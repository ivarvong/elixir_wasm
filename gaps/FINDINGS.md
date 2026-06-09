# Gap hunt — 20 realistic programs, differentially tested vs the Elixir VM

20 realistic, **deterministic, pure** Elixir mini-applications (`p01..p20`, ~200–250 lines each), each
deriving all data from a `seed`, exercising a broad stdlib surface, and folding every intermediate into
a rolling checksum returned as one integer. The harness (`run.exs`) compiles each to WasmGC and runs
`run(seed)` on Wasm **and** the real VM across 8 seeds, diffing bit-exact. A single miscompiled stdlib
function anywhere changes the checksum; the compiler's own `STUBS: N` meter flags unsupported-but-reachable
functions.

```
elixir run.exs          # all 20
elixir run.exs p14      # filter
```

## Headline results

- **0 compiler "lies."** No program produced a *wrong number* — every failure is an honest **trap**
  (a stubbed/unsupported function reached at runtime) or a build/instantiate issue, never a silent
  miscompute. Where the compiler compiles, it is correct.
- **3 programs ran fully bit-exact across all 8 seeds** despite having latent stubs: `p03_expr_evaluator`,
  `p13_poker`, `p20_calc_interp`. These confirm correctness of: deep recursion, multi-clause dispatch &
  guards, tuple-as-data ASTs, bignum arithmetic, maps as environments, hand-written tokenizers/parsers,
  char-by-char binary matching, sorting, comparison.
- **~95 distinct unsupported stdlib functions enumerated** (the master gap list, below) — the corpus's
  main product. Most programs trap because realistic Elixir leans on these constantly.

