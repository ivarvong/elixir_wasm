# Runtime — preemptive processes + GenServer on a JSPI scheduler

The leap from compiler to **runtime**: real Elixir processes (`spawn`/`send`/`receive`/`self`)
running as JSPI stacks under a **preemptive** scheduler — including a working `GenServer`.
`scheduler.mjs` is the host: process table, per-process mailboxes, a reduction budget per
dispatch, and a run loop that drives each process until it parks at `receive` or is preempted.

```bash
# compile a module that uses processes (proc imports are auto-detected)
cd ../compiler/examples
elixirc processes.ex
EXPORTS="sumsq_to:int->int;counter:int->int;nested:int->int" \
  elixir ../beam2wasm.exs Elixir.Processes.beam > processes.wat
wasm-as processes.wat -o processes.wasm -all
node --experimental-wasm-jspi ../../runtime/scheduler.mjs processes.wasm sumsq_to 50   # -> 42925
```

## Preemption (the soft-real-time guarantee)
In proc mode the compiler injects a reduction-budget decrement at every function entry; when
the budget hits 0 the process calls the suspending `sched.yield` and the scheduler dispatches
the next runnable process. The host resets the budget (`set_reds`) per dispatch — BEAM's "fresh
reductions per schedule." A CPU-bound process therefore **cannot** monopolize the isolate:
`spin(1_000_000)` (no `receive`) is sliced into ~500 dispatches (budget 2000), measured via
`SCHED_DEBUG=1`. (Real Wasm `return_call` tail calls keep deep recursion flat — 1M-deep tail
recursion runs without growing the stack.)

## GenServer (`examples/genserver.ex`)
A generic `Srv` loop dispatches to a **callback module** (`Counter`, `Stack`) via dynamic
`mod.handle_call/handle_cast/init` — lowered through a generated closed-world `apply_N` switch.
`call` is synchronous (send + await reply), `cast` is async; state threads through the loop.
Verified vs the VM (`conformance` `genserver` category). This is "Durable Objects with OTP
discipline" made literal: an OTP-style server, compiled from Elixir, on the edge substrate.

## Fault tolerance — links, exit signals, supervisor restart (`examples/supervisor.ex`)
`spawn_link` links two processes; `Process.flag(:trap_exit, true)` makes a process receive a
linked peer's death as a message instead of dying with it; `exit(reason)` terminates a process
(the import throws to unwind its JSPI stack). When a process dies, the scheduler delivers
`{:EXIT, pid, reason}` to each trapping linked process (built by a Wasm-side `make_exit` export,
since atoms live in Wasm, not JS) — or propagates the kill to a non-trapping linker if the exit
was abnormal. On top of these primitives, a **supervisor** spawns a worker, catches its `{:EXIT,
…, reason}`, and **restarts** it: a worker that crashes (`exit(:crashed)`) twice is restarted and
eventually succeeds — bit-exact with the VM (`conformance` `supervisor` category). "Let it crash,"
on WasmGC.

## Registry + monitors (`examples/registry.ex`)
`Process.register(pid, name)` / `Process.whereis(name)` give **named processes**; `send` resolves a
name to a pid (the compiler's `resolve_dest` checks pid-vs-atom at runtime), so `send(:counter, msg)`
works. `Process.monitor(pid)` returns a ref and, when the target dies, the monitoring process gets
`{:DOWN, ref, :process, pid, reason}` (built by a Wasm-side `make_down`). Verified vs the VM
(`conformance` `registry`). The registry is per-scheduler-run; note the VM's name table is *global*,
so the runtime actually handles repeated registrations the VM rejects across cases.

## Durable GenServer in a Durable Object
`../durable-genserver/` runs a GenServer's `handle_call/3` inside a Cloudflare DO with state durable
across restart — the in-isolate runtime here is the live-process model; the DO is the durable model.

## How it works
- The compiler detects process opcodes and emits **imports** (`proc.spawn/send/self/recv_*`) +
  a `start_process` export. `recv_wait` is a `WebAssembly.Suspending` import — the JSPI suspend point.
- Each process is a `WebAssembly.promising` stack. It runs **synchronously until it parks** at
  `recv_wait` (empty/no-match mailbox), so the host's `current` pid is always correct. `send` to a
  parked process re-queues it; the run loop resolves its parked promise to resume the stack.
- A spawned closure's captured variables travel inside the `$fun` (see the compiler's closure model),
  so workers that capture `me`/`i` work — verified with 50 concurrent workers.
- `receive` is **selective** (BEAM `loop_rec`/`loop_rec_end`/`wait` with a mailbox cursor), not just FIFO.

## Verified vs the Elixir VM (conformance `processes` category, 7/7)
worker pool with captured vars (`sumsq_to`), stateful server (`counter`), nested spawn + multi-hop
messaging (`nested`) — all bit-exact with `elixir`.

## Honest scope
Built: spawn, send, selective receive, self; **preemptive** scheduling (reduction budget + JSPI
suspend); captured closures in spawned processes; real Wasm tail calls; a module-based **GenServer**
(call/cast/state via `apply` dispatch); **links + `trap_exit` + exit signals + a restarting
supervisor**; **monitors** (`{:DOWN,…}`) and a named-process **registry**; and a **durable GenServer in
a Durable Object** (`../durable-genserver/`). **Not yet:** `receive ... after` **timeouts**; a reusable
`Supervisor`/`Agent`/`Task` library (the primitives are all here — these would wrap them); a term codec
(ETF) for richer durable state + cross-isolate messaging. The scheduler is single-isolate and round-robin
over a microtask-driven run loop; GenServer/supervisor/registry are the programming model on our
primitives, not OTP's `:gen_server`/`:supervisor`/`:global` (no `sys`/`proc_lib`).
