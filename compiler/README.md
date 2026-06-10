# beam2wasm.exs — a BEAM → WasmGC compiler in Elixir

A BEAM-bytecode → WasmGC compiler written in **Elixir**, consuming OTP's own **`:beam_disasm`**
(no hand-rolled `.beam` decoder; typed registers normalized, so it ingests **default Elixir output**).
Emits WAT; assembled with Binaryen; run on a WasmGC engine — the Cloudflare Workers substrate model.

It's a small library under **`compiler/lib/`** (`Codegen.Common` leaf helpers, `Codegen.Runtime` the WAT
runtime library, `Codegen.Emit` the emit path, `Beam2Wasm` the orchestration); the top-level
**`beam2wasm.exs`** is a thin CLI shim, so `elixir beam2wasm.exs <beams>` works as shown below.

## `mix wasm.build` — any Mix project to a deployable module

The compiler is also a Mix package. Add it as a path dependency and build straight from a project:

```elixir
# mix.exs
{:beam2wasm, path: "../elixir_wasm/compiler", runtime: false}
```

```bash
mix wasm.build --module Blog --export "render:int->bin" --export "render_md:bin->bin" --worker
```

That compiles the app + every dep + a broad stdlib surface (consolidated protocols preferred,
self-consolidation as fallback, function-level DCE), assembles with Binaryen, and prints the
honest report: module size, unsupported constructs (0 = provably supported; `--strict` enforces),
and called-but-not-fed externals (named traps if ever reached). `--worker` also emits a complete
Cloudflare scaffold — `worker.mjs` (a JSON-args HTTP dispatcher over your exports), `imports.mjs`,
`wrangler.toml`, and a `config.capnp` for local workerd. The markdown demo app built through this
exact path is byte-identical to the VM on all four render checks (`mix help wasm.build`).

One compiler now compiles six programs, all validated against the Elixir VM:

| program        | exercises                                                              | result |
|----------------|-----------------------------------------------------------------------|--------|
| **Account**    | **maps**: `%{...}` construction, `%{m \| k => v}` update, `%{k => v}` match, `is_map`, guards, atom values | a durable state machine — demo(x)=x+15 with status/funds guards holding |
| **Strix**      | **binaries**: `<>`/`<<>>` construction, integer segments, `byte_size`, binary pattern matching (`<<c, rest::binary>>`, literal prefixes) with match-context threading, byte guards | upcase/count/len — bit-exact vs VM, **runs on workerd** |
| **EnumDemo**   | **the real unmodified Elixir `Enum`** compiled in: closures (`fn`/`&`), `Enum.map`/`reduce`/`filter`/`count`/`any?`/`all?`/`reverse`, pipelines | bit-exact vs VM — `Enum` is *Elixir's own source*, not a shim |
| **Expr**       | a small **interpreter**: tuples, atoms, assoc-list env, recursion, 2-level dispatch | demo(x)=x*6+(x-6) ✓ |
| **Sort**       | merge sort: tuples, guards, multi-clause matching, tail calls          | sorts (incl. edge cases) ✓ |
| **Arith/Guards**| arithmetic tail (`div`/`rem`/`band`/`bor`/`bxor`/`bsl`/`bsr`/unary `-`) + type guards (`is_integer`/`is_atom`/`is_list`/`is_binary`/…) | ✓ |
| **Smoke/Lists**| add/dbl/fact/fib, sumto — arithmetic + recursion regression suite      | ✓ |

## Headline for the durable-edge thesis: maps + a state machine
`account.ex` is the shape of the production target — a single-owner, durable state machine — written in
ordinary Elixir and compiled to WasmGC:

    def new(initial), do: %{balance: initial, status: :open}
    def step(%{status: :open, balance: b} = s, {:deposit, amt}) when amt > 0,
      do: %{s | balance: b + amt}
    def step(%{status: :open, balance: b} = s, {:withdraw, amt}) when amt > 0 and amt <= b,
      do: %{s | balance: b - amt}
    def step(%{status: :open} = s, :freeze),    do: %{s | status: :frozen}
    def step(%{status: :frozen} = s, :unfreeze), do: %{s | status: :open}
    def step(s, _event), do: s

`demo/1` folds an event sequence and returns the balance. The frozen-state deposits/withdrawals and the
over-balance withdraw are all correctly ignored (guards + map pattern matching), so demo(x)=x+15 — not
x+115. This is "Durable Objects with OTP discipline," but the discipline is now *compiled Elixir*, not
hand-written.