> Note on the gap list: it is the set of unsupported functions **reachable in the call graph** (the
> compiler's DCE keeps them), which is a superset of functions actually hit at runtime. High-count
> entries ([19]/[20]) are stdlib-internal functions pulled in by common `Enum`/error/protocol paths;
> low-count entries are program-specific. A few (`rand.uniform`, `Process.sleep`, `Macro.Env.in_guard?`)
> are almost certainly spurious DCE pulls, not real needs.

## The gaps, grouped (and roughly ordered by impact)

1. **Tuple BIFs** — `tuple_to_list/1`, `list_to_tuple/1`, `setelement/3`, `make_tuple/2`,
   `insert_element/3`, `delete_element/2`, `append_element/2`. Very common (`Tuple.*`, `put_elem`, the
   checksum kit's own `Tuple.to_list`). **Highest leverage** — fixing these alone would let many programs run.
2. **Protocols** — `Enumerable.reduce/count/member?/slice` (so `Enum`/`Stream` over non-lists, `Range`,
   `MapSet`), `Collectable.into/1` (`Map.new`, `Enum.into`, `for ... into:`), `String.Chars.to_string/1`
   (**string interpolation `#{x}`!**). A large, pervasive gap.
3. **String / binary scanning** — `:binary.split/match/matches/replace/at/compile_pattern`,
   `split_binary/2`, so **`String.split` is unsupported**; plus `String.duplicate/2`,
   `starts_with?/ends_with?` (string pattern), `next_grapheme`, `:string.titlecase`.
4. **Exceptions** — `:erlang.error/1,2,3`, `throw/1`, `nif_error/1`; struct construction
   `ArgumentError/KeyError/RuntimeError/Enum.EmptyError/Enum.OutOfBoundsError.exception/1`;
   `Exception.normalize/3`, `Kernel.Utils.raise/1`. (try/throw/catch works; `raise`/`reraise` and
   raising built-in exceptions do not.)
5. **:math** — `pow/2`, `floor/1`, `ceil/1`, `log2/1`, `log10/1`, `atan/1` (only a subset of `:math` is
   imported today). Also `Kernel.**/2` (the power operator) and `Float.round/3` (rounding with precision).
6. **Numeric formatting / parsing** — base-N: `integer_to_binary/2`, `binary_to_integer/2`,
   `list_to_integer/2`, `integer_to_list/2`; float text: `float_to_binary/2`, `float_to_list/2`.
7. **List subtraction** — `:erlang.--/2` (the `--` operator).
8. **Stream** — `Stream.Reducers.chunk_every/5`, `chunk_by/3` (lazy `Stream` combinators).
9. **MapSet / sets** — the `:sets.*` family (`add_element`, `union`, `intersection`, `subtract`,
   `is_subset`, `fold`, `from_list`, …). Set algebra is largely unsupported.
10. **Unicode normalization** — `:unicode.characters_to_nf{c,d,kc,kd}_binary/1` (`String.normalize`).
11. **inspect** — `Kernel.inspect/1` ([20], pulled into nearly every error path).
12. **Non-byte-aligned bitstrings** — `p18`'s `pack_bits/2` was stubbed: building a **sub-byte/10-bit
    packed bitstream** isn't supported (byte-aligned `<<>>` is — see below).

## Map iteration order — a semantic boundary, not a compiler bug (p01)

`p01_text_analytics` surfaced as an apparent **compiler lie** (a wrong checksum with 0 stubs). A
checkpoint bisector localized the first divergence to one line that ranked bigram frequencies via
`top_keys`, which sorted by count **alone** (`fn {_, c} -> -c end`) and broke ties by **map
iteration order**. Decomposition proved the map *contents* were bit-identical (an order-independent
`fold_map`, which sorts its input, matched); only the *iteration order* differed.

Root cause is a representation difference, **not** a miscompile:
- The WasmGC runtime stores maps as a weight-balanced BST → iteration is **key-sorted**.
- BEAM stores ≤32-key maps as a **flatmap** (also term-sorted — so small maps agree) but **>32-key
  maps as a 16-ary HAMT** keyed by the OTP-internal `make_internal_hash` (a MurmurHash3 finalizer
  over the internal hash), emitted slot-15→0 reversed-depth-first. That order is **not** key-sorted,
  not `phash2`, not term order. (Verified against the OTP-28 source: `erl_map.{c,h}`,
  `erl_term_hashing.c`; `MAP_SMALL_MAP_LIMIT = 32`.)

That's why the **unigram** frequency map (≤27 vocab words → flatmap → sorted both ways) matched, but
the **bigram** map (>32 distinct → HAMT) diverged. Elixir documents map iteration order as
**unspecified**, and the OTP order is an implementation detail that is not even stable across OTP
minor versions — so replicating it in the runtime would be both impractical and wrong.

**Resolution:** fixed the corpus program to use a **total** sort key `{-c, k}` (matching its own
sibling `ranked` sort, which always agreed), making it deterministic across conforming
implementations. p01 is now provably correct (8/8). Lesson for the corpus and for users: never rank
or fold a >32-key map by a non-total key — sort by a tuple that includes the key. (The ARCHITECTURE
map-representation section notes the key-sorted iteration order as a deliberate, documented delta.)

## Codegen / tooling findings (not stdlib gaps)

- **`exact` heap types under `wasm-as -all` (RESOLVED).** `wasm-as -all` emits a newer WasmGC feature
  (exact references / custom descriptors) that stock Node 24 rejects at instantiation ("invalid heap
  type 'exact'"). Fixed by passing `--disable-custom-descriptors` (we don't use RTTs); this is now the
  canonical flag set in `tooling.exs` (`Tooling.wasm_as_args/3`), applied uniformly across all harnesses.
  `p16_calendar_engine` — which originally exposed this — is now provably correct (8/8).

## What this says about the compiler

The supported **core** is solid and *honest*: arithmetic (incl. bignum), pattern matching, guards,
recursion, tuples/lists/maps as data, byte-aligned binaries, comprehensions, closures, `Enum` over lists
— all bit-exact where exercised, and unsupported functions trap loudly rather than lie. The gaps are in
the **stdlib breadth**: protocols, the `:binary`/`String.split` family, tuple/set/Stream/Regex/`:math`
tails, base-N conversion, and `raise`. Closing the top three groups (tuple BIFs, protocols,
`:binary.split`) would flip most of these 20 programs from "trap" to a full differential signal.
