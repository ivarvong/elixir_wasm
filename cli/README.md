# `pyex` — run general Python on WasmGC, like a real `python` binary

```
cli/pyex script.py             # run a file
cli/pyex -c "print(1+1)"       # run a snippet
echo "print('hi')" | cli/pyex  # run stdin
REBUILD=1 cli/pyex ...         # force recompiling the interpreter
```

Runs the real [ivarvong/pyex](https://github.com/ivarvong/pyex) (a Python-3 interpreter in Elixir,
~146 modules) compiled to WasmGC and prints what `print()` emitted — byte-identical to CPython on the
programs tested (functions, classes/dunders, comprehensions, generators, slicing, f-strings, dicts,
exceptions, exact bignums).

The interpreter is built by **`mix wasm.build`** run inside pyex — configured declaratively in pyex's
`mix.exs` (`:wasm` key: entry module, exports, and the dependency sandbox boundary). `cli/pyex` just
ensures `pyex/wasm/pyex.wasm` exists (building it once) and runs your program through it. Both projects
use Elixir 1.20/OTP29. Point `PYEX_DIR` at your pyex checkout.

For agent loops, use the **`PyexSandbox`** class in `cli/sandbox.mjs`: compile once, `box.run(code)` per
snippet (~0.3 ms), isolated + sandboxed + step-bounded. See its header for the API.

---

# `elw` — compile & run pure Elixir on WasmGC as a CLI

```
cli/elw <file.ex> [entry] [int-arg ...]
```

Runs the whole pipeline for you: `elixirc` → `beam2wasm.exs` (EXPORTS/STUB/BIGNUM) →
`wasm-as` → a Node runner that instantiates the WasmGC module, calls `entry`, and prints
its return value as JSON (walked out of the heap by `termToJs`). Host effects (IO, File,
`:math`, `:crypto`, exact bignums) are wired from `runtime/imports.mjs`.

- `entry` defaults to `main`; integer args cross the boundary as f64 (exact to 2^53).
- The return value is printed as JSON. Exact integers larger than 2^53 come back as strings.
- `IO.puts`/`IO.write` reach the real stdout before the return value is printed.

### Pulling in stdlib / deps

The user file is compiled alone by default. To include stdlib or dependency modules,
list them in `DEPS` (resolved to their `.beam` via `:code.which`):

```
DEPS="Enum,String" cli/elw myprog.ex main
```

### Examples

```
cli/elw prog.ex add 40 2                 #=> 42
cli/elw prog.ex fact 20                  #=> "2432902008176640000"  (exact)
DEPS="Enum" cli/elw prog.ex main         #=> {":list":[1,4,9], ...}
```

### Env knobs

- `NODE` / `WASM_AS` — override toolchain binaries (defaults: pinned nvm 24.x, `wasm-as` on PATH).
- `KEEP=1` — keep `cli/_work/out.{wat,wasm}` build artifacts for inspection.
- `DEPS="Mod,Mod"` — extra modules to compile alongside the entry file.

### Notes / limits

- `STUB=1` is on: constructs the compiler can't lower yet become traps so the module still
  builds; if the entry hits one you'll see a Wasm trap. Fix at the root per the project rule.
- Entry return type is `term`, so any value walks back. Args are integers only for now
  (extend the runner's marshalling for lists/binaries if needed).
- The CLI sets `ATOMNAMES=1` so atom keys print by name (`:greeting`, not `:idx12`); this is
  an env-gated compiler flag, off by default, so it doesn't affect the verify suites.
```
