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
