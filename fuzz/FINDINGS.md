# Findings — bugs surfaced by the ledger fuzz, and their fixes

The fuzzer (`run.exs` + `ledger.ex`) found three real `beam2wasm` bugs that the hand-written
conformance corpus missed. All three are now fixed in `../compiler/beam2wasm.exs`; the fuzz is
`33/33` and conformance stays `147/147 (100%)`.

The common thread: the corpus only ever did `+ - * > ==` on bignums and only `Enum.sort`ed lists
of *bare ints*. A realistic service mixes tiers (small ints and bignums in the same operation),
flows values through `Enum`/`Map` (where the compiler can't prove they're integers), passes large
arguments, and does bitwise math on big values. Each of those hit an unguarded fast path.

---

## 1. `$num_+/-/*` truncated/trapped on the mixed-tier path

**Symptom.** `illegal cast` trap whenever `+`/`-`/`*` ran on a value the compiler could not prove
was a small integer — e.g. anything flowing out of `Enum.reduce`/`Map.get`. With both operands
small it instead silently wrapped at 31 bits.

**Root cause.** BEAM emits a generic `gc_bif :+/:-/:*` on `t_number` operands (could be int *or*
float), which the compiler lowered to `$num_add/$num_sub/$num_mul`. Their integer branch assumed
both operands were `i31`:

```wat
(else (ref.i31 (i32.add (i31.get_s (ref.cast (ref i31) $a))
                        (i31.get_s (ref.cast (ref i31) $b)))))   ;; casts → trap on $big; wraps on overflow
```

`mix(h, x)` worked when `h` came from a literal (proven int → `$int_add`) but trapped when the
identical value came from `snapshot`'s `Enum.reduce` (top-typed → `$num_add`). Same source,
different surrounding code, different result — the tell-tale of a type-inference-dependent path.

**Fix.** The non-float branch now delegates to the tiered `$int_*` helper (i31 fast path with
`$narrow` overflow-promotion; bignum fallback), which already handles every int tier correctly.

---

## 2. int-argument export wrapper truncated args above 2^30

**Symptom.** Every seed below 2^30 passed; `seed = 2147483646` (2^31−2) produced a *wrong value*
(not a trap), localized by the bisector to op #2.

**Root cause.** The generated export wrapper boxed `int` arguments as `(ref.i31 (local.get $p))`.
An `i32` param can carry values up to 2^31−1, but `ref.i31` keeps only 31 bits, so any argument
with `|x| > 2^30` was silently truncated before the function ever ran.

**Fix.** In bignum mode the wrapper narrows through i64 —
`(call $narrow (i64.extend_i32_s (local.get $p)))` — producing a boxed `$big` when the value
exceeds the i31 range instead of truncating.

---

## 3. bitwise ops trapped on bignums and `bsl` silently truncated

**Symptom.** `band`/`bor`/`bxor`/`bsr` on a boxed bignum trapped `illegal cast`; `bsl` that
overflowed the small-int domain returned `0` (`1 bsl 40 → 0`) instead of promoting — a *wrong
answer*, the most dangerous kind.

**Root cause.** All five were lowered as `(ref.i31 (i32.wrap_i64 (i64.<op> (i64val a) (i64val b))))`.
`i64val` does `ref.cast (ref i31)` (→ trap on `$big`), and `i32.wrap_i64`→`ref.i31` truncates the
result to 31 bits (→ silent overflow).

**Fix.** New tiered helpers `$int_band/$int_bor/$int_bxor/$int_bsl/$int_bsr`:
`band`/`bor`/`bxor` keep an i31 fast path (their result provably fits i31) and fall back to host
`BigInt` for any boxed operand; `bsl`/`bsr` always go to the host (a shift can over/underflow the
i31 range unpredictably). Five `big.*` host imports back them, with Erlang two's-complement and
negative-shift-count semantics (`bsl` by `-n` ≡ `bsr` by `n`). Verified against the VM, e.g.
`5 bsl 40 = 5497558138880`, `bxor`/`band`/`bsr` on 3×10^18 all bit-exact.

Host functions added to every bignum runner's `big` object (`conformance/driver.mjs`,
`runtime/scheduler.mjs`).
