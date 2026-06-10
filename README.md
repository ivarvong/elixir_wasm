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
| Substrate (JSPI stacks, kill/unwind, shared-heap GC) | **proven on workerd/V8** | `attic/spikes/01-jspi-economics` |
| Feasibility gate (size + perf go/no-go) | **GREEN** | `attic/spikes/02-feasibility-gate` |
| Frontend: real Elixir → WasmGC via OTP's `:beam_disasm` | **working compiler** | `compiler/` |
| Correctness vs the Elixir VM (arith, bignum, floats, strings, maps, exceptions, OTP processes) | **161/161 bit-exact** | `conformance/` |
| Differential fuzzing (a full ledger service, random ops) + 20-program gap corpus | **33/33 + 19/20 provably correct, 0 lies** | `fuzz/`, `gaps/` |
| Real process runtime: spawn/send/receive, links/monitors, GenServer/Supervisor, kill-by-unwind, fairness | **working (JSPI scheduler)** | `runtime/` |
| Real unmodified hex libs (`Jason` encode, `Req` + `:crypto`) on WasmGC | **bit-exact** | `attic/jason-demo/`, `demo/` |
| Running in a Durable Object on workerd, durable across restart | **working** | `attic/durable-object/` |
| Cold start, preemption, arbitrary-precision integers | **measured** | `attic/measurements/` |
| Throughput / tail latency / cost-per-actor at scale | **open — needs real Cloudflare** | `ROADMAP.md` |

**One-line takeaways from the measurements:** per-DO instantiation ~10µs (workerd-confirmed);
reduction-counted preemption suspends the Wasm stack via JSPI at +14% worst-case overhead and prevents
thread monopolization; integer arithmetic is exact at arbitrary precision (`fact(50)` bit-identical to
the Elixir VM).

---

## Directory map

| dir | what |
|---|---|
| `compiler/` | the BEAM→WasmGC compiler (a Mix package: `mix wasm.build`) + CLI shim |
| `runtime/` | shared host imports (`imports.mjs`), JSPI scheduler, term walker, deep-stack helper |
| `verify.exs` | **the** verification manifest — 8 differential suites, pinned floors, one command |
| `conformance/` `fuzz/` `gaps/` `genfuzz/` `regexdiff/` `scoreboard/` | the suites (see LIMITATIONS.md §4) |
| `perf/` | measurement harnesses: constant factors, scaling exponents, allocation, unboxing log |
| `demo/markdown` | real Jason+Earmark, byte-exact; deployed (elixir-markdown) |
| `demo/durable-sql` | Elixir querying the DO's SQLite; deployed (elixir-sqlite-ledger) |
| `demo/pyex` | Python-on-WasmGC via pyex; deployed (elixir-python) |
| `demo/effects` | the File/IO host-effects differential |
| `durable-genserver/` | the compiled GenServer in a Durable Object; deployed (elixir-durable-bank) |
| `interp/` | the BEAM-interpreter tier seed (runtime code loading; roadmap) |
| `attic/` | preserved history — superseded spikes and demos, nothing live |

## Read in this order

1. **`ARCHITECTURE.md`** — the design and every standing decision with rationale (the *why*). Start here.
2. **`compiler/README.md`** — how the compiler works and what BEAM opcodes it covers.
3. **`conformance/`** — the differential safety net: 161 cases run on WasmGC **and** the real Elixir VM,
   diffed bit-exact (arith, bignum, floats, strings, maps, exceptions, processes, real OTP GenServer/Supervisor).
   The single best place to gauge what actually works.
4. **`runtime/`** — the JSPI process scheduler: spawn/send/selective-receive, fair dispatch, links/monitors,
   `trap_exit`, kill-by-unwind, `Process.exit/2`, finite `receive … after`.
5. **`fuzz/`** & **`gaps/`** — a differential fuzzer (random ledger ops) and 20 realistic programs; together
   they enumerate the remaining stdlib gaps and keep the compiler honest (it traps, it doesn't lie).
6. **`perf/`** — attribution + scaling harnesses (these found the map O(n²) and the bignum-boundary tax).
7. **`interp/`**, **`attic/jason-demo/`**, **`demo/`** — a self-hosted BEAM interpreter (hot-reload seed); real
   unmodified `Jason` encoding; real `Req` + `:crypto` — all on WasmGC, bit-exact vs the VM.
8. **`attic/durable-object/`** & **`durable-genserver/`** — the compiled state machine / a real GenServer as a
   Durable Object, state surviving restart (the product thesis, demonstrated).
9. **`attic/measurements/README.md`** — the runtime guarantees, measured.
10. **`attic/spikes/`** — the substrate validation the whole thing rests on.
11. **`ROADMAP.md`** & **`BUILD.md`** — phased build plan, and the exact toolchain/commands to reproduce.

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

**The mission bar:** any non-native (pure Elixir/Erlang) code runs here, bit-exact vs the VM — and if
it doesn't, that's a bug. IO (file, network) is handed back to the **host** at the import boundary
(virtual filesystem on Workers is fine). **`LIMITATIONS.md`** is the canonical line between true limits
(NIF shim fidelity, host-effect availability, runtime codegen, scale) and the enumerated bug inventory
we're burning down.
