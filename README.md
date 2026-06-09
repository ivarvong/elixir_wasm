# Elixir on the edge — an AOT Elixir→WasmGC runtime for Cloudflare Workers

**What this is.** A working prototype and design package for running **Elixir/BEAM programs on
Cloudflare Workers** by ahead-of-time compiling a subset of Elixir to **WebAssembly GC (WasmGC)**, with
**Durable Objects** as the durable, single-owner actor substrate. It is built around one product thesis:

> The most defensible first product is a **durable, single-owner, strongly-consistent state machine at
> the edge** — "Durable Objects with OTP discipline." Think order lifecycles, idempotent payments,
> per-account ledgers: correctness-critical entities that benefit from BEAM's programming model and from
> the edge's durability and latency.

This repo proves the path end-to-end on the real engine and hands the build team the design, the
compiler, a running example, and measured runtime guarantees — plus an honest map of what is real vs.
modeled vs. still open.

---

## Status at a glance

| Area | State | Evidence |
|------|-------|----------|
| Substrate (JSPI stacks, kill/unwind, shared-heap GC) | **proven on workerd/V8** | `spikes/01-jspi-economics` |
| Feasibility gate (size + perf go/no-go) | **GREEN** | `spikes/02-feasibility-gate` |
| Frontend: real Elixir → WasmGC via OTP's `:beam_disasm` | **working compiler** | `compiler/` |
| Non-trivial programs (merge sort, an interpreter, a map state machine) | **compiled, validated vs Elixir VM** | `compiler/examples` |
| Running in a Durable Object on workerd, durable across restart | **working** | `durable-object/` |
| Cold start, preemption, arbitrary-precision integers | **measured** | `measurements/` |
| Per-process scheduler, throughput/latency/cost at scale | **open — needs real Cloudflare** | `ROADMAP.md` |

**One-line takeaways from the measurements:** per-DO instantiation ~10µs (workerd-confirmed);
reduction-counted preemption suspends the Wasm stack via JSPI at +14% worst-case overhead and prevents
thread monopolization; integer arithmetic is exact at arbitrary precision (`fact(50)` bit-identical to
the Elixir VM).

---

## Read in this order

1. **`ARCHITECTURE.md`** — the design and every standing decision with rationale (the *why*). Start here.
2. **`compiler/README.md`** — how the compiler works, what BEAM opcodes it covers, the two opt-in modes.
3. **`durable-object/README.md`** — the compiled state machine running as a DO on workerd.
4. **`measurements/README.md`** — the three runtime guarantees, measured.
5. **`spikes/`** — the substrate validation and feasibility work the whole thing rests on.
6. **`ROADMAP.md`** — phased build plan: proven / modeled / open, effort buckets, priorities.
7. **`BUILD.md`** — exact toolchain and commands to reproduce every result.

---

## 60-second quickstart (after `BUILD.md` sets up the toolchain)

```bash
# Compile a real Elixir program (a merge sort) to WasmGC and run it
cd compiler
elixirc examples/mergesort.ex                       # -> Elixir.Sort.beam
elixir beam2wasm.exs Elixir.Sort.beam > sort.wat    # BEAM -> WAT, via :beam_disasm
wasm-as sort.wat -o sort.wasm -all                  # Binaryen -> WasmGC binary
node --experimental-wasm-jspi examples/runsort.mjs sort.wasm

# Run the compiled state machine as a Durable Object on workerd
cd ../durable-object
workerd serve config.capnp     # http://127.0.0.1:8791
curl 'http://127.0.0.1:8791/?id=acct&event=new&amount=100'
curl 'http://127.0.0.1:8791/?id=acct&event=deposit&amount=50'
```

---

## What "the team needs to build this" means

The prototype establishes feasibility and the shape of the system. Turning it into a runtime is, in
priority order (see `ROADMAP.md`):

1. **Finish the compiler's coverage** — the remaining BEAM opcode tail, binaries/bitstrings, tiered
   comparisons for bignums, multi-clause `apply`, and function-level DCE (the 10MB-gate lever).
2. **Build the runtime base** — the term library, BIF shims (`:crypto`→WebCrypto, `:re`→host, etc.), and
   the scheduler with a real per-process run queue (today it's a shared global budget).
3. **Productionize the two-tier concurrency** — in-isolate JSPI processes + cross-isolate Durable
   Objects, with ETF message serialization over workerd cap'n-proto RPC.
4. **Measure on real Cloudflare** — the numbers that local workerd can't give: scale, latency, cost.

Everything in this repo is a foundation for those four, with the design rationale captured so the team
isn't reverse-engineering intent from code.

---

## Provenance / honesty note

This was produced as candidate due-diligence work. Every measurement here was run on the actual
V8/WasmGC/JSPI engine (and, where noted, on workerd itself), not estimated. Where something is modeled,
hand-written, or elided for the prototype, it is labeled as such in the relevant doc's "Honest scope"
section. The intent is that a skeptical reviewer can reproduce the claims and trust the boundaries.
