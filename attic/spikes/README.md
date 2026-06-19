# Spikes — the evidence the design rests on

Each spike answered a load-bearing question before the compiler was trusted to depend on it. Results are
in each directory's `RESULTS.md` / `README.md`.

- **01-jspi-economics** — Can every Elixir process be a real suspendable Wasm stack? *Yes.* ~5.2KB per
  shallow suspended process (flat 1k→100k), suspend/resume ~1.4–2.2M/s; ~15–25k concurrent under the
  128MB cap. Also: kill-via-unwind composes with JSPI (spike B), and WasmGC objects share V8's heap with
  sub-ms, non-stop-the-world GC pauses (spike C). Runs on Node and on workerd.
- **02-feasibility-gate** — Size and performance go/no-go. *GREEN.* Actor closure ~0.36MB gz bytecode
  pruned vs the 10MB cap (~10–28× headroom); WasmGC ≈ BEAM bytecode size; AOT ~1.7 ns/call (~2.6× a
  JS-backend port, far faster than a BEAM interpreter). Includes the transitive `.beam` import-closure
  walker used to compute that closure.
- **03-durable-statem-eval** — Does OTP discipline actually buy correctness under failure? *Yes.* A naive
  Durable Object double-charges on crash and corrupts on invalid input; a `gen_statem`-style design with
  idempotency keys + transactional commits is correct on all five scenarios (happy/retry/concurrent/
  crash/invalid). This is the product thesis, demonstrated.
- **04-beam-loader-smoketest** — A from-scratch `.beam` container parser + bytecode interpreter (no
  Erlang at runtime) that validated the file format and compact operand encoding. **Superseded by
  `:beam_disasm`** in the real compiler, but kept as documentation of the format and the typed-register
  gotcha that motivated using OTP's disassembler.
- **workflows-comparison-spec.md** — Specification (not yet executed) for the four-way comparison
  (ours / raw-DO / Cloudflare Workflow / Fly-BEAM) that settles where our differentiator is safe vs.
  where Workflows wins. Execution needs real Cloudflare.
