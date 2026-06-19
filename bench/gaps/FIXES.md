# Closing the gaps — progress log

Driven by the 20-program gap corpus (`run.exs`). Every fix is gated on: conformance **147/147**,
fuzz **33/33**, and the corpus (programs flipping trap → bit-exact). Compiler edits in `beam2wasm.exs`.

## Batch 1 — landed & validated (corpus: 3 → 5 programs fully bit-exact)

1. **Tuple BIFs** (`tuple_to_list`, `list_to_tuple`, `setelement`, `make_tuple`, `append_element`,
   `insert_element`, `delete_element`). Pure WasmGC array ops. Required making `$tuple` a **mutable**
   array (to build new tuples) — which made it structurally identical to the internal `$kv` array, so
   the two were **unified** into one type (kv arrays never escape to user code, so it's safe).
   → flipped **p10** (vending FSM) to 8/8.
2. **`:math` tail** — `pow/floor/ceil/log2/log10/atan` were whitelisted but `math_funs_used` only
   matched `:call_ext`, missing **tail calls** (`call_ext_only`/`call_ext_last`); broadened the match
   (and `float_op?` for robustness). The host already provides these.
3. **`:binary` search/split family** (`split/2,3`, `match/2`, `matches/2`, `at/2`, `replace/4`,
   `compile_pattern/1`, `erlang.split_binary/2`) — naive byte search + copied sub-binaries. So
   **`String.split`** works (incl. `parts:`/`trim:`). Added a `$bin_join` helper for replace.
   Moved `$list_has_atom` to a builtin (was proc-gated); forced atoms `:global`/`:nomatch`/`:trim`.
   → flipped **p12** (JSON doc) to 8/8.
4. **`$ftab` table gating** — a DCE-kept-but-unexecuted `call_indirect $ftab` (e.g. a stdlib
   higher-order fn whose closure arg isn't built on the taken path) left a dangling table reference →
   wasm-as failure. Now emit an (empty if needed) `$ftab` table whenever any closure type is in play.

Fully bit-exact now: **p03, p10, p12, p13, p20**. (No compiler *lies* anywhere — still 0.)

## Batch 2 — closure/apply ABI for CAPTURED ext funs (corpus: 5 → 8 bit-exact)

Root cause: a captured fun (`&abs/1`, `&Tuple.to_list/1`, `&Atom.to_string/1`, `&is_list/1`, `&band/2`,
`&>=/2`, …) is stored in BEAM as a **literal fun value** (or `:erlang.make_fun`). When applied (via
`call_fun`→trampoline or the `apply` instr) it routes to the generic `$apply_N(args, mod, fun)` which
switches on the interned `(mod_idx, fun_idx)`. Captured *ext* functions had no clause there (and DCE had
pruned their would-be bodies), so dispatch fell to `(unreachable)`. Three coordinated fixes in `beam2wasm.exs`:

1. **DCE roots** — `do_reach` now also follows `literal_funs_in/1` (captured fun MFAs), so a captured
   *user* function (e.g. `&Enum.sum/1`) survives pruning and gets its normal `apply_N` clause.
2. **Capture wrappers** — `capture_wrappers/1` synthesizes a real `$Mod.fun_arity` for each captured
   *inline-BIF* ext MFA that has neither a user body nor a builtin shim, using the SAME mode-aware
   expressions as the inline lowering (`capture_wrap_body/1` + shared `type_test_i32/2`): `abs`,
   `byte_size`/`bit_size`, `map_size`/`tuple_size`/`length`, `hd`/`tl`, bitwise `band/bor/bxor/bsl/bsr`,
   comparisons `==/=:=/</>/>=/=</…`, arithmetic `+/-/*//rem` (float-aware), and all `is_*` type tests.
3. **apply_N clauses** — `ext_capture_clauses/N` emits a dispatch clause for every captured ext MFA that
   resolves to a builtin shim, a capture wrapper, or a gated extra (`atom_to_binary` — its `atom_names?`
   detection was also broadened to count tail-call forms + captures).

Net: every `apply_1`/`apply_2` capture trap is gone. **p06** (matrix: `&Tuple.to_list/1`, `&abs/1`, and
Stream/zip's internal `&:erlang.is_list/1`), **p11** (trie), **p14** (number-theory) flipped to 8/8
bit-exact. p07 advanced past `apply_1` to its next gap (Stream.Reducers.chunk_every). Still **0 compiler
lies**; conformance 147/147 + fuzz 33/33 held. Now 8/20 bit-exact: p03,p06,p10,p11,p12,p13,p14,p20 —
all blocked from "provably correct" only by the SAME 11 latent exception-constructor stubs (next target).

## Batch 3 — numeric/test opcodes in DCE-kept stdlib (corpus: first PROVABLY-CORRECT program)

The capture fix exposed the real "latent stub" floor: opcodes inside DCE-kept-but-unexecuted stdlib
functions. Implemented (all mode-aware, gated on conformance 147/147 + fuzz 33/33):
- **`round/1`, `trunc/1`** (→ integer; integer arg passes through unchanged so bignums survive; float
  arg converts — round is half-away-from-zero like Erlang via `trunc(x + copysign(0.5,x))`).
- **`float/1`** (number → float).
- **`is_number` test** (integer-any-tier OR float); factored the type-test exprs into shared `type_test_i32/2`.
- **`bs_get_binary2` / `bs_get_float2`** (older binary-match forms): sub-binary extraction (runtime
  size, `:all`=rest) advancing the `$mctx`; 64-bit big-endian float read via new `$read_f64_be` builtin.

Result: **p14 (number-theory) is PROVABLY CORRECT** (0 stubs, 8/8 — the first). The other 7 bit-exact
programs (p03,p06,p10,p11,p12,p13,p20) dropped to the SAME 2 honest latent stubs. Still **0 lies**.

### KEY ARCHITECTURAL INSIGHT — the universal 2-stub floor

The 2 remaining stubs on every Enum-heavy program are `Float.round/3` and `bs_init_writable`, both
**DEAD** (never executed — programs are 8/8 bit-exact). They are pulled in by a SOUND, unavoidable DCE
rule: the BEAM `{:apply,3}` instruction (used by `Enum.count/member?/empty?/slice` for Enumerable
protocol dispatch, and by GenServer for `apply(Mod,:handle_call,…)`) forces "keep ALL arity-3 functions"
because the target module is a runtime value. That collateral includes `Float.round/3`, whose body needs
**non-byte-aligned bitstrings** (it bit-matches an IEEE-754 double: sign=1, exp=11, **mantissa=52 bits**).
Our `$binary` is a whole-byte array, so a 52-bit bitstring has no faithful representation.

Consequence: reaching literal **0-stubs on the apply-using programs requires a real bitstring subsystem**
(a bit-length-carrying binary type + sub-byte match/construct). This is the same machinery p18 needs. It
is the single universal blocker to "provably correct" across the Enum-heavy corpus. INTEGRITY NOTE: we
deliberately keep `Float.round/3` an HONEST stub rather than byte-truncating the 52-bit field (which would
be a silent lie on a dead path) — consistent with "improve the compiler, never avoid it." p14 is provably
correct precisely because its minimal `extra` (Integer/Bitwise) never triggers the apply/3 keep-all.

## Batch 4 — apply-target DCE precision (corpus: 1 → 8 PROVABLY CORRECT)

Resolved the universal 2-stub floor at its root — soundly, no bitstring overhaul needed. `do_reach`'s
old rule "a function containing `{:apply,n}` keeps ALL arity-n functions" was over-conservative: the BEAM
`apply` instruction puts the target function NAME in `x[n+1]`, and that name is a **compile-time-constant
atom** in every real case (Enumerable dispatch moves `:reduce`; GenServer moves `:handle_call`/`:init`/…).
New `apply_targets/2` + `reg_const_atoms/2` resolve the constant name and keep only arity-n functions WITH
THAT NAME; only if the name is written non-constantly (truly dynamic) does it fall back to keep-all. This
prunes the dead collateral (`Float.round/3`, `bs_init_writable`) that `Enum.count/member?/empty?/slice`
were dragging into every program. **Soundness verified**: conformance 147/147 (incl. the real-OTP
GenServer/Supervisor cases that dispatch callbacks via `apply`) + fuzz 33/33 held.

Result: **8/20 PROVABLY CORRECT** (p03,p06,p10,p11,p12,p13,p14,p20 — 0 stubs, 8/8 bit-exact). The 12
remaining programs now report 0 stubs and trap at their genuine FIRST missing feature (no more dead-code
noise): Enum.aggregate/group_by (p05,p08,p09), String.Chars.to_string=interpolation (p02,p19),
:sets/MapSet (p04), Stream lazy (p07), Regex (p01,p17), unicode NF (p17), binary-protocol (p15,p18),
calendar (p16). Still **0 compiler lies** anywhere.

## Batch 5 — dual closure WITH free vars (corpus: 8 → 11 PROVABLY CORRECT)

Real compiler bug. A "dual" target (captured AND called directly) was ASSUMED to have 0 free vars, so
its funcref-table wrapper `__c` was typed `$clos{total_arity}` and passed all args straight through. But
`Enum.aggregate_by`'s `fun-0` is dual AND has a free var: called directly as `f/2` (line in aggregate_by_4)
and captured with 1 free var → invoked through the table as `$clos1` (call arity = 2−1). Wrapper typed
`$clos2` but called as `$clos1` ⇒ "null function or function signature mismatch" trap. Fixed `clos_wrappers`
to type the wrapper `$clos{callar}` (callar = total−nf), read the nf free vars out of `self`, and tail-call
the real function with `(call-args ++ free-vars)` (free vars in the HIGH slots, per the closure ABI);
degenerates to the old pass-through when nf=0. Unlocked **p05** (frequencies), **p08**/**p09** (group_by) →
**11/20 PROVABLY CORRECT**. conformance 147/147 + fuzz 33/33 held. Still 0 lies.

## Batch 6 — String.Chars.to_string + the `:lists.member` identity bug (corpus: 11 → 12)

- **String.Chars.to_string/1** (string interpolation `#{}` + `Enum.join` element conversion): gated shim
  dispatching on runtime type — binary→itself, integer→`integer_to_binary`, nil→"", atom→`atom_to_binary`
  (forces `atom_names?`). `to_string?/1` detector + `extra_defined`. (float/charlist left as honest stub.)
- **`$lists.member_2` used `ref.eq` (identity) not value equality** — a real latent bug. It only matched
  reference-equal elements, so `x in [literals]` (which lowers to `:lists.member`) worked ONLY when the
  needle was pool-shared with the list (e.g. `String.split("lit",…)` is constant-folded to interned
  binaries) and silently returned false for distinct-but-equal binaries (runtime-built/parsed strings).
  Found by the corpus: enabling to_string let p02 run further and `r.dept in @depts` (parsed CSV fields)
  reported 0/41 valid. Fixed to use `term_eq`. (keyfind/keymember already used `term_compare`;
  `$list_has_atom` compares atoms only, where `ref.eq` is correct.)

Result: **p02 PROVABLY CORRECT → 12/20**; p19 advanced past interpolation to `:sets`/MapSet. conformance
147/147 + fuzz 33/33 held (the member fix touches every `in`/`:lists.member`). Still 0 lies. NOTE:
`$erlang.integer_to_binary_1` is still i31-only (`ref.cast (ref i31)` traps on i64/bignum) — fine for the
corpus, but a real tier gap to close for arbitrary-precision `to_string`.

## Batch 7 — MapSet / :sets v2 (corpus: 12 → 14 PROVABLY CORRECT)

MapSet delegates to OTP `:sets` v2, which is map-backed (a set is `#{Elem => []}`); its hot ops compile
to inline map instructions (is_map_key / put_map_assoc), so only a few BIFs needed shims. Added `:sets`
to the harness `@default_extra` (it's always-present OTP stdlib; the compiler compiles it fine) and added
builtins: `maps.from_keys/2`, `maps.iterator/1` (= flattened {k,v} cons-list), `maps.next/1`
(`{k,v,next}` | `none`), `proplists.get_value/3` (for the `{version,2}` option). Unlocked **p04** (graph
BFS/DFS/components) and **p19** (relational set algebra: union/intersection/difference) → **14/20
PROVABLY CORRECT**. conformance 147/147 + fuzz 33/33 held. 0 lies.

Remaining 6: p01/p17 Regex, p07 Stream lazy (chunk_every), p15 (1 stub in its own intify), p16 (?),
p17 unicode NF, p18 non-byte-aligned bitstrings.

## Batch 8 — float comparison + float literals + float→int tiers (corpus: 14 → 15)

p15 (physics/stats on floats) surfaced a cluster of real float bugs (all gated on conformance 147/147 +
fuzz 33/33):
1. **`term_rank` had no `$float` case** → floats fell to rank 8 (no handler) so `term_compare` returned
   "equal" for EVERY float pair → `Enum.sort`/`min`/`max`/`<` on floats silently wrong. Added float→rank 0
   (it's a NUMBER, sorts with ints). THE big one.
2. **`$int_cmp` / `$to_f64` didn't handle the float (and i64/bignum) tiers** — comparing a float (or a
   boxed-int vs float) hit `to_big(float)` → illegal cast. `$int_cmp` now f64-compares when either side is
   a float; `$to_f64` now converts `$i64`/bignum (new `big.to_f64` host import, lossy past 2^53 like BEAM).
3. **Float literals as VALUES were a SILENT LIE** — `operand/1` had no `{:float, _}` clause, so a float
   passed as a function arg/list element (e.g. `percentile(sorted, 0.25)`) became `(ref.null none)` in STUB
   mode. Added the boxed-`$float` clause + taught `float_op?` to treat a bare float literal as float-mode.
4. **`trunc`/`round`/`floor`/`ceil` were i32-only** (overflow trap past 2^31) — now use the i64 tier via
   `$narrow` (`f64_to_int/1`); honest trap past 2^63.
5. **`Float.floor/ceil/round` (precision 0)** shimmed via `float_builtins` as `float(floor/ceil/round f64)`
   (precision > 0 needs sub-byte IEEE decomposition → honest trap); DCE treats them as leaves so the dead
   `Float.round/3` bit-machinery is pruned (→ 0 stubs). Sub-byte bitstrings remain the one deferred piece.

→ **p15 PROVABLY CORRECT, 15/20.** (Also caught+fixed a paren-balance regression in the non-float
`$int_cmp` wrapper before it shipped — gaps float-mode programs hid it; conformance's int programs caught it.)

Remaining 5: p01/p17 Regex (+ p17 unicode NF), p07 Stream lazy (chunk_every), p16 calendar, p18 non-byte-
aligned bitstrings.

## Batch 9 — calendar codegen + Stream/Enumerable protocol (corpus: 15 → 17)

- **p16 (calendar)**: pure build-config — `wasm-as -all` emits `exact` heap types (custom-descriptors)
  Node 24 rejects; we don't use RTTs, so build with `-all --disable-custom-descriptors`. → PROVABLY CORRECT.
- **p07 (RLE/Huffman)**: `Enum.chunk_every` → `Stream.Reducers.chunk_every/5` → `Enumerable.reduce` →
  `impl_for` → `Code.ensure_compiled`. Added `Stream.Reducers` + the `Enumerable`/`Enumerable.List/Map/
  Range` impls to the harness modules, and shimmed `Code.ensure_compiled/1 → {:module, mod}` (closed world:
  every shipped module is "compiled", so the UNconsolidated protocol dispatch resolves instead of trapping).
  The apply-target DCE keeps it tight — `apply(impl, :reduce, …)` has constant F=`:reduce`. → PROVABLY CORRECT.

**17/20.** Remaining 3 are each a large subsystem: **p01/p17 Regex** (needs a real `:re`/regex engine,
likely a host RegExp shim), **p17 unicode NF** (normalization tables), **p18 non-byte-aligned bitstrings**
(a bit-length-carrying binary type + sub-byte match/construct — the one deferred core piece). 0 lies throughout.

## Batch 10 — bitstring seed + UTF-8 charlist (corpus: 17 → 18)

- **`bs_init_writable`** → an empty `$binary` (the `<<acc::binary, …>>` appends already lower to
  bs_create_bin `:private_append`, which copies). Unblocked p18's `seed_bytes` — but p18 then hit
  `<<v::size(n)>>` with a RUNTIME sub-byte width (1-7 bits): genuine non-byte-aligned construction.
- **`:unicode.characters_to_list/1`** (backs `String.to_charlist`): native UTF-8 byte→codepoint-list
  decoder builtin. → **p17 PROVABLY CORRECT** (it's a hand-rolled glob matcher over charlists; the only
  gap was UTF-8 decode, NOT regex/normalization as first assumed).

**18/20 PROVABLY CORRECT** (from 1 at the start of this push), **0 compiler lies** throughout, conformance
147/147 + fuzz 33/33 green at every step. Real compiler bugs found+fixed along the way: captured-fun apply
ABI; apply-target DCE precision; dual-closure-with-free-vars; `$lists.member_2` identity-vs-value equality;
`term_rank` missing `$float` (all floats compared equal → sort/min/max broken); float-literal-as-value
silent lie; float/i64/bignum tiers in int_cmp/to_f64/trunc/round.

## Batch 11 — p01 partial (regex works; real binary_part bug fixed); still 18/20

Pushed p01 through several layers (each a real fix, all gates green): **regex** (`Regex.split/3` host JS
RegExp shim — extract `%Regex{}.source` via `struct.get $mnode 1` on `$map_get`, frame parts back as
`<<count:32,(len:32,bytes)…>>`, decode + `:trim`); added `String.Break`/`Enumerable*`/`Stream.Reducers`
to the harness modules; and **fixed a genuine bug: `$binary_part` ignored NEGATIVE length** (Erlang's
"extract backward from Start" — `binary_part(b, start, -3)` = bytes `[start-3, start)`); it did
`array.new_default(-3)` → "array too large" trap. Now adjusts `start += len; len = -len`. (String.Break.
trim_trailing relies on this.) p01 now advances to `:string.titlecase` (String.capitalize) — partially
shimmed via host, but capitalize passes a grapheme structure, not a plain `$binary`, so the arg-type needs
work — and then `String.reverse`/`pad_leading`/`slice`/`replace` remain: p01 is effectively "make the whole
String module bit-exact", a long tail. Left at an HONEST trap (no lie).

## Batch 12 — p01 String cascade fixed; blocked by Erlang MAP ITERATION ORDER (a real finding)

Closed the whole String-internals cascade in p01 (all gates 147/147 + 33/33 held):
`:string.titlecase` returns a LIST of codepoints for a list input (not a binary) — `String.capitalize`
pattern-matches is_integer/is_list on the result, so the shim now returns `[upper(cp)|rest]` (host
`str.upchar` single-codepoint upcase) for lists and a binary for binaries; `grapheme_to_binary`
(binary/codepoint/iolist), `:erlang.list_to_bitstring` (=iolist_to_binary, byte-aligned). Plus the earlier
negative-`binary_part` fix and the regex host shim.

p01 then runs end-to-end but DIFFERS on `top_keys = frequencies |> sort_by(-count) |> take(8)`. Root cause
is NOT a compiler bug: with many tie-count-1 bigrams, `take(8)` depends on **map iteration order**, which
Erlang leaves UNSPECIFIED. Erlang switches representation past 32 keys (flatmap, key-sorted → HAMT,
hash-order); our maps are a key-sorted weight-balanced BST. ≤32 keys → both key-sorted (matches); >32 keys
→ Erlang's HAMT hash-order ≠ our sorted order. p01's bigram-frequency map has ~40 keys. Bit-matching would
require reimplementing OTP's exact internal map hash + HAMT traversal (undocumented, OTP-version-specific)
— infeasible, and our deterministic key-sorted order is arguably the better choice. **p01 is blocked by a
program relying on unspecified Erlang behavior, not by a compiler deficiency.** (Most code sorts before
iterating, so this is a narrow faithfulness gap; the corpus's other map-using programs all `fold_map`-sort.)

## Remaining (the two genuine subsystems)
- **p01** — Erlang HAMT map-iteration order (>32-key maps). Infeasible without OTP internals; the String
  cascade is otherwise fully fixed.
- **p18** — non-byte-aligned bitstrings (`<<v::size(n)>>` runtime 1-7-bit fields). The one tractable-but-big
  core piece left.

## Remaining 2 (each a large subsystem)

- **p01 — Regex** (`String.split(~r/\s+/, trim: true)` → `Regex.split/3` → the `:re` engine). Tractable
  only via a host JS `RegExp` shim (extract `%Regex{}.source`, split in JS, frame the parts back as a
  length-prefixed binary, decode to a cons list, apply `trim`). Risk: JS RegExp vs Erlang PCRE semantics
  could diverge → a lie; needs care. (p01's other op, `String.replace(doc,"o","0")`, is plain-string, works.)
- **p18 — non-byte-aligned bitstrings** (`<<v::size(n)>>` runtime 1-7-bit fields; `pack_bits`/`unpack_bits`).
  The one genuinely large core piece: a bit-length-carrying binary type + sub-byte match/construct (also
  what a TRUE-correct `Float.round/3` would need). No host shortcut.

## Remaining roadmap (ordered by impact × tractability)

Each is a subsystem; they cascade (fixing one reveals the next), so they're best done as deliberate,
separately-validated batches:

- **Exceptions / `raise`** — `:erlang.error/1,2,3`, `throw/1`, and built-in `*.exception/1`
  constructors (`ArgumentError`/`KeyError`/`RuntimeError`/`Enum.EmptyError`/`OutOfBoundsError`).
  `try/catch` already works; `raise` builds an exception struct + `:erlang.error`. (Blocks p08 overdraft, etc.)
- **Protocols** — `Enumerable` (reduce/count/member?/slice for Stream/Range/MapSet via `Enum`),
  `Collectable.into` (`Map.new`, `Enum.into`, `for into:`), `String.Chars.to_string` (string
  interpolation `#{}`). The single biggest pervasive blocker. Needs protocol dispatch / consolidation.
- **MapSet / `:sets`** — set algebra (`add_element`/`union`/`intersection`/`subtract`/…). Blocks p01/p04/p19.
- **Deep String/Keyword closure path** — `String.replace` → `Keyword.get` → a `call_indirect` whose
  `make_fun3` isn't detected (closure-make detection misses some form). A real detection bug.
- **Numeric** — base-N `integer_to_binary/2`/`binary_to_integer/2`/`integer_to_list/2`/`list_to_integer/2`;
  `Float.round/3`; `Kernel.**`; float text `float_to_binary/2`. (Blocks p14 number-theory, p15 stats.)
- **`Stream`** lazy combinators (`Stream.Reducers.chunk_every/chunk_by`).
- **`Regex`** (`match?/split/replace`) — needs a real `:re` shim. (Blocks p17 if it used it — it doesn't.)
- **Unicode normalization** (`:unicode.characters_to_nf*_binary`); `inspect/1`.

## Codegen finding (separate from stdlib)

- **p16 won't instantiate**: `wasm-as -all` emits an `exact` heap type Node 24 rejects without
  `--experimental-wasm-custom-descriptors`. Pin the wasm-as feature set (or pass the node flag).

Likely-spurious gap-list entries (DCE-reachable, never executed; not worth fixing): `rand.uniform`,
`Process.sleep`, `Macro.Env.in_guard?`, `IO.warn`, `Dict.update`, `jaro_similarity`.
