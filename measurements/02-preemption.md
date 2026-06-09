# Reduction-counted preemption on WasmGC + JSPI

BEAM's scheduler is preemptive: each process runs on a reduction budget (≈ one per function call),
and when it's spent the scheduler suspends it and runs another — so no process monopolizes a thread
(soft real-time). Reproduced here: the compiler (mode `REDS=<budget>`) injects, at **every function
entry**, a decrement + check that calls a **suspending `yield` import** when the budget hits zero, then
resets it. The yield suspends the whole Wasm stack via JSPI (`WebAssembly.promising` entry +
`WebAssembly.Suspending` import) and resumes after the scheduler regains control.

Injected at each entry:
    (global.set $reds (i32.sub (global.get $reds) (i32.const 1)))
    (if (i32.le_s (global.get $reds) (i32.const 0)) (then (call $yield) (global.set $reds (i32.const N))))

## Overhead (fib(30), 2.69M calls; Node, V8 = workerd's engine)
| build                              | time   | overhead |
|------------------------------------|--------|----------|
| baseline (no counting)             | 9.2 ms | —        |
| + reduction count, never yields    | 10.5 ms| **+14%** (0.48 ns/reduction) |
| + count + yield (budget 50k)       | 13.6 ms| correct result; **suspended 53×** (~53 expected) |

**+14% is the worst case** — `fib` is a ~12-instruction body, so a ~6-instruction check weighs heaviest.
Functions with real work amortize it; per-reduction cost is 0.48 ns.

## Preemption is real (does a long computation hog the thread?)
A co-running task (microtask loop) tries to make progress while `fib(32)` runs:
- **blocking** (synchronous fib): co-runner advanced **0×** during the call — thread monopolized.
- **preemptive** (yielding fib): co-runner advanced **143×** during the call — thread **shared**
  (fib suspended 141×).

That is the property that makes a single isolate safe to share across many actors: a runaway
computation yields instead of starving everything else.

## Honest scope
The `yield` import resolves via a microtask (`Promise.resolve`); a real scheduler would yield to a run
queue and dispatch the next ready process — the JSPI suspend/resume mechanism is identical, only the
scheduling policy is elided. The budget is a single shared global here; true per-process fairness wants a
per-process counter (in the process struct). Tail-recursive loops are covered because each iteration
re-enters the function (the entry check fires). Cost transfers to workerd (JSPI + WasmGC confirmed there
in earlier spikes); these timings are Node for precise counters.
