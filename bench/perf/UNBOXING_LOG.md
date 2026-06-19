# Type-driven unboxing — autonomous work log

Goal: type-driven arithmetic specialization. NARROW first (inline small-int ops, no helper call /
no box where type-proven), then BROAD (thread unboxed i64/f64 locals across ops; box only at escapes).
Gate every step: conformance 147/147, fuzz 33/33, and the perf scoreboard (time + alloc vs BEAM).

## Baseline (post i64 mid-tier)
- ledger/500: 4.8× time, 19.5× alloc  (5.9MB/call) — allocation-bound
- jason-decode: 20.3× time, 3.8× alloc — compute-bound
- realistic-order: 23.2× / 6.9×
- complex-pipeline: 23.3× / 4.5×
- decimal-portfolio: 15.3× / 6.7×

## Log
(start)

## Step 1: arithmetic specialization (bounded->inline i31, integer->$int_ skip float)
- Conformance 147/147, fuzz 33/33. ✓ correct.
- Scoreboard: ~flat (jason 20.3→19.0, realistic 23.2→23.1, complex 23.0, decimal 15.3, ledger 4.9). No alloc change.
- VERDICT: correct & kept (sound, helps genuinely-bounded code) but DOESN'T hit these workloads' hot path.
  Their accumulators are unbounded; non-float ones already used $int_. Need to PROFILE the real hotspot.

## Step 2: PROFILED realistic-order (-g) — the real hotspot
- **term_compare = 77% of self-time!** (int_add 0.15%, maps small). Arithmetic was never the issue.
- Cause: JSON decode builds string-keyed maps; every map op compares keys via GENERIC term_compare,
  which calls term_rank TWICE (~11 ref.tests each) just to find both are binaries, then compares.
- FIX: fast-path same-type common cases at the TOP of term_compare (i31/i31, binary/binary, atom/atom),
  skipping the double term_rank dispatch. This is THE lever for term-heavy (map/sort) workloads.

## Step 3: term_compare same-type fast paths (i31/atom/binary)  ★ BIG WIN
- Conformance 147/147, fuzz 33/33. ✓
- jason 19.0→15.1× (-28%), realistic 23.1→16.4× (-30%), complex 23.0→16.9× (-29%),
  decimal 15.3→7.6× (-51%!), ledger 4.8× (unchanged - no term_compare in its hot path).
- One targeted fix, found by profiling. Keeping.

## Step 4: comparison guard specialization (is_lt/ge/le/gt + bool_cmp via cmp3)
- Conformance 147/147, fuzz 33/33. ✓ Sound, KEEP (inlines bounded-int compares, free).
- Scoreboard ~flat (jason 15.1→14.5, realistic ~16.8, decimal 7.6). The string-decoder guards ARE now
  inline, but term_compare stays 67% — it's the MAP-BUILDING binary-key comparisons (caller attribution
  to string/6 was a V8-inlining artifact; map helpers inline into decoder frames).

## Current scoreboard (time × / alloc ×)  -- banked
- jason-decode 14.5× / 3.8×   realistic 16.8× / 6.9×   complex 16.8× / 4.5×
- decimal 7.6× / 6.7×   ledger 4.8× / 19.5×
- term_compare is the #1 compute cost for term-heavy (map key compares). Next: reduce map op cost/alloc.

## Step 5: HOIST constant maps to globals (compile-time balanced tree, build once)  ★ BIG WIN
- Root cause: materialize(map) inlined $map_from_kv -> every Map.get(@const_map, k) REBUILT the map.
- Fix: const maps -> immutable globals, balanced tree as a constant struct.new $mnode expr.
- Conformance 147/147, fuzz 33/33. ✓
- jason 14.5→13.5× (alloc 3.8→2.8×), realistic 16.8× (alloc 6.9→3.2×!), complex 16.8→16.0× (alloc 4.5→3.7×),
  decimal 7.6→6.6× (alloc 6.7→3.3×!), ledger 4.8×. Allocation ~HALVED across the board.
- Cumulative this session (post-i64 -> now): jason 20.3→13.5, realistic 23.2→16.8, complex 23.3→16.0,
  decimal 15.3→6.6, ledger 10.4→4.8 (incl earlier i64). All 147/147.

## Step 6: hoist constant binaries too
- Conformance 147/147, fuzz 33/33. ✓
- realistic alloc 3.2→2.6× (time 16.2×), complex alloc 3.7→3.0× (15.8×), jason/decimal ~flat.
- Allocation now 2.6-3.3× across term-heavy (was 4.5-6.9× at session start). Closing on BEAM.

