# Contributing

Thanks for your interest! This is an early-stage prototype, but contributions are welcome.

## The bar: every change is bit-exact vs the Elixir VM

The whole project is held to one invariant — **pure Elixir runs on WasmGC bit-exact against the real
Elixir VM, or it's a bug.** The repo proves this with a one-command differential suite. Before you open
a PR, it must stay green:

```bash
# Pin the toolchain Node (the 24.x line; see BUILD.md for why), or rely on tooling.exs auto-discovery:
export NODE=$(which node)        # must be a 24.x build
elixir verify.exs               # full manifest, ~10 min
elixir verify.exs fast          # skips the slow suites (scoreboard, markdown), ~5 min
```

`verify.exs` runs eight differential suites against pinned **exact-count floors** and exits non-zero on
any drop. See `LIMITATIONS.md §4` for what each suite proves.

## Prerequisites

See **`BUILD.md`** for the full toolchain (Elixir/OTP, Node 24.x, Binaryen, optionally workerd). The
versions are pinned in `.tool-versions` / `.nvmrc`.

## Workflow

1. Fork and branch from `main`.
2. Make your change. If you're closing a `LIMITATIONS.md §3` gap, **solve it at the root** (a builtin in
   `compiler/lib/.../codegen/runtime.ex`, a host shim in `runtime/imports.mjs`, or a lowering in
   `.../codegen/emit.ex`) — don't work around it. See `CLAUDE.md` for the working agreement.
3. **Add a differential case** that proves the new behavior (a conformance case is usually the right
   place — see below), and run `elixir verify.exs`.
4. **When a suite grows, raise its floor** in `verify.exs` as part of the same change. A bigger suite
   with the old floor isn't actually enforced.
5. `cd compiler && mix format --check-formatted && mix test` for compiler-internal changes.
6. Open a PR describing what you changed and pasting the relevant `verify.exs` output.

## Adding a conformance case

`conformance/` is the curated per-feature safety net. Add a case there (see existing cases for the
shape), then `cd conformance && elixir run.exs` — it compiles your snippet to WasmGC **and** runs it on
the real VM, diffing the results. Once it passes, bump the `conformance` floor in `verify.exs`.

## Reporting bugs

A miscompile (a value that differs from the VM) is the highest-priority class of bug — please include a
minimal Elixir snippet and the diverging outputs. For anything security-sensitive, see
[`SECURITY.md`](SECURITY.md) instead of filing a public issue.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By participating you agree to abide
by it.
