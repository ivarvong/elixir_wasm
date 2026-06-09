# perf — measurement-driven optimization (zero guessing)

Two harnesses. Every perf claim must come from one of them: a **reproducible number**, an
**attribution** of where it goes, and a **comparison to the real VM**. Optimize from data, not hunches.

```bash
elixir run.exs            # constant-factor: Wasm vs BEAM us/op + self-time + host-call attribution
elixir run.exs --save     # write perf/baseline.json
elixir run.exs --baseline # diff vs baseline (signed delta per workload — regression gate)

elixir scaling.exs        # complexity: fit the growth exponent per op, flag N², compare to the VM
elixir scaling.exs map    # only probes whose key matches the filter
```

## `run.exs` + `measure.mjs` — constant factors & attribution

For each workload: compile to WasmGC **with `-g`** (so the V8 profile carries real names, not
`wasm-function[N]`), time the Wasm build (median/min over K trials) and the **real VM in-process**,
and attribute the Wasm time two ways:

- **self-time** per function from an in-process V8 sampling profile, demangled (`int_mul`,
  `term_compare`, `Ledger.run/2`) and categorized (user / stdlib / runtime / host / boundary).
- **host-boundary call counts**: every `big.*` call is an op that fell to the bignum tier;
  `from_i64` is an i31 operand lifted into a host BigInt. This quantifies the bignum tax directly.

`baseline.json` + `--baseline` give a signed delta so any compiler change is judged, not guessed.

### What it found (ledger/500)
~75% of runtime is the **JS↔Wasm BigInt boundary** for `add`/`mul` — the hash/PRNG run on 2⁶¹–2⁶⁴
values that never fit i31, so every op pays a `from_i64` lift + a host call + reboxing. The fix it
points to: an **unboxed i64 mid-tier** so 64-bit-fitting values never cross to the host.

## `scaling.exs` + `scaling.mjs` — empirical complexity (kill all N²)

For each operation, run it over sizes 10 → 100k, fit the log-log growth exponent, and **compare
Wasm's exponent to the VM's** so a *compiler-introduced* N² is distinguished from one inherent in
the source. Two probe kinds:

- **bulk** — `op(n)`: total work as a function of n (catches bulk N², e.g. building an n-entry map).
- **isolated** — build the input **once** (a handle JS holds), then time `reps` ops on it: the
  *per-operation* complexity, with the build excluded so it can't mask the op.

> Microbenchmarks lie in specific ways, and this harness was hardened against three: the build
> masking the op (→ isolated probes), front-of-array lookups letting a linear scan exit early
> (→ spread keys across the whole range), and a quadratic op hanging the run (→ per-point crash
> containment + adaptive sizing). Each flaw was caught because the Wasm number disagreed with the VM.

### What it found

| Operation | Wasm exp | VM exp | Verdict |
|---|---|---|---|
| `Map.get` (per op) | ~0.84 (O(n)) | ~0.0 | ❌ linear scan — VM is O(1) |
| `Map.put` (per op) | ~0.89 (O(n)) | ~0.15 | ❌ array copy — VM is O(1) |
| `Map` build (bulk) | ~2.0 | ~1.3 | ❌ **O(n²)** |
| `Enum.map` | — | — | ❌ **stack-overflow** ~10⁴ (body recursion grows the Wasm stack) |
| `Enum.uniq` | ~2.0 | ~1.2 | ❌ O(n²) + stack-overflow |
| `Enum.sort` / `reduce` / `reverse` | ~1.0 | ~1.0 | ✓ clean to 100k |
| `Enum.member?` / `++` in a loop | ~2.0 | ~2.0 | N² but VM equally so → inherent, not the compiler |

## `alloc.mjs` — WasmGC allocation profiler (bytes/op)

WasmGC objects live on V8's managed heap but are **invisible to the JS HeapProfiler sampler**, so we
measure allocation as GC churn: a `--trace-gc` child runs the workload between two markers, and the
parent sums new-space allocation (each Scavenge frees what was allocated since the last) over the
window → **bytes/op**. `conformance/_bench.exs` (BENCH=1) reports it alongside time, Wasm vs BEAM
(BEAM via GC-reclaimed words).

### What it found — allocation is NOT the main gap (we'd have guessed wrong)
Term-heavy workloads are **compute-bound** (15–23× time but only ~4–7× allocation): jason-decode
20.3×/3.8×, realistic 23.2×/6.9×, complex 23.3×/4.5×, decimal 15.3×/6.7×. The bignum-heavy **ledger is
the inverse** — 4.8× time but **19.5× allocation** (the i64 tier fixed its compute; it now boxes every
`$i64`/BigInt). So the binding constraint differs per workload, and the single fix that addresses both
is **type specialization + unboxing**: emit typed locals (i32/i64/f64) that flow between ops without
boxing into heap terms, boxing only at boundaries — this removes the generic boxed-dispatch compute
*and* the allocation simultaneously.

## The kill list (ordered)

1. **Maps were O(n) per op → O(n²) bulk** — ✅ **FIXED.** Replaced the sorted kv array with a
   **persistent weight-balanced BST** keyed by term order (`$mnode`/`$mput`/`$mfind`/`$mbal` in the
   compiler). get/put are now **O(log n)**; in-order traversal = key-sorted, so `$map_kv` flattens to
   the same order the rest of the runtime expects → iteration/equality/ordering unchanged.
   Measured: `Map.get` 0.84→**0.03**, `Map.put` 0.89→**0.19**, bulk build 2.01→**1.16** (168× faster
   at 10k keys), conformance still 147/147. (A binary-search `get` on the old array was tried first
   and reverted — map literals aren't built term-sorted, so the invariant binary search needs wasn't
   universally held; the tree avoids that by construction.)
2. **Body-recursive stdlib overflows the Wasm stack** (`Enum.map`/`filter`/`uniq` via `:lists`) at
   ~10⁴–10⁵ elements. Needs a larger Wasm stack and/or tail/CPS lowering or trampolining.
3. **The bignum boundary tax** (from `run.exs`) — an unboxed i64 mid-tier between i31 and host BigInt.

Each fix is judged by re-running both harnesses: the exponent must drop (scaling) and the signed
delta must improve (run.exs --baseline), with conformance staying 147/147.
