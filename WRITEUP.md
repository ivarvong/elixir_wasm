# Elixir, compiled to WasmGC, bit-exact — and live on Cloudflare Workers

*(Or: how a "can a GenServer survive in a Durable Object?" experiment ended with a compiler
that occasionally outruns the BEAM it's imitating — and can prove it's imitating it correctly
while doing so.)*

This repo contains an ahead-of-time compiler from BEAM bytecode to WebAssembly GC, a JSPI
process runtime, and a verification harness whose job is to make every claim in this document
a measurement. The headline claims:

- **Real, unmodified hex packages run byte-identical to the Elixir VM.** Jason 1.4.5 and
  Earmark 1.4.49 — the actual libraries, every LineScanner regex, the leex-generated lexers,
  OTP's `erl_scan`/`io_lib` underneath — render HTML that matches the BEAM byte-for-byte.
- **It's deployed.** Four services run on production Cloudflare infrastructure right now,
  each verified against the VM before and after deploy.
- **One workload now beats the native BEAM by 3.3×** — honestly, with an optimization the
  BEAM doesn't perform, and with the result diffed bit-exact against it.
- **The whole verification surface is one command**: `elixir verify.exs` — eight differential
  suites at pinned floors, ~2.5 minutes, exit 1 on any drop.

Try them:

```bash
# real Jason + Earmark rendering markdown at the edge
curl -s 'https://elixir-markdown.ivar.workers.dev/?seed=0'

# a compiled GenServer callback (guards and all) in a Durable Object, state durable
curl -s 'https://elixir-durable-bank.ivar.workers.dev/?acct=you&op=withdraw&amount=999'
# -> {"reply":":insufficient", ...}    <- that's a `when amt <= balance` guard clause deciding

# compiled Elixir running SQL against the Durable Object's own SQLite (open in a browser for the CRUD app)
curl -s 'https://elixir-sqlite-ledger.ivar.workers.dev/?actor=you&op=report'

# and: Python. interpreted by an Elixir interpreter, compiled to WasmGC
curl -s -X POST https://elixir-python.ivar.workers.dev --data-binary 'print(2**100)'
```

## Why

Cloudflare's edge has things the BEAM never had: instant global placement, per-actor durable
storage (Durable Objects), scale-to-zero, millisecond cold starts. The BEAM has things the
edge desperately lacks: processes, supervision, pattern matching, thirty years of "let it
crash" discipline, and a deep library ecosystem. The bet was that WasmGC — first-class
GC structs and arrays, traced by V8 itself — finally makes the marriage practical without
shipping a garbage collector in linear memory or paying interpreter overhead forever.

So: BEAM terms become real WasmGC heap objects (cons cells are two-field structs, tuples are
arrays, maps are a persistent weight-balanced tree, integers are three-tier
i31 → unboxed-i64 → host BigInt). BEAM bytecode — consumed via OTP's own `:beam_disasm`,
so default `mix compile` output feeds it — compiles function-by-function into a dispatch-loop
block machine. Processes, `send`/`receive`, links, monitors, preemption by reduction budget,
and the *unmodified OTP `:gen_server`* run on a JSPI scheduler. NIFs and effects lower to host
imports: the host decides whether `File.read/1` is a real filesystem, an in-memory one, or a
Durable Object — and an unwired effect traps honestly instead of returning a wrong value.

## The discipline that made it work

One rule, enforced mechanically: **the compiler never lies.** Anything unsupported is a
*counted trap* — it raises with a name, it never produces a wrong value silently. And every
change proves itself bit-exact against the real VM before it lands:

