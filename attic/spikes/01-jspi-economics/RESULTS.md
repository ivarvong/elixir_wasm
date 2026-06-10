# JSPI economics spike — results

**Question:** can every Elixir process be a real JSPI (stack-switched) activation, or do we
need a CPS / state-machine fallback for the bulk of processes? This decides the hardest part
of the runtime design.

**Method:** model a process as a `promising()` activation that blocks in a JSPI *suspending*
`recv()` import (`process.wat` → 156-byte module). A process optionally descends `DEPTH` live
call frames, then enters a receive loop counting messages until a negative sentinel. JS side
holds a per-pid mailbox + parked-resolver map; "wake" = resolve the pid's promise. Measured on
Node 24.16 (V8 13.6, `--experimental-wasm-jspi --expose-gc`) for clean `process.memoryUsage()`,
and validated functionally on `workerd 2026-06-05` (the production runtime, `--experimental`),
which enforces the real per-isolate memory cap that Node does not.

The stable `WebAssembly.Suspending` / `WebAssembly.promising` API is identical in both. (Note:
Node 22 / V8 12.4 has only the older crashy `WebAssembly.Function({promising})` shape — needs
Node 23+ / V8 12.9+ for the stable API.)

## 1. Memory per suspended stack (Node, depth 0)

| processes | RSS delta | per process |
|-----------|-----------|-------------|
| 1,000     | +5.3 MB   | 5.50 KB     |
| 5,000     | +26.2 MB  | 5.35 KB     |
| 10,000    | +51.2 MB  | 5.25 KB     |
| 25,000    | +125 MB   | 5.12 KB     |
| 50,000    | +254 MB   | 5.21 KB     |
| 100,000   | +504 MB   | 5.16 KB     |

**~5.2 KB per blocked process, dead flat to 100k, no engine ceiling** (Node has no cap; 100k
spawned in 68 ms). Stacks are allocated off the JS heap, so the cost shows in RSS, not heapUsed.

## 2. Stack-depth sensitivity (Node, N = 5,000)

| live frames | per process |
|-------------|-------------|
| 0           | 5.35 KB     |
| 10          | 5.38 KB     |
| 100         | 9.37 KB     |
| 1,000       | 73.3 KB     |
| 5,000       | 357 KB      |

JSPI stacks are **growable**: ~5 KB floor, then ~70 bytes per (small) live frame. Consequence:
tail-recursive Elixir (GenServer loops, `Enum.reduce`, comprehensions) stays at the floor;
only deep *non-tail* recursion is expensive. **Emitting Wasm tail calls keeps processes at ~5 KB.**

## 3. Throughput (Node, depth 0)

Wake a herd (suspend → resume → return): **0.7–0.95 M/s** (945k @ 1k procs, 707k @ 50k).
Steady-state suspend/resume cycles (deliver → resume → handle → re-suspend): **1.4–2.2 M/s**,
i.e. **~0.45–0.7 µs per round trip**. This is substrate-only (trivial i32 messages, no payload
marshaling, no selective-receive scan, no reduction work) — an upper bound on the scheduler, on
top of which real Elixir work dominates. It is comfortably in BEAM's messaging ballpark.

## 4. workerd (target runtime) — functional + ceiling

| request           | result |
|-------------------|--------|
| n=5,000  m=0      | `ok:true, parkedAfterSpawn:5000` (all suspended) |
| n=10/20/25/30,000 | `ok:true` (all suspended) |
| n=1,000  m=50     | `total:50000` exact (1000 × 50 messages resumed correctly) |
| n=50,000          | **V8 fatal: `StackMemory::StackSegment ... allocation failed: process out of memory`** |

The abort names the mechanism: concurrent suspended processes are bounded by **stack-segment
allocation against the per-isolate memory cap**. Shallow-process ceiling locally is between
30,000 and 50,000; under production's strict 128 MB enforcement, budget lower (~15–25k once the
runtime + term heaps share the 128 MB).

## Conclusion for the runtime design