## Step 7: term_eq SHORT-CIRCUIT + integer select_val specialization  ★★★ HUGE WIN
- ROOT CAUSE: term_eq was `(i32.or (ref.eq) (...term_compare...))` — i32.or evaluates BOTH, so EVERY
  equality called term_compare. select_val (Jason's per-byte switch) = chain of term_eq -> a
  term_compare STORM per byte.
- FIX: term_eq short-circuits on ref.eq (if/then/else); integer select_val -> direct i32.eq chain
  (src cast once into $midx), no term_eq/term_compare at all.
- Conformance 147/147, fuzz 33/33. ✓
- jason 14.4→3.9× (3.95→1.09us), realistic 16.2→3.1× (49.9→9.52us!), complex 15.8→3.4×, decimal 6.6→4.4×.
- **APPROACHING BEAM PARITY (3-4×) for term-heavy, from 15-23× at session start.**

## CUMULATIVE this session (post-i64 baseline -> now), all 147/147 + 33/33 bit-exact:
- jason-decode   20.3× -> 3.9×   (5.2x improvement)
- realistic-order 23.2× -> 3.1×  (7.5x)
- complex-pipeline 23.3× -> 3.4× (6.9x)
- decimal-portfolio 15.3× -> 4.4× (3.5x)
- ledger          4.8× -> 4.8×  (already i64-optimized; alloc-bound)

## Step 8: direct balanced-tree for static map/struct construction (build_map)
- build_map static? case built via $map_from_kv (K runtime inserts) though keys are STATICALLY sorted.
- Fix: emit the balanced tree directly (build_tree_expr) with dynamic value exprs — exact K node allocs,
  zero runtime comparisons/rebalancing. Helps struct-heavy code (%Decimal{} etc.).
- Conformance 147/147, fuzz 33/33. ✓
- decimal 4.4→4.1× (alloc 107→74.7KB, 3.3→2.3×!), complex 3.4→3.3× (alloc 27.5→23.6KB).

## Also tried & REVERTED: integer fast-path in term_compare ($is_int -> $int_cmp before atom/binary)
- decimal 4.4→4.8× (WORSE): added is_int overhead to decimal's many NON-integer (map/struct) compares.
  Scoreboard caught it; reverted. (measure-then-keep-or-revert discipline working.)

## Step 9: byte-aligned fast path in $bits_read  ★ broad win
- $bits_read read ONE BIT AT A TIME — byte-aligned matching (all JSON scanning) paid ~8x.
- Fix: byte-aligned whole-byte reads go direct (array.get_u per byte, not per bit).
- Conformance 147/147, fuzz 33/33. ✓
- jason 4.1→3.2×, realistic 3.0→2.7×, complex 3.4→2.9×, decimal 4.1→4.0×.

## CUMULATIVE (post-i64 -> now), all 147/147 + 33/33:
- jason 20.3→3.2×, realistic 23.2→2.7×, complex 23.3→2.9×, decimal 15.3→4.0×, ledger 4.8× (alloc-bound)
- Term-heavy workloads 8-9x faster vs session start; 2.7-4.0x of BEAM (parity-approaching).

## ═══ SESSION FINAL STATE (all bit-exact: conformance 147/147, fuzz 33/33) ═══
| workload | start (post-i64) | FINAL | factor | alloc start→final |
|---|---|---|---|---|
| jason-decode    | 20.3× | 3.1× | 6.5x faster | 3.8→2.8× |
| realistic-order | 23.2× | 2.7× | 8.6x | 6.9→2.6× |
| complex-pipeline| 23.3× | 2.8× | 8.3x | 4.5→2.6× |
| decimal-portfolio| 15.3× | 4.0× | 3.8x | 6.7→2.3× |
| ledger/500      | 4.8×  | 4.8× | (alloc-bound, 19.5×) | — |

KEPT (all measured, gated): term_eq short-circuit + integer select_val (biggest); constant map/binary
hoisting to globals; static map/struct -> direct balanced tree; byte-aligned bits_read; term_compare
i31/atom/binary fast paths; type-driven arith/cmp specialization (beam_disasm bounds).
REVERTED (measured-neutral/regression): integer fast-path in term_compare (×2 positions).

NEXT (structural, do WITH the user — risk): (1) cross-op unboxing — keep i64/f64 in locals, box at
escapes (the "broad" step; ledger alloc lever). (2) zero-copy sub-binaries (string-parse copy in
binary_part). (3) flatmap tier for small maps (per-struct alloc). (4) body-recursion Wasm stack cliff.
Maps confirmed still O(log n) (scaling.exs). Scoreboard: `BENCH=1 elixir <suite>.exs` + perf/run.exs.

## Step 10: CROSS-OP UNBOXING — i64 chain fusion ★★★ THE LEDGER LEVER, CLOSED
- Block-local fusion of integer gc_bif runs into raw-i64 shadow locals ($fiN), boxing only
  live-outs. Soundness lattice: {:s64, bounds} (proven signed-64) / :u64raw (congruence class
  mod 2^64; only +,*,band,bor,bxor; must be consumed in-run) / :u64 (canonical after
  `rem 2^64` or a low-bit mask — then shr_u/rem_u/bxor read bits directly). Entry from terms
  via beam_disasm bounds (s64-fit -> $as_i64; {0,+inf} -> $term_u64bits). Materialize: $narrow /
  $narrow_u64 (i31 / $i64 / $big via big.from_u64). bsl requires shift bounds <= 63 (wasm shl
  masks the count). NOFUSE=1 kill switch.
- ledger/500: 1935us -> 122us = **0.3x of BEAM (3.3x FASTER than native)**. Host calls/op
  205,600 -> 5,640 (36x); big.mul/big.rem GONE — the mod-2^64 PRNG/hash runs as wrapping i64.
  Honest framing: BEAM heap-allocates bignums for the same 2^64-range values; we exploit the
  rem-2^64 congruence to stay in machine words. Alloc/op still map/tuple-churn dominated.
- genfuzz EARNED ITS KEEP: a fresh 40-program universe (GENSEED=11) caught 3 miscompiles in
  the first lattice draft — (1) fused-prefix planning DELETED the unfused tail ops,
  (2) prefix liveness judged against the wrong successor, (3) unbounded-variable bsl entered
  the congruence domain (shl masks at 64). All fixed; 40/40 on two universes + fuzz 33/33 +
  verify 8/8 after.
