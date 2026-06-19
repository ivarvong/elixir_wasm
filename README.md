# Elixir on WasmGC

**An experiment: compiling pure Elixir/BEAM, ahead-of-time, to WebAssembly GC — and checking the
output against the real Elixir VM.**

I wanted to learn WasmGC, so I pointed it at a hard target: the BEAM. Elixir's runtime — immutable
term graphs, lightweight processes, OTP, "let it crash" — is about as far from WebAssembly's
threadless, linear-memory world as you can get. But WasmGC adds first-class GC structs and `i31ref`,
which looked like just enough to make it work. So I tried. WasmGC runs lots of places now — browsers
and server-side runtimes alike — so the approach isn't tied to any one host. The venue I was most
curious about is Cloudflare Workers, where Durable Objects look like a natural fit for single-owner,
strongly-consistent state machines — "Durable Objects with OTP discipline."

This is a prototype and a learning project, not a product. Below is the question I set out to answer,
what actually works, and — since it's the more useful half — what doesn't.

> **TL;DR.** A surprisingly large slice of real, *unmodified* Elixir (including `Jason`, `Earmark`,
> and the actual OTP `:gen_server`) compiles to WasmGC and produces the same output as the real VM —
> checked program-by-program by a one-command differential suite. It is **correct but slow** — 5–23×
> the BEAM on realistic workloads
> today, for understood and fixable reasons. The product thesis (durable OTP state machines at the
> edge) is demonstrated locally and **unproven at scale**.

## See it run

Five demos, live on Cloudflare Workers — real Elixir compiled to WasmGC:

- **[Markdown render](https://elixir-markdown.ivar.workers.dev)** — unmodified `Earmark` + `Jason`, byte-identical to the VM
- **[Elixir × SQLite × Durable Objects](https://elixir-sqlite-ledger.ivar.workers.dev)** — Elixir querying a DO's SQLite
- **[A GenServer in a Durable Object](https://elixir-durable-bank.ivar.workers.dev/?acct=A&op=deposit&amount=50)** — compiled OTP, state durable across restart
- [Portfolio rebalancer](https://elixir-rebalancer.ivar.workers.dev) · [Python-on-Elixir-on-Wasm](https://elixir-python.ivar.workers.dev)

## The question

Take ordinary compiled Elixir (`.beam` files), with no source changes, and:

1. run it on WasmGC and get the **same output** as the reference VM, and
2. host the non-pure parts (NIFs; file/network/crypto) at the Wasm **import boundary** — the way the
   BEAM hands them to the OS.

If both hold, "pure Elixir runs on Wasm" stops being a slogan and becomes a bounded, measurable fact.

## What I found

**A large slice runs, and the output matches — more than I expected.** One command compiles each
program to WasmGC *and* runs it on the real Elixir VM, then diffs the two:

```
elixir verify.exs
✅ conformance 219/219   ✅ fuzz 33/33     ✅ gaps 20/20         ✅ genfuzz 12/12
✅ regexdiff 0 lies   ✅ scoreboard 487/487   ✅ markdown 3/3   ✅ calc-parser 13/13   ✅ effects
```

That includes real, unmodified hex libraries (`Jason` encode + decode, `Earmark`) and the actual OTP
`:gen_server` / `:proc_lib` / `Supervisor` — not reimplementations. The scope is **bounded and
enumerated, not universal**: 219 conformance cases, 389 stdlib functions, with the remaining gaps
tracked in [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md). The aim is "any pure Elixir runs, or it's a
logged bug" — an aim with a gap list, not a finished guarantee.

**It's correct but slow — that's the real result.** On realistic term-heavy workloads it currently
runs **5–23× slower than the BEAM** (`jason-decode` ~20×, `realistic-order` ~23×, a ledger service
~5× time and ~20× allocation). The cause is understood: every BEAM term becomes a heap-allocated GC
struct, and effects cross a host-call boundary. Where arithmetic fuses to native `i64`, it matches or
beats the BEAM. So it's an engineering gap with a known shape, not a fundamental wall — but I didn't
close it.

**The host-boundary model for effects works.** File / IO / crypto / HTTP are Wasm imports the host
fills: real fs and sockets on Node, a virtual filesystem + `fetch` on Workers. An unwired effect
**traps honestly** rather than silently returning wrong data. Real `Req` + `:crypto` run this way.

**The product thesis is plausible but unproven where it counts.** A compiled `GenServer` runs inside a
live Durable Object with state surviving restart — locally, on `workerd`. The numbers that would
actually validate "durable OTP at the edge" — throughput, tail latency, cost-per-actor at scale —
need real Cloudflare and are **not measured**. The part that matters most is the part I haven't tested.

## What this is not

- **Not production-ready.** A prototype to learn from.
- **Not a complete BEAM.** No distribution, no ETS as such; NIF/BIF coverage is shim-deep; the
  scheduler is a single global reduction budget, not per-process run queues.
- **Not fast** (see above).
- **Not validated at scale.**

## Prior art

I'm not the first to point Elixir at Wasm. **[Lumen / Firefly](https://github.com/GetFirefly/firefly)**
were AOT compilers, now dormant. **[Popcorn](https://popcorn.swmansion.com/)** runs real BEAM bytecode
in the browser, interpreted. The main difference here is the target: it compiles to **WasmGC**, so
terms are native GC structs instead of a hand-written heap in linear memory. To know it actually works,
I also run each program on the real Elixir VM and compare the output. WasmGC runs in browsers and
server-side runtimes alike, so where it ends up running is open — I've mostly exercised it on Cloudflare
Workers. Whether compiling to WasmGC is a good idea is one of the things I wanted to find out.

## How it works

`.beam` → OTP's own `:beam_disasm` → a per-function BEAM→WAT emit path → Binaryen → one WasmGC module.
Terms map to GC structs (i31 / cons / tuple / map / binary / atom / fun); integers are a three-tier
ladder (i31 → unboxed i64 → host BigInt). Function-level dead-code elimination prunes self-contained
code — but it's *sound, not yet precise*: a single protocol call reaches the consolidated dispatch,
which statically links every impl, so for protocol-heavy programs it currently keeps ~everything, and
small builds rely on a **curated feed**, not DCE smarts (see [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md)
§3). The design and every standing decision are in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Reproduce

```bash
git clone https://github.com/ivarvong/elixir_wasm && cd elixir_wasm && mix deps.get
mix wasm.doctor          # checks the toolchain (Node 24, Binaryen 130, optional workerd)
elixir verify.exs        # the differential suite above — one command, vs the real Elixir VM
```

`mix test` runs the package's unit tests; [`docs/BUILD.md`](docs/BUILD.md) pins the exact toolchain
(Node 24, Binaryen 130, Erlang/OTP 27, Elixir 1.17). Everything was measured on the real
V8 / WasmGC / JSPI engine, and where noted on `workerd` itself — not estimated.