**"Every process = a real JSPI stack" is viable** — no whole-program CPS transform required for
the common case, which was the single biggest risk and the thing that sank Lumen/Firefly.

- ~5 KB per shallow blocked process → **tens of thousands of concurrent blocked processes per
  isolate**, bounded by the 128 MB cap (not by any engine limit).
- `spawn` = `WebAssembly.promising(table.get(idx))(args)`; `receive` = suspend on a promise the
  mailbox resolves (exactly the `ws_receive` pattern in workers-zig). Both confirmed on workerd.
- Tail-call codegen is load-bearing: it pins processes to the ~5 KB floor. Deep non-tail
  recursion is the only thing that inflates a stack.
- To scale past one isolate's ceiling, shard processes across isolates and route long-lived /
  durable actors to Durable Objects — the two-tier model. Reserve a state-machine fallback only
  for a single workload that must hold >~tens-of-thousands of simultaneously-blocked processes in
  one isolate, which is an anti-pattern on Workers regardless.

## Reproduce

```
# Node (precise memory + throughput):
node --experimental-wasm-jspi --expose-gc harness.mjs mem  10000 0
node --experimental-wasm-jspi --expose-gc harness.mjs wake  10000 0
node --experimental-wasm-jspi --expose-gc harness.mjs tput   1000 0 100
#   args: MODE(mem|wake|tput) N DEPTH [M]   -> CSV line

# workerd (target runtime, functional + ceiling):
workerd serve --experimental config.capnp        # then:
curl 'http://127.0.0.1:8787/?n=10000&m=0'         # parkedAfterSpawn should == n
curl 'http://127.0.0.1:8787/?n=1000&m=50'         # total should == n*m
```

Files: `process.wat` (the model), `harness.mjs` (Node benchmark), `worker.js` + `config.capnp`
(workerd), `smoke.mjs` (minimal end-to-end check).

---

# Spike B — process kill / unwind across a JSPI suspension

**Question:** OTP needs `Process.exit`, links, monitors, and "let it crash." Can a process
parked in `receive` actually be killed, with its `try/after` cleanup running — and can the
runtime tell its *own* exception (an Elixir `raise`, compiled to a tagged Wasm `throw`) from an
externally-injected kill? This couples Wasm exception handling with JSPI stack switching — two
newish features used together.

**Mechanism under test:** to kill a parked process, *reject* the promise its `recv()` is
suspended on. V8 should resume the suspended Wasm stack by throwing the rejection in at the
suspend point; a `try_table` with `catch_all` catches it, runs cleanup, and the process
terminates. A self-`raise` is a Wasm `throw` of a dedicated tag, caught by `catch $tag` —
distinct from the foreign kill. `spikeB.wat` = 195-byte module; harness `spikeB.mjs`; validated
on `workerd 2026-06-05` via `workerB.js` / `configB.capnp` (port 8788).

## B1–B2 functional (Node 24.16, V8 13.6; identical pass on workerd)

| test | result |
|---|---|
| B1 kill a parked process → `catch_all` runs cleanup, returns -1 | **PASS** (cleanup ran) |
| B2 self-`raise` caught by own tag → -2, *not* misclassified as kill | **PASS** |
| B2b normal completion (sentinel) → returns count | **PASS** |

workerd confirmation (production runtime): `kill {ret:-1, cleanupRan:true, ok:true}`,
`raise {ret:-2, raiseHandled:true, notKill:true, ok:true}`, `normal {ret:2, ok:true}`.
**Wasm EH and JSPI compose correctly, including on workerd.** Rejection-as-unwind works; the
runtime distinguishes raise/throw/exit from an external kill at the suspend point.

## B3 memory: termination must UNWIND, not abandon

RSS rarely shrinks (V8 pools freed Wasm stacks), so the right test is whether memory **plateaus**
(reused) or **grows** (leaked) across generations of spawn→die. 5 generations × 10k processes:

