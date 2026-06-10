# Runtime measurements — Elixir→WasmGC on the edge (Cloudflare principal DD)

Three numbers a reviewer asks for, measured (not estimated), each with honest scope. The compiler
(`beam2wasm.exs`) gained two opt-in modes for this: `REDS=<budget>` (reduction-counted preemption) and
`BIGNUM=1` (arbitrary-precision integers). Harnesses are reproducible (Node 24 `--experimental-wasm-jspi`;
V8 is the engine workerd runs).

## 1. Cold start — not the bottleneck  (`01-cold-start.md`)
- Per-DO **instantiate ≈ 10 µs** (workerd-confirmed, matches V8).
- Per-isolate **compile ≈ 5 µs/KB** → ~5 ms for a realistic ~1 MB module, amortized over the isolate's life.
- End-to-end cold DO ≈ 10 ms (storage/disk setup, language-independent); warm ≈ 3 ms.
- The compiled-Elixir module costs microseconds; isolate + storage dominate.

## 2. Preemption — BEAM's soft-real-time guarantee, reproduced  (`02-preemption.md`)
- Compiler injects a reduction check at each function entry; on budget=0 it **suspends the Wasm stack via
  JSPI** and yields. Confirmed: fib(32) suspended 141×, correct result.
- **Overhead +14%** worst-case (tiny `fib` body; 0.48 ns/reduction); real functions amortize.
- A co-runner advanced **143×** during a yielding fib(32) but **0×** during a blocking one — no
  computation can monopolize the thread.

## 3. Arbitrary precision — fintech exactness  (`03-bignums.md`)
- Tiered integer: i31 fast path → boxed JS BigInt on overflow; `+ - *` detect/promote/demote.
- `fact(50)` (65 digits) and every boundary (i31, i64, beyond) **bit-identical to the Elixir VM**.
- Fast-path cost +50% if always-on; the fix is type-driven specialization using BEAM's own type info
  (`:beam_disasm` already exposes typed registers) — exact by default, fast by analysis.

## What this establishes for the thesis
The "Elixir-flavored durable edge runtime" rests on three load-bearing claims that were previously on
paper; all three now have measurements on the real engine:
1. **Cold start is competitive** — the module is in the noise vs platform overhead.
2. **The scheduler can be preemptive** — reductions + JSPI deliver soft-real-time on one thread, the
   property that makes sharing an isolate across many actors safe.
3. **Arithmetic is exact** — arbitrary precision, matching BEAM, which a fintech ledger requires.

Still genuinely open (need real Cloudflare, not local workerd): throughput/latency/cost at scale, and the
per-process (not shared-global) scheduler with a real run queue.
