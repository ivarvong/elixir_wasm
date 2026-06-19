# Changelog

## v0.1.0 (unreleased)

First packaged version. Highlights, in the order they were earned:

- BEAM bytecode → WasmGC via `:beam_disasm` (default `mix compile` output feeds it).
- Three-tier exact integers (i31 → unboxed i64 → host BigInt); floats; binaries +
  sub-byte bitstrings; maps as a persistent weight-balanced tree; closures; exceptions
  on Wasm EH; processes/links/monitors/preemption on a JSPI scheduler.
- Host-boundary shims for NIFs and effects (regex, crypto, fs/io, SQL) — an unwired
  effect traps honestly, never returns a wrong value.
- Closed-world protocol self-consolidation; function-level DCE from export seeds.
- TRMC (tail recursion modulo cons): list-building recursion at 10^6+ elements on the
  default stack.
- Cross-op i64 chain fusion: mod-2^64 integer chains run as wrapping machine arithmetic
  (the bignum-bound ledger benchmark runs 3.3x FASTER than native BEAM, bit-exact).
- `mix wasm.build`: compile any Mix project to a deployable module + Worker scaffold.

Stdlib coverage: the API scoreboard now covers seventeen modules, **487/487** public
functions bit-exact (added `Atom`, `Bitwise`, `Access`, `Function`, and the calendar trio
`Date`/`Time`/`NaiveDateTime`). `Atom.to_charlist/1` drove a new `:erlang.atom_to_list/1`
builtin (composed from `atom_to_binary` + `unicode.characters_to_list`, UTF-8-correct).
The calendar modules came almost entirely from *feeding the pure modules they delegate to*
(`Calendar`, `Calendar.ISO`, …) — the compiler already compiles those; they just weren't
fed. Clock-readers (`utc_now`/`utc_today`/`now`) are classified nondeterministic, not failures.
`scoreboard/run.exs all` runs a non-gating **full-coverage map** over the remaining frontier
(Base/Path/Version/Regex/DateTime) — an enumerated backlog of gaps to drive down.

Feeding simplified: `Tooling.stdlib_closure/1` feeds a broad set of pure stdlib beams minus the
host-shimmed denylist, and the compiler's function-level DCE prunes whatever the export seeds
don't reach — so the scoreboard's ~40-line hand-curated feed list collapsed to one call, and new
modules' delegates (Calendar, :filename, …) light up automatically. Verified: feeding 12 unrelated
modules to a program yields byte-identical output (DCE prunes them). Caveat (later measured, and
worse than first written): for protocol/dispatch-heavy programs the DCE is far weaker — one
`to_string` reaches the consolidated dispatch, which statically links *every* impl, so it keeps
~everything (`N of N`). Small builds rely on **curation** (consolidated protocols + a trimmed
stdlib), not DCE precision; the robust whole-program version (RTA/0-CFA) is diagnosed but unbuilt.
See `docs/LIMITATIONS.md` §3.

Real third-party libraries: `demo/calc-parser` runs the **unmodified `nimble_parsec`**
combinator library — a recursive-descent arithmetic grammar with operator precedence,
parentheses, left-associativity, and runtime AST construction — compiled to WasmGC with
**zero unsupported constructs**, producing byte-identical JSON ASTs vs the VM (13/13,
including error cases). The only externals were pure stdlib delegates (`Keyword`/`Map`/
`Enum`/`:lists`), fed and compiled.

Verification: nine differential suites vs the real Elixir VM (`elixir verify.exs` in
the repository), pinned floors, zero tolerated lies.

Packaging / quality:

- Public API is `Beam2Wasm.compile/2` and `Beam2Wasm.run/2` (both `@spec`'d); all
  compiler internals are now private (`defp`), so the generated docs describe a real
  API surface rather than the codegen internals.
- Credo (`mix credo`), `mix format`, and Dialyzer (`mix dialyzer`, strict flags:
  `error_handling`/`extra_return`/`missing_return`) all clean. Dialyzer found one dead
  clause (`s64op(:bsl)` — unreachable; `:bsl` gets its `:shl` wop from `transition/4`),
  now removed. CI (`.github/workflows/ci.yml`) runs format + Credo + Dialyzer + ExUnit,
  plus the differential `verify.exs` gate, on every push/PR.
- `nodeFsBacking` / `nodeSqliteBacking` carry explicit capability-model security notes
  (full-host-FS / arbitrary-SQL authority — wire only to trusted modules).
