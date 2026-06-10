# Spike A — term-representation perf + the 10 MB size gate (the feasibility gate)

The one test that could still say *no* on feasibility. Verdict: **GREEN on both halves.**

## Size gate — does a real actor's code fit under 10 MB compressed?
Seed: a `gen_server`-based order/payment actor (`seed.erl`). The closure walker (`closure.mjs`)
follows the `.beam` import tables transitively over installed OTP, excluding preloaded/BIF modules
(those map to native runtime, not shipped bytecode).

| closure | modules | gz bytecode (interpreted-tier payload) |
|---|---|---|
| module-granularity, everything reachable | 145 | **1.06 MB** |
| pruning subsystems our runtime doesn't contain¹ | 39 | **0.36 MB** |

¹ closed-world deletes the code server + entire compiler (`beam_ssa`/`cerl`/`v3_core`/`compile`…);
Durable Objects replace distribution (`net_kernel`/`global`/`inet_*`); no-FS removes disk DBs
(`dets`/`disk_log`); `crypto`→WebCrypto; logger→shim. Excluding their entry points prunes each subtree.

Both are far under the 10 MB cap. Function-level DCE (we currently ship whole modules — all of
`lists`/`maps`/`unicode_util` for a few reached functions) would shrink it further.

## Term-rep perf — is WasmGC worth it, and how fast are the tiers?
Same workload three ways (`perf.mjs`, `fib(30)` = 2.69 M calls; all three return 832040):

| tier | time/fib(30) | per call | vs WasmGC |
|---|---|---|---|
| **WasmGC (AOT)** | 4.7 ms | 1.7 ns | 1.00× |
| JS backend (terms as JS values) | 12.0 ms | 4.5 ns | 0.39× |
| BEAM interpreter (our dynamic tier) | 1049 ms | 390 ns | 0.004× |

Heap-allocating term workload (`lst_lift.wat`, build+fold a 1000-cell cons list, 20 M allocations):

| representation | per cell | throughput |
|---|---|---|
| WasmGC struct cons | 6.2 ns | 161 M cells/s |
| JS object cons | 8.3 ns | 121 M cells/s (0.75×) |

So: **AOT WasmGC beats a JS backend ~2.6× on arithmetic and ~1.33× on allocation**, and beats the
interpreter ~220×. WasmGC over uniform i31/struct terms is worth it, and confirms the tiering: AOT
the hot path, interpret only cold/dynamic code.

## The AOT size multiplier (the surprise)
For the same functions (add/dbl/fact/fib): BEAM Code chunk = 206 B raw / 176 B gz; WasmGC = 207 B raw
/ 163 B gz → **~1.0× raw, 0.93× gz.** WasmGC AOT is *not* bloated vs BEAM bytecode — it's ~1:1, because
WasmGC is itself a dense bytecode and i31/struct ops lower compactly. (See caveats — this is from simple
integer functions and will rise for pattern-matching/binary/map code.)

## Projection vs the 10 MB limit (gen_server actor closure)
| tier | pruned | unpruned upper bound |
|---|---|---|
| interpreted (bytecode) | 0.36 MB | 1.06 MB |
| AOT (bytecode × 0.93) | 0.33 MB | 0.98 MB |

Even multiplying the AOT figure by 4–10× to account for realistic code (below), the pruned closure stays
~1.4–3.6 MB — under cap, before any function-level DCE.

## Verdict
The existential risk — the 10 MB module gate — is **retired with ~10× headroom**. A full durable-actor
workload (the production-shaped target) fits comfortably, AOT is performant (faster than a JS backend),
and the interpreter is a usable cold/dynamic tier. Spike A clears the go/no-go.

## Caveats (honest)
- **Multiplier is optimistic.** ~1× comes from trivial integer functions. Pattern matching, bit-syntax,
  maps, guards, and closures will expand more (plausibly 1.5–4×). Still fits.
- **Fixed runtime base not counted here.** The BIF library + scheduler + interpreter + term ops are a
  one-time Wasm cost on top of the app closure. Calibration: AtomVM ships a whole VM in ~3 MB; budget a
  similar base + the <1–2 MB app closure → still under 10 MB.
- **Interpreter is ~220× slower as written** — a naive string-switch tree-walker that allocates a frame
  per call. An optimized interpreter (numeric opcodes, no per-call allocation, monomorphic dispatch) would
  land ~20–50×. Either way: AOT hot, interpret cold.
- **fib doesn't stress GC.** The cons microbench + Spike C cover allocation/pause behavior (workable for
  small live sets; degrades near the cap).
- **No function-level DCE yet** — whole modules are shipped; real tree-shaking shrinks the closure.

## Reproduce
```
erlc seed.erl && node closure.mjs seed.beam                 # size gate
wasm-as fib_lift.wat -o fib_lift.wasm -all
wasm-as lst_lift.wat -o lst_lift.wasm -all
node --experimental-wasm-jspi perf.mjs                       # 3-way perf + multiplier + projection
```
