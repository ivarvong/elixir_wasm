# Arbitrary-precision integers (fintech-grade exactness)

Erlang/Elixir integers are arbitrary-precision; money math must never silently overflow. Default i31
terms wrap at ±2^30. The `BIGNUM` compiler mode gives a tiered integer that is exact at any size:

- **i31** small ints — fast, unboxed (the common case).
- on overflow, a **boxed JS BigInt** — `(struct $big (field externref))`, arbitrary precision.

`+`/`-`/`*` route through helpers (`$int_add/$int_sub/$int_mul`) that test operand types: both i31 →
compute in i64 and **narrow** back to i31 if it still fits, else box; otherwise promote both to BigInt
(host) and **demote** the result if it fits again. BigInt arithmetic is done by the host
(`a+b`, `a*b`, …); the engine's `BigInt` is the bignum.

## Exactness — factorial across every overflow boundary (vs the Elixir VM)
| n  | tier crossed            | result                                                              |
|----|-------------------------|---------------------------------------------------------------------|
| 12 | i31 (fits)              | 479001600                                                           |
| 13 | overflow i31 → boxed    | 6227020800                                                          |
| 20 | boxed, still ≤ i64      | 2432902008176640000                                                 |
| 21 | exceeds i64 → BigInt    | 51090942171709440000                                                |
| 25 | BigInt                  | 15511210043330985984000000                                          |
| 50 | BigInt (65 digits)      | 30414093201713378043612608166064768844377641568960512000000000000  |

**All EXACT — bit-identical to the Elixir VM's native bignums.** No silent wrap at i31 or i64.

## Cost
- Small ints that never overflow: the i31 fast path inside the helpers — one type-test + i64 widen +
  narrow + a call. Measured **+50%** on `fib(30)` (an adversarially arithmetic-dense, all-small workload)
  vs i31-inline. Real code is less arithmetic-saturated, so lower.
- Default mode is unchanged (opt-in): the five existing programs still pass bit-for-bit.

## The real answer to that +50%: type-driven specialization
The +50% is the cost of treating *every* `+`/`*` as polymorphic. It need not be. `:beam_disasm` already
exposes BEAM's type analysis — the typed registers we saw, e.g. `{:tr, {:x,0}, {{:t_integer, ...}}}`.
Where the compiler can prove an operand is a bounded small integer, it emits the inline i32 path; only
genuinely-unknown sites pay the tiered call. So the production story is: **exact by default, fast by
analysis** — and the analysis is already in the IR we consume.

## Honest scope
Comparisons (`<`, `>=`, `==`) still assume i31 in this mode — fine for the demo (factorial's loop
counter stays small while the accumulator grows), but full generality needs tiered comparisons too
(another `$int_lt`/`$int_eq` pair, same shape). Boxing every overflowing result allocates a small struct
+ holds a JS BigInt; a real impl might keep a middle i64 tier unboxed (i31 → i64 → BigInt) to defer the
externref. The mechanism — detect, promote, demote — is complete and exact.
