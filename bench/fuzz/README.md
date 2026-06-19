# Fuzz — a full service, differentially fuzzed against the Elixir VM

A stress test for the `beam2wasm` compiler: build a realistic **clearinghouse ledger** service,
drive it with large streams of **random** operations, run the *same* code on WasmGC and on the
real Elixir VM, and verify the results are **bit-exact**. The goal is a test where it is
essentially impossible to pass unless the compiler is genuinely correct — and where any
divergence localizes to a single operation.

```bash
elixir run.exs            # default grid: 10 seeds × {50, 500, 5k} ops + three 50k–100k runs
elixir run.exs 200000     # also append a heavy nops=200000 run
```

`ledger.ex` is the service; `run.exs` is the harness (it reuses `../conformance/driver.mjs`).

## The service (`ledger.ex`)

`Ledger.run(seed, nops)` is a **pure deterministic function**. A 64-bit PRNG seeded by `seed`
generates `nops` random ledger operations — `open / deposit / withdraw / transfer / accrue
interest / snapshot` over 16 accounts — each applied to an in-memory double-entry ledger. After
the stream, a rolling hash is folded over the entire final state and returned as one integer.

It is shaped to force every term type and compiler feature onto the hot path:

| Construct | What it exercises |
|---|---|
| 64-bit LCG (`s * 6364136223846793005 + …`) | bignum multiply + rem every step |
| compounding interest | balances crossing the i31 → i64 → bignum tiers |
| account map, `Map.put/get`, `Map.keys` | maps |
| `Enum.sort` over `{balance, id}` tuples | term ordering on (possibly bignum) tuples |
| `Enum.map` / `Enum.reduce` with closures | closures capturing the map |
| overdraw → `throw` / `catch` | exceptions |
| the op loop (`loop/6`) | recursion via real Wasm tail calls (safe at 100k+ depth) |
| xorshift hash (`bxor`/`bsr`/`band` on 2^61 values) | **bitwise on bignums** |

## Why it can't pass while broken — three amplifiers

1. **The PRNG runs inside the compiled code.** Both sides generate the op stream from the same
   seed, so if integer arithmetic is even slightly wrong the two streams diverge at op #1.
2. **A rolling avalanche hash folds the entire state.** A single wrong term — one mis-sorted
   balance, one bad bignum carry — explodes into a completely different final integer. There is
   no "mostly right" pass. The hash function is itself compiled, so a bug in it reveals itself.
3. **Order-dependence makes divergence chaotic.** A wrong comparison flips a transfer from
   success to rejected, which changes every downstream balance, which (because amounts depend on
   current balances) changes every subsequent random decision. A correct run and a one-bit-wrong
   run share *nothing* after the first divergence.

When a case mismatches, the harness **bisects `nops`** to report the first op count at which Wasm
and the VM disagree — and since the seed is fixed, that case replays deterministically.

## Result

`33/33` bit-exact vs the VM, including two 100k-op runs and a seed above 2^31. Getting there
surfaced **three real compiler bugs**, all now fixed — see [`FINDINGS.md`](FINDINGS.md). The
full conformance suite (`../conformance`) remains `147/147 (100%)` after the fixes.
