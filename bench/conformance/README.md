# Conformance — differential testing vs the Elixir VM

The safety net that makes scaling the compiler safe. For every corpus entry it compiles the
Elixir module to WasmGC (via `../../beam2wasm.exs`), runs each case **on Wasm and on the
real Elixir VM in-process**, and diffs bit-exact. One command, one honest coverage number.

```bash
elixir run.exs              # whole corpus + category matrix + overall %
elixir run.exs binaries     # only categories matching a substring
```

- `driver.mjs` — generic Node runner: encodes typed args / decodes typed results via the
  compiler's JS bridges (`cons`/`bin_alloc`/…), emits a canonical string per case.
- `run.exs` — orchestrator + corpus. Each entry: `%{cat, src, extra: [Module,…], cases}`.
  Types bridged today: `int | bool | atom | bin(string) | list(of ints)`. A module that fails
  to build reports `BUILD_ERR` for its cases instead of crashing the run.

## Baseline (2026-06-08): **131/131 (100.0%)** bit-exact vs the VM 🎉

> **Milestone:** real, unmodified OTP runs on WasmGC. A `use GenServer` on the *actual*
> `:gen_server`/`:gen`/`:proc_lib`/`:sys` stack (`real-genserver`), and a whole non-trivial app —
> a real `Supervisor` starting a named `GenServer` KV store with map state + `Enum`
> (`supervised-app`) — both bit-exact vs the VM. Covers proc_lib spawn + sync init handshake,
> the monitor-alias call/reply, supervisor child specs, `hibernate`, old-style `catch`, dynamic
> funs (`make_fun/3`), and the map/list NIFs the OTP stack reaches.

> Design note: `sort`/`max`/`min` are **not shimmed** — the *real* pure-Erlang `:lists.sort`/`max`/`min`
> are compiled in, on top of a correct `$term_compare` (full Erlang term order). The compiler also
> reports `STUBS: N unsupported reachable` (function- *and* opcode-level); **0 ⇒ provably supported**.

Green: arith, lists, tuples, maps, binaries/strings, closures/HOF, real `Enum` over lists,
negatives, **bignum** (exact arbitrary-precision integers under `BIGNUM=1`: i31 fast path, a
host `BigInt` box on overflow — `fact(50)` to 65 digits, plus `>`/`>=`/`==` *on boxed bignums*
via a tiered `$int_cmp` and `$big`-aware term order), **exceptions** (`try`/`catch`/`raise` →
Wasm exception handling: value- and
class-based catch, *and nested* `try` — the handler stack is threaded through BEAM's per-try
Y register, so a throw in a catch body unwinds to the enclosing `try`), **processes**
(spawn/send/receive on the preemptive JSPI scheduler), **genserver**
(module-based GenServer via `apply` dispatch), **supervisor** (links + `trap_exit` → restart a
crashing worker), and **registry** (named processes, send-by-name, `Process.monitor`/`{:DOWN,…}`).
Process cases run via `../runtime/scheduler.mjs`, each in a fresh scheduler; their oracles run in a
fresh Elixir process (so `trap_exit`/mailbox don't leak across cases — a leak the harness itself
caught). **Every category is green — 100%.** The real `String` module (`string-mod`) runs on top
of native UTF-8 (`unicode:characters_to_binary`), codepoint grapheme iteration (`unicode_util:gc`),
and host-delegated case mapping (`String.Unicode.upcase` → a `str` import, like `math`/`big`); plus
`byte_size` on a match context and `:append` binary segments.

> Note: the `recursion` category tests `fact` up to `12!` (exact within i31's ±2³⁰ fast path);
> `13!`+ exact arbitrary precision lives in the `bignum` category (`BIGNUM=1`). Making bignum the
> *default* (so fast mode never wraps) is gated on type-driven arithmetic specialization to avoid
> the always-on tax — see ROADMAP.

✓ Closed via the harness loop: **bignum** (tiered `$int_cmp` + `$big`-aware term order → exact
arithmetic *and* comparison), **exceptions** (`try`/`catch`/`raise` → Wasm EH, incl. class-dispatch +
nested), `Enum.sort`/`max`/`min` (correct `$term_compare` + real `:lists.sort`/`max`/`min`),
`Enum.uniq`/`dedup` (real `Map` primitives), `Enum.member?` (`:lists.member`), `element/2`/`tuple_size`,
`abs`/`min`/`max`, `length`/`hd`/`tl`.

**Workflow:** before adding a feature, run this; after, run it again. Coverage must go up and
nothing may regress. Add corpus entries as new constructs are supported.
