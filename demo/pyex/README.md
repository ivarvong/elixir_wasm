# Python on WasmGC — the pyex interpreter, compiled

**LIVE: https://elixir-python.ivar.workers.dev** — POST Python source, get the transcript
back (or open it in a browser for the playground). Stateless: each request evaluates in a
fresh interpreter context; a `NameError`/`SyntaxError` comes back as a classified
`error(kind)` transcript, and an unwired capability or runaway program is an honest 500.

```bash
curl -s -X POST https://elixir-python.ivar.workers.dev --data-binary 'print(2**100)'
# ok
# 1267650600228229401496703205376
```

[pyex](https://github.com/ivarvong/pyex) is a Python 3 interpreter written in pure Elixir.
This demo compiles it with `mix wasm.build` and runs **real Python on WasmGC**:

```
Python source ──> pyex (Elixir) ──> BEAM bytecode ──> beam2wasm ──> WasmGC
```

```bash
cd app && mix deps.get && mix compile
mix wasm.build --module PyexWasm --export "eval:bin->bin" --out wasm
cd .. && elixir run.exs
```

## Result

**16/16 Python programs TRANSCRIPT-IDENTICAL** between pyex-on-the-BEAM and pyex-on-WasmGC —
the full transcript (print output + repr + error text) byte-for-byte. The battery covers:
recursive functions, comprehensions (list/set/generator), dicts, classes with methods,
custom exception classes + try/except, closures/lambda/map, f-strings, while loops,
star-unpacking, negative-stride slicing, floats (`0.1 + 0.2`, banker's-rounding `round()`
via Decimal), and **`2**100` exact bignums**. Warm evals run in 3–20 ms; the module is
15.1 MB raw, **2.23 MB gzipped** (deployable on Workers — under even the free-plan cap).

## What it took (gaps BUILT, per the working agreement)

pyex is the largest program this compiler has eaten — 531 beams, 14,083 functions — and it
forced six pieces of general hardening, each verified suite-safe:

- **V8's `array.new_fixed` 10k cap**, twice: the 13k-entry atom-names table now builds in a
  `(start)` function; >10k-byte binary literals (long embedded strings) emit **data
  segments** + `array.new_data`, with a size gate keeping them out of constant-expression
  contexts where `array.new_data` is illegal.
- **`:persistent_term`** as a mutable-global assoc table (pyex caches its builtins env there).
- **`erlang.--/2`** (list difference), **`binary_to_list/1`**, **`list_to_binary/1`**.
- **`System.monotonic_time/0,1` + `convert_time_unit/3`** on a deterministic monotonic
  counter (pyex's compute-budget tracking).
- **`binary_to_float/1` / `list_to_float/1`** via a host parse (both engines are
  correctly-rounded decimal→double, so it's exact) — pyex's lexer parses float literals
  with it.
- A real bug: our base-N `binary_to_integer/2` rejected a leading `+` (Erlang accepts it) —
  found because Python's `round()` goes through Decimal, whose exponent parser produces
  `'+2'` charlists.

Honest scope: pyex targets Elixir ≥ 1.19 and this machine runs 1.17, so one interpreter
path (tuple-assignment in `__init__`) fails identically-on-neither — a pyex/VM-version
issue, not a compiler delta. The host-capability stdlib (asyncio, sql, http) rides the
same effects ABI as everything else and is unwired in this harness.
