# Build & reproduce

Exact toolchain used to produce every result in this repo, plus the commands to reproduce each. Versions
are what was validated; newer should work with the noted caveats.

## Toolchain

| Tool | Version used | Why / caveats |
|------|--------------|---------------|
| **Node.js** | 24.16.0 (V8 13.6) | Stable JSPI **and** WasmGC. Run with `--experimental-wasm-jspi`. Earlier Node (v22) had crashy JSPI — avoid for the preemption work. |
| **Binaryen** (`wasm-as`) | version_130 | Assembles WAT→Wasm. **Always pass `-all`** (enables GC, i31, exceptions, tail calls, etc.). Older Binaryen may lack `array.copy` / `struct.new` in global initializers, both of which we use. |
| **workerd** | build 2026-06-05 | Cloudflare's runtime. Durable Objects work locally without `--experimental`; JSPI features need `compatibilityFlags=["experimental"]` + `--experimental`. WasmGC is on by default in this build. |
| **Erlang/OTP** | 25 (erts 13.2.2.5) | Provides `erlc`, `erl`, and `:beam_disasm` / `:beam_lib`. |
| **Elixir** | 1.14.0 (on OTP 25) | `elixirc`, `elixir`, `iex`. The compiler script runs under this. |

Notes:
- `:beam_disasm` normalizes typed registers, so **compile Elixir with default flags** — no
  `+no_type_opt` / `ERL_COMPILER_OPTIONS` needed (an earlier hand-decoder required them).
- WAT is assembled with Binaryen, not `wabt` — the bundled `wabt` could not assemble WasmGC.

## Repo layout

```
elixir-wasm-edge/
  README.md            ARCHITECTURE.md   ROADMAP.md   BUILD.md
  compiler/            beam2wasm.exs + README + examples/  (the BEAM→WasmGC compiler)
  durable-object/      worker.js + config.capnp + account_aot.wasm  (DO on workerd)
  measurements/        the 3 runtime-guarantee docs + reproducible harnesses
  spikes/              substrate validation + feasibility gate + evals + Workflows spec
```

## Reproduce: compile & run an Elixir program

```bash
cd compiler
elixirc examples/mergesort.ex                        # default flags -> Elixir.Sort.beam
elixir beam2wasm.exs Elixir.Sort.beam > sort.wat     # BEAM (via :beam_disasm) -> WAT
wasm-as sort.wat -o sort.wasm -all                   # -> WasmGC binary
node --experimental-wasm-jspi examples/runsort.mjs sort.wasm
# expect: sorts incl. edge cases, ALL PASS
```

Same pattern for the others: `expr.ex` (interpreter, `runexpr.mjs`), `lists.ex` (`runlists.mjs`),
`smoke.ex` (arithmetic; called directly). For the **merged** account module (two modules → one Wasm):

```bash
elixirc examples/account.ex                          # -> Elixir.Account.beam + Elixir.AccountAbi.beam
elixir beam2wasm.exs Elixir.Account.beam Elixir.AccountAbi.beam > account.wat
wasm-as account.wat -o account.wasm -all
node --experimental-wasm-jspi examples/runaccount.mjs account.wasm
```

## Reproduce: the Durable Object on workerd

```bash
cd durable-object
mkdir -p state
workerd serve config.capnp        # serves http://127.0.0.1:8791 ; DO state persists to ./state
curl 'http://127.0.0.1:8791/?id=alice&event=new&amount=100'
curl 'http://127.0.0.1:8791/?id=alice&event=deposit&amount=50'      # 150
curl 'http://127.0.0.1:8791/?id=alice&event=freeze'
curl 'http://127.0.0.1:8791/?id=alice&event=deposit&amount=1000'    # ignored (frozen)
# kill workerd, re-run `workerd serve config.capnp`, then GET ?id=alice -> state survived on disk
```

`config.capnp` binds `account.wasm` as a module, declares the `Account` DO namespace, and uses
`durableObjectStorage = (localDisk = "do-disk")` for on-disk (restart-surviving) persistence.

## Reproduce: the three measurements

```bash
cd measurements
# 1. cold start (compile + instantiate, size→time curve)
node --experimental-wasm-jspi bench_coldstart.mjs <wasm files…>
# 2. preemption (overhead + interleaving) — needs REDS-mode modules:
#    REDS=2000000000 elixir ../compiler/beam2wasm.exs Elixir.Smoke.beam > smoke_count.wat  (never yields)
#    REDS=50000      elixir ../compiler/beam2wasm.exs Elixir.Smoke.beam > smoke_yield.wat  (yields)
node --experimental-wasm-jspi preempt.mjs
# 3. exact integers — needs a BIGNUM-mode module:
#    BIGNUM=1 elixir ../compiler/beam2wasm.exs Elixir.Smoke.beam > smoke_big.wat
node --experimental-wasm-jspi bignum.mjs
```

`sanity.wat` / `sanity.mjs` is the minimal JSPI suspend/resume check (run it first if JSPI misbehaves).

## Reproduce: the spikes

Each spike directory has its own `RESULTS.md` / `README.md` with commands. In brief:
- `spikes/01-jspi-economics` — `node --experimental-wasm-jspi harness.mjs` (process economics);
  `spikeB.mjs` (kill/unwind), `spikeC.mjs` (shared-heap GC); workerd configs for the on-runtime runs.
- `spikes/02-feasibility-gate` — `closure.mjs` (transitive `.beam` import-closure walker), `perf.mjs`
  (AOT vs JS-port vs BEAM-interpreter), `*_lift.wat` (hand-lifted WasmGC reference).
- `spikes/03-durable-statem-eval` — `workerd serve config.capnp`, then drive the fault scenarios
  (happy/retry/concurrent/crash/invalid) per its README.
- `spikes/04-beam-loader-smoketest` — the from-scratch `.beam` loader/interpreter (`runbeam.mjs`),
  superseded by `:beam_disasm` but kept as documentation of the bytecode format.

## Engine flags cheat-sheet

- Node, any JSPI/WasmGC work: `node --experimental-wasm-jspi [--expose-gc --max-old-space-size=128] file.mjs`
  (`--expose-gc` + the 128MB cap mirror the Workers isolate for the GC/economics spikes).
- Binaryen: `wasm-as in.wat -o out.wasm -all`.
- workerd: `workerd serve config.capnp` (add `--experimental` only for JSPI-in-workerd configs).