## What maps took
- **Map term distinct from tuples.** A map is a **persistent weight-balanced BST** (Adams' algorithm)
  of `$mnode` (key/val/left/right/size) — O(log n) get/put, key-sorted iteration. (It started as a flat
  `[k0,v0,…]` array; the perf harness caught the resulting O(n²) bulk build and it was replaced — ~168×
  faster at 10k keys.) The distinct node type also keeps `is_map` and `is_tuple` `ref.test`s from colliding.
- **`get_map_elements`** → BST lookup (`$map_get`, `$term_compare` on keys) per key; jump to the fail label
  if any key is absent. **`put_map_assoc` / `put_map_exact`** → fold a copy-on-write `$map_put`
  (update-in-place-on-copy if present, grow-by-2 if absent) over the k/v list. **`is_map`** →
  `ref.test`. Map literals (`%{}` and constant maps) handled by `materialize`.
- Keys compared with `ref.eq` — uniform over interned atoms (identity) and `i31` (value), same primitive
  the interpreter uses.

## What binaries took (Strix)
- **A `$binary` term distinct from maps/tuples.** `(struct $binary (field (ref $bytes)))` wrapping a
  mutable `(array (mut i8))` — the struct keeps `is_binary` (`ref.test $binary`) from colliding with
  `is_tuple`/`is_map` (the §5 rule again). String literals materialize byte-by-byte from the Erlang
  binary.
- **Construction (`bs_create_bin`).** Segments (string / binary-`:all` / fixed-size integer) are blitted
  into a freshly-allocated byte array at a running offset; total length is computed at runtime (binary
  `:all` segs contribute `array.len`). Integer segments write big-endian. `<>` and `<<>>` both lower here.
- **Matching (the modern `bs_match` family).** A `$mctx` struct `{bytes, bit-position}` is the match
  context. `bs_start_match3` either wraps a binary at bit 0 **or reuses an existing context threaded
  through a recursive call** (OTP's optimization — the context flows through `x0` across `count`'s tail
  recursion). Commands lowered: `ensure_at_least`/`ensure_exactly` (length guards), `integer` (big-endian
  read + advance), `=:=` (literal-prefix compare), `skip`, plus `bs_get/set_position` and `bs_get_tail`.
- **`byte_size`/`bit_size`** → `array.len` (×8 for bits). The JS bridge (`bin_alloc`/`bin_put`/`bin_len`/
  `bin_get`) lets a host build and read `$binary` terms across the boundary — used by `runstrix.mjs` and
  by the workerd demo (`work/workerd-strix/`).

## Arithmetic tail & guards
- gc_bif `div`/`rem`/`band`/`bor`/`bxor`/`bsl`/`bsr` → the matching `i32.*` ops; unary `-`/`+`.
- `{:test, is_integer|is_atom|is_list|is_binary|is_bitstring, …}` → `ref.test` against the right type
  (`is_list` = nil-or-`$cons`; `is_integer` also accepts `$big` in BIGNUM mode).

## Earlier machinery (all still in)
Atoms as interned `$atom` globals (equality via `ref.eq`); literal materialization (ints/atoms/lists/
tuples/maps/**binaries**); `trim` Y-register renumbering resolved statically per block; `select_tuple_arity`;
`{:tr,…}` typed-register unwrap; the `br_table` block-dispatch lowering; Y-registers → Wasm locals;
calls → Wasm calls from `:beam_disasm`'s `{M,F,A}`.

## Closures + the real stdlib (EnumDemo)
The headline for "nontrivial Elixir": **Elixir's own `Enum` module, unmodified, compiled to WasmGC**
beside a user module. `Enum.map(list, fn x -> x*2 end) |> Enum.sum()` runs bit-exact vs the VM.
What it took:
- **Closures.** A `$fun` term = `(struct (field i32 table-index) (field (ref $freevars)))`. `make_fun3` →
  `struct.new $fun`; `call_fun`/`call_fun2` → `call_indirect` through a funcref table. Lambdas compile
  with a `(self, args…)` signature whose prologue copies captured vars from `self` into the high
  registers `x[N..]` (BEAM passes call-args low, free vars high). A named capture `&f/a` that's *also*
  called directly gets a thin closure **wrapper** so both calling conventions work.
- **Module-qualified names.** Every function is `$Mod.fun_arity`, so `Enum` + `:lists` + the user module
  merge without `fun/arity` collisions (the old flat naming couldn't). Calls/captures resolve by the
  module in the BEAM instruction.
- **The list fast paths need no protocols.** `Enum.map`/`reduce`/`filter` over a list dispatch via
  `is_list` to inlined helpers (`-map/2-lists^map/1-1-`) that use only opcodes we already have + `call_fun`.
  `Enumerable`/`Stream`/`try`/`apply`/floats are only the *non-list* paths.
- **`STUB=1`** lowers any function using an unsupported long-tail construct to a trap, so the whole 600+
  function module builds; only ~3 functions get stubbed and none on the exercised paths.
- **BIF shims** (`builtins/0`) provide hand-written WAT for native NIFs the BEAM implements in C — e.g.
  `:lists.reverse/2` (its BEAM body is just `nif_error`). Grown as real programs need them.

Build/run: `examples/runenum.sh` (locates `Enum.beam` via `:code.which/1`).

## Generalized exports
`exports/1` no longer hardcodes a per-module table. Set `EXPORTS="name:argtype,…->ret;…"` (types
`int|bin|atom|list|term`) to emit typed wrappers for any module; the atom table is emitted as an
`;; @atoms [...]` comment so runners can decode atom returns. The legacy per-module table is kept as a
fallback when `EXPORTS` is unset (so the original demos build unchanged).

## Run
    elixirc account.ex
    elixir beam2wasm.exs Elixir.Account.beam > account.wat
    wasm-as account.wat -o account_aot.wasm -all
    node --experimental-wasm-jspi runaccount.mjs account_aot.wasm

    # binaries / strings (Strix): note the EXPORTS spec for the generalized wrapper
    elixirc strix.ex
    EXPORTS="count:bin,int,int->int;upcase:bin->bin;len:bin,int->int" \
      elixir beam2wasm.exs Elixir.Strix.beam > strix.wat
    wasm-as strix.wat -o strix.wasm -all
    node runstrix.mjs strix.wasm                          # diff vs VM, ALL PASS

    # the same compiled-Elixir string code running on workerd:
    cd examples/workerd-strix && workerd serve config.capnp   # :8795
    curl 'http://127.0.0.1:8795/?op=upcase&s=hello%20from%20compiled%20elixir'

## Honest scope
A deliberate slice. Maps are a **persistent weight-balanced BST** (O(log n) get/put; iteration is
key-sorted — a documented delta from BEAM's >32-key HAMT order, see `ARCHITECTURE.md` §5 and
`gaps/FINDINGS.md`); `put_map_exact`'s badkey trap is elided (consistent with the compiler emitting
`{:f,0}` when it proves the key present). Arithmetic is **exact arbitrary-precision by default** (3-tier
i31 → `$i64` → host BigInt; `BIGNUM=0` opts out to wrapping small-int). Only `trim` renumbers Y registers
(not general `allocate`-into-a-live-frame).

Binaries are **byte-aligned**: `bs_create_bin` and `bs_match` assume sizes/positions are multiples of 8
(covers strings and byte data — the overwhelmingly common case), so non-byte-aligned bitstrings
(`<<x::3, y::5>>`), UTF-8 codepoint segments, signed/little-endian integer segments, and float segments
are not yet lowered (they'll raise in the compiler, by design, so the gap is loud not silent). No
external-BIF calls (`String.*`, `:binary.*`) yet — only the compiled `<>`/`<<>>`/`byte_size`/match
primitives.

For the real stdlib (EnumDemo): only **list** enumerables work — non-list `Enumerable` dispatch
(maps/ranges/streams) needs **protocols**, and several Enum functions need **exceptions** (`try`/`catch`,
for `reduce_while`-style early exit) and **`apply`**, both still open. `STUB=1` is a crutch — it traps
unsupported functions instead of dropping them; **function-level DCE** is the principled replacement
(ship only the reachable set, prove it's fully supported). Native BIFs are hand-shimmed one at a time
(`builtins/0`); only `:lists.reverse/{1,2}` so far. The architecture is the right one: an Elixir pass over
`:beam_disasm` emitting WasmGC, now covering maps, binaries/strings, and **closures + the real `Enum`**
end to end, validated bit-for-bit against the VM and running on workerd.
