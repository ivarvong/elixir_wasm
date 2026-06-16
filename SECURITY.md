# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for anything
exploitable.

- Preferred: open a [GitHub private security advisory](https://github.com/ivarvong/elixir_wasm/security/advisories/new)
  ("Report a vulnerability" on the Security tab).
- Or email **ivar@ivarvong.com** with `SECURITY` in the subject.

Please include a description, affected component, and a minimal reproduction. You'll get an
acknowledgement within a few days. This is a prototype maintained on a best-effort basis; there
is no formal SLA, but credible reports will be triaged and credited.

## Scope

This project is a BEAM→WasmGC compiler (`compiler/`), a host runtime (`runtime/`), and a set of
demos. The compiler **trusts its `.beam` inputs** — it is a build tool you run over code you
already chose to compile, not a sandbox for untrusted *bytecode*. The security boundary that
matters at runtime is described below.

## Capability model (the threat model)

The isolation primitive is the **WebAssembly sandbox** (a V8/`workerd` isolate). Compiled Elixir
runs inside it and **cannot reach the host** — no filesystem, network, clock, or database —
*except* through host imports that the embedder explicitly wires in.

By default, capabilities are **deny-by-default**: unwired effects throw an honest
"not wired in this host" stub rather than silently succeeding (see `compiler/priv/host.mjs`). No
shipped demo worker wires a real outbound `fetch`/HTTP backing, so there is no SSRF surface in the
deployed examples.

**The critical caveat:** *host imports carry full host authority.* When you wire a backing, the
compiled module inherits exactly that capability, unrestricted, for as long as it runs. In
particular, two backings in `runtime/imports.mjs` grant broad authority and perform **no**
confinement:

| Backing | Authority granted | Restriction |
|---|---|---|
| `nodeFsBacking` | Reads/writes any path on the host filesystem | **None** — no root prefix, no `..` normalization, no allowlist |
| `nodeSqliteBacking` / `doSqliteBacking` | Executes any SQL the guest emits (incl. DDL / `PRAGMA` / `ATTACH`) | **None** — params are parameterized, but the statement text is guest-controlled |

An embedder who wires either of these to **attacker-influenced compiled code** inherits
path-traversal / arbitrary-file-I/O and arbitrary-SQL respectively.

### Guidance

- **Untrusted or third-party Elixir → use the in-memory backings.** `memFsBacking` keeps file
  effects in a `Map`; leave SQL/HTTP/crypto unwired (they trap honestly).
- **If you need real host effects with untrusted code,** wrap the backing yourself:
  realpath-confine `nodeFsBacking` to a fixed prefix; give SQL an isolated/read-only database or a
  statement allowlist.
- **Demo error bodies are verbose by design** — the example workers return the demangled Wasm
  frame name on a trap to aid debugging. Sanitize error responses before exposing a worker
  publicly.

## What the sandbox does *not* protect against

- A backing you explicitly wired (see above).
- Resource exhaustion beyond the platform's own limits — the runtime relies on the host
  (workerd/V8) CPU and memory caps for runaway-program containment.
- The build step — `mix wasm.build` / `beam2wasm` execute as your user over the `.beam` files you
  give them.

## Supported versions

This is pre-1.0 (`0.x`). Only the latest `main` receives fixes.
