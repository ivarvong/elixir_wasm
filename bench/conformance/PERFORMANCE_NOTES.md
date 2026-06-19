# Performance Notes

Current status: correctness-first BEAM-to-WasmGC lowering. The conformance suites prove broad
semantics, but generated Wasm is still generic and intentionally unspecialized.

Measured steady-state, Wasm vs BEAM measured identically (median us/op, both in-process; run with
`BENCH=1 elixir <suite>.exs`, and `perf/run.exs` for the ledger). All workloads are bit-exact vs the
VM. Local V8 / BeamAsm; compute only, not Cloudflare.

| Workload | Wasm us/op | BEAM us/op | Ratio | alloc ratio |
| --- | ---: | ---: | ---: | ---: |
| ledger/500 (random ledger ops) | 1939 | 406 | 4.8× | 19.5× |
| jason decode | 0.91 | 0.29 | 3.1× | 2.8× |
| realistic order | 8.53 | 3.16 | 2.7× | 2.6× |
| complex pipeline | 16.63 | 5.90 | 2.8× | 2.6× |
| decimal portfolio | 56.18 | 14.17 | 4.0× | 2.3× |

**~3× slower** for term-heavy workloads (down from 15–23×), approaching BEAM parity; allocation 2.3–2.8×
(was 4.5–6.9×). All wins bit-exact (147/147 + fuzz 33/33) and measured (`perf/`, see
`perf/UNBOXING_LOG.md`):
- **Maps** are a weight-balanced tree (O(log n) get/put) — killed the O(n²).
- **Integers** are 3-tier: i31 → `$i64` (in-Wasm) → host `$big`. Cut the bignum ledger 10.4×→4.8×.
- **Type-driven specialization** from `beam_disasm` typed registers: bounded-int arithmetic/comparisons
  emit inline i32 (no helper, no box); `term_compare` got same-type (i31/atom/binary) fast paths.
- **Constant hoisting**: constant maps/binaries built ONCE as immutable globals (compile-time balanced
  trees) instead of re-materialized per use — `Map.get(@const,k)` no longer rebuilds the map each call.
- **term_eq short-circuits** on `ref.eq`; integer `select_val` → a direct `i32.eq` chain — killed a
  per-byte `term_compare` storm in the JSON decoders (realistic 16×→2.7×).
- **Static map/struct construction** emits a balanced tree directly (no runtime inserts/rebalancing).
- **Byte-aligned `$bits_read`** reads whole bytes (was bit-by-bit — an 8× tax on all binary scanning).

Remaining levers (structural): the ledger is allocation-bound (boxes every `$i64` — needs cross-op
unboxing, the "broad" step), zero-copy **sub-binaries** (string parsing copies via `binary_part`),
a flatmap tier for small maps (lower per-struct allocation), and the body-recursion stack cliff at ~10^4.

Primary bottlenecks:

- Generic boxed terms everywhere: arithmetic, maps, lists, tuples, binaries, pids, refs all use the same term path.
- Exact integers are always enabled: correct, but small-int arithmetic still pays dynamic checks before the BigInt fallback.
- Maps use sorted kv arrays: simple and correct, but `put` copies arrays and hot `get` paths are not specialized.
- Structural `term_compare` is generic and recursive: needed for correctness, expensive in hot key/equality paths.
- Binary matching is bit-accurate but naive: `$bits_read` handles arbitrary offsets one bit at a time.
- Real `Enum` and closures work but are interpreted through generic closure tables and apply paths.
- No production optimization pipeline yet: generated WAT has little inlining, specialization, constant folding, or CSE.

High-ROI optimization work:

1. Specialize proven-small integer arithmetic with exact fallback.
2. Add byte-aligned, i32, and i64 fast paths for binary matching before falling back to bit reads.
3. Specialize JSON/string-key map access for `Map.get`, `Map.fetch!`, and `Map.put` hot paths.
4. Improve map representation for larger maps or add flatmap/HAMT tiers.
5. Generate direct loops for common `Enum.reduce`/`Enum.map` shapes when closure targets are statically known.
6. Establish a working `wasm-opt`/Binaryen feature configuration for WasmGC or add lightweight WAT-level optimizations.

Principle: keep writing normal Elixir and make the compiler/runtime catch up. Avoid shaping application code around compiler gaps.
