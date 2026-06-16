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

Verification: eight differential suites vs the real Elixir VM (`elixir verify.exs` in
the repository), pinned floors, zero tolerated lies.

Packaging / quality:

- Public API is `Beam2Wasm.compile/2` and `Beam2Wasm.run/2` (both `@spec`'d); all
  compiler internals are now private (`defp`), so the generated docs describe a real
  API surface rather than the codegen internals.
- Credo (`mix credo`) and `mix format` clean; CI (`.github/workflows/ci.yml`) runs
  format + Credo + ExUnit, plus the differential `verify.exs` gate, on every push/PR.
- `nodeFsBacking` / `nodeSqliteBacking` carry explicit capability-model security notes
  (full-host-FS / arbitrary-SQL authority — wire only to trusted modules).