| termination | RSS delta by generation (MB) | verdict |
|---|---|---|
| **kill** (reject → unwind → complete) | `[58, 66.5, 67.4, 67.9, 68.2]` | **plateaus** — stacks pooled & reused; churn is memory-bounded |
| **abandon** (drop all JS refs, never settle) | `[0, 40.6, 81.4, 122.3, 163.1]` | **grows ~41 MB/gen** — engine-rooted suspended stacks accumulate forever |

**Operational rule:** a suspended JSPI stack is rooted by the engine, *not* by JS reachability.
You cannot reclaim a blocked process by dropping references to it — `Process.exit` and
dead-process cleanup MUST deliver a kill that *unwinds* the stack (the B1 path). Done that way,
spawning and killing millions of short-lived processes is memory-bounded by peak concurrency,
not cumulative count — exactly the Workers request-per-spawn workload.

---

# Spike C — shared-heap GC (the cost of losing per-process heaps)

**Question:** WasmGC gives one V8-traced heap per isolate, so we lose BEAM's per-process heaps:
(a) no GC isolation — one process's churn pauses all of them; (b) killing a process doesn't free
its memory immediately. How bad is it? `spikeC.wat` allocates cons cells (`struct {i32, ref}`) —
a stand-in for a "term"; `garbage(n)` builds+drops an n-cell list, `retain/release` control a
rooted live set, `process_main` allocates per message. **Assembled with Binaryen `wasm-as -all`**
(wabt 1.0.39 cannot emit WasmGC instructions). Run on Node 24.16, `--max-old-space-size=128` to
emulate the Workers isolate cap. GC pauses measured via `perf_hooks` PerformanceObserver.

> Validity: WasmGC objects live on the *same* V8 managed heap and are collected by the *same* GC
> as everything else, so these pause / throughput / reclamation dynamics are engine properties
> that transfer directly to the real runtime.

## C1 — GC pauses under multi-process churn
2000 processes × 200 msgs × 200 terms = **80M allocations in 867 ms** (92M terms/s, 461k msgs/s):
- **193 pauses** (189 minor scavenges, 4 major), totaling **195.8 ms = 22.6% of wall time**.
- Individual pauses: **mean 1.0 ms, p50 0.87 ms, p95 1.9 ms, max 6.7 ms.**

No multi-hundred-ms stop-the-world — pauses are single-digit ms even under pathological churn.
The 23%-of-wall figure is a worst case (an allocation-bound microbenchmark at 92M terms/s); real
handlers do work between allocations. Tail-call loops keep this from being worse.

## C2 — throughput vs live set, near the 128 MB cap
Fixed garbage workload timed (median of 3) at increasing rooted live sets:

| live set | garbage throughput |
|---|---|
| ~9 MB  | 165 M terms/s |
| ~50 MB | 140 M terms/s |
| ~61 MB | 140 M terms/s |
| ~90 MB | **6.8 M terms/s** |

Throughput holds up to ~60 MB live, then **collapses ~20×** approaching the cap: V8 runs near-
constant major GCs to stay under 128 MB. **The shared heap means every process's live data counts
against one budget; approaching the cap is catastrophic for everyone.** Operational implication:
keep live set well under the cap (shard across isolates/DOs); treat ~half the cap as the soft
ceiling.

## C3 — deferred reclamation on process death
Retain a ~2M-cell structure (a process's "heap"), then `release` it (process dies) **without** GC:

`before 4 MB → retained 65 MB → after death, no GC 65 MB → after GC 4 MB`

**61 MB stays live after the process dies, freed only at the next GC** — vs BEAM, which returns a
dead process's heap immediately. Memory-pressure accounting must assume dead-process memory lingers
until GC; under the 128 MB cap, a burst of deaths does not instantly create headroom.

## Spike C verdict
The shared heap is **workable for the Workers model** (short requests, small per-request live sets):
pauses are short, and request-scoped garbage is cheap to collect. It is **not** BEAM's soft-realtime
isolation — there is no per-process GC, no instant free on kill, and a large shared live set degrades
everyone. Design around it: keep live sets small, shard across isolates, and never rely on kill for
prompt memory reclamation.