| suite | what it proves | floor |
|---|---|---|
| `conformance/` | curated per-feature cases, every term type and runtime mode | 203/203 |
| `fuzz/` | a randomized ledger service, rolling-hash diff vs the VM | 33/33 |
| `gaps/` | 20 realistic programs, **0 stubs = provably supported** | 20/20 |
| `genfuzz/` | *generated random programs* over the whole term algebra | 12/12 (+40/40 sweeps) |
| `regexdiff/` | 76-case PCRE corpus: every divergence classified, **zero lies** | 68 exact · 4 documented · 4 honest refusals |
| `scoreboard/` | every public function of ten stdlib modules, generated calls | 389/389 (100%) |
| `demo/markdown` | real Jason + Earmark, byte-identical HTML | 3/3 |
| `demo/effects` | File/IO through the host-effects ABI vs the real fs | ✓ |

The suites aren't decoration — they're where the bugs died. A sampler of what differential
testing caught that code review never would have: `get_map_elements` is *one* instruction in
BEAM, so a destination register may alias the source map mid-instruction (found by bisecting
Earmark's parser byte-by-byte); JS `String.split()` silently injects capture groups into
results where `:re.split` drops them; PCRE's bare `$` matches before a final newline and JS's
doesn't; `\K` doesn't error in JS — it silently matches a literal "K"; Erlang's
`binary_to_integer/2` accepts a leading `+`, discovered because Python's `round()` goes
through Decimal, whose exponent parser emits `'+2'` charlists, three layers down.

## What runs (a tour of escalating absurdity)

**The markdown pipeline.** JSON → real `Jason.decode!` → real `Earmark.as_html!` → HTML,
byte-identical to the BEAM, ~1,250 full parses+renders/sec in one isolate. Production load
test: 15,000 requests at ~500 req/s, zero errors, p50 46ms / p99 134ms end-to-end (the
compute itself is ~1ms; the network is the rest). Cold start for the 2.9MB module: ~17ms
total. Honest decomposition vs JavaScript: Earmark-on-WasmGC is 3.1× native-BEAM-Earmark;
the ~88× gap to `marked` is ~28× library design (an AST parser vs line regexes) times our
compiler tax.

**The durable GenServer.** `Bank.handle_call/3` — multi-clause, guarded, ordinary OTP
callback code — compiled and installed in a Durable Object. The platform supplies what the
BEAM never had natively: per-actor state that survives restarts, eviction, and *redeploys*.
`idFromName/1` is `whereis/1` with planet-scale registration. The overdraft rejection you get
from the live URL is a compiled guard clause failing over to the next clause.

**SQLite, from inside Elixir.** Durable Objects expose a *synchronous* SQLite handle, which
means compiled Elixir can query mid-computation through a plain host import — the database
as a NIF-shaped capability. `Sqlite.query!("... RETURNING id", params)` with params and rows
riding the compiled Jason both ways. A full-CRUD webapp sits on top; switch the actor name
and you're in a different, isolated, durable database. The differential gate runs the same
seeded CRUD session on the BEAM and on WasmGC against the identical engine: 6/6
byte-identical.

**Python.** [pyex](https://github.com/ivarvong/pyex) is a Python 3 interpreter written in
pure Elixir. The mission statement says any pure Elixir runs here, and pyex is 531 beams and
14,083 functions of pure Elixir, so:

```
your Python ──> pyex (Elixir) ──> BEAM bytecode ──> beam2wasm ──> WasmGC ──> a Worker
```

16/16 Python programs run *transcript-identical* between pyex-on-the-BEAM and
pyex-on-WasmGC — classes, custom exceptions, comprehensions, f-strings, `2**100` exact,
banker's `round()` via Decimal. The deployed service takes `POST /json` with
`{"code": ..., "data": ...}` and returns the **result value itself as JSON** — not by
serializing inside the module, but by letting the host *walk the returned WasmGC term graph
live* through introspection exports. Versus Pyodide (real CPython on wasm): pyodide wins
sustained compute 2–230× (it's a bytecode VM; we're a tree-walker); pyex-wasm wins cold
start 12× (124ms vs 994ms to first answer) and footprint (2.2MB vs ~13MB) — which is the
trade that matters for the agent-tool-call shape it exists for. Exact bignums are the fun
reversal: pyex-wasm computes `2**100` *faster* than CPython-on-wasm.

## The two compiler campaigns worth telling

**The stack cliff, and TRMC.** Wasm gives you the host's stack — ~10⁴ frames — where the
BEAM gives you millions. Body-recursive list building (`[f(h) | rec(t)]` — `lists:map`, every
lexer) overflowed it, and a realistic 7KB payload crashed the deployed Python service to
prove it. The fix is the classic *tail recursion modulo cons*: the compiler detects the
pattern in the bytecode and emits a loop that allocates each cons with a **hole** for the
tail and patches it one iteration later. The mutation is unobservable; the construction order
is provably identical; a million-element recursive build now runs on the default stack,
bit-exact. The test that couldn't exist before is now pinned in conformance. What remains of
the cliff is non-cons recursion (`1 + f(n-1)`, tree folds) — documented, with a 256MB-stack
worker mitigation on Node.

**Cross-op unboxing, and the day it beat the BEAM.** The worst benchmark was a ledger whose
PRNG works on 2⁶¹–2⁶⁴-range integers: 4.8× slower than native, 205,600 host-BigInt calls per
op. The observation: those values are heap-allocated bignums *on the BEAM too* — native pays
arbitrary-precision multiplication in that loop. And `(x*c + d) rem 2^64` depends only on
`x mod 2^64` — exactly. So the compiler now fuses integer-op chains into raw wrapping-i64
arithmetic in shadow locals, governed by a small soundness lattice (bounds-proven signed-64 /
congruence-class-mod-2⁶⁴ / canonical-unsigned), boxing only what survives the chain. Result:
**122µs vs the BEAM's 407µs — 3.3× faster than native**, host calls down 36×, verified
bit-exact by three independent suites. The first draft had three real miscompiles; the
generative fuzzer caught all three on a fresh seed before anything shipped, which is exactly
the failure mode the instrument was built for.

Full performance picture, all bit-exact, all reproducible from the repo:

| workload | vs native BEAM |
|---|---|
| JSON decode (real Jason) | 3.2× |
| realistic order processing | 2.4× |
| complex pipeline | 2.7× |
| Decimal portfolio | ~4× |
| markdown (real Earmark) | 3.1× |
| **mod-2⁶⁴ ledger (PRNG/hash)** | **0.3× — faster than native** |

## What it can't do (the honest section)

The canonical line lives in `LIMITATIONS.md`; the short version: no runtime code generation
(the interpreter tier is the designed answer, not yet productionized); the non-cons recursion
cliff above; `__STACKTRACE__` is empty (exceptions work, traces aren't recorded — probably
the first thing a production user would want); three classified regex deltas and last-ulp
transcendental differences between libm and V8 (measured: 3 of 40 haversine pairs differ in
the 16th digit); map iteration order for >32-key maps is key-sorted where BEAM's is
hash-ordered (both unspecified by the language); time is currently a deterministic counter
rather than a wall clock. Every one of those is *detected or documented* — the invariant the
whole project is built on is that nothing fails silently.

## The takeaway

The thing I'd want a reader to keep isn't any single number — it's the method. Every gap got
built instead of worked around; every build got verified against the original instead of
eyeballed; every benchmark kept its unflattering rows. The result is a compiler you can
extend aggressively — TRMC and the unboxing lattice both landed in an afternoon each —
because a 250-case differential suite, two fuzzers, and a 392-function scoreboard will catch
you the moment you're wrong. They did, repeatedly, and that's why the fast paths can be
trusted.

`elixir verify.exs` — eight suites, one command, all green.

---

*Everything here was built in a multi-day collaboration with Claude (Opus 4.8), working from
"review this project" to production deploys — compiler passes, fuzzers, benchmarks, and this
document included. The differential harnesses kept both of us honest.*
