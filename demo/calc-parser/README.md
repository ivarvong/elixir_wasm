# demo/calc-parser — a recursive grammar on WasmGC

A recursive-descent arithmetic parser built on the **real, unmodified
[`nimble_parsec`](https://hex.pm/packages/nimble_parsec)** combinator library — the one that
powers Jason, Phoenix, and much of hex — compiled to WebAssembly GC and producing **byte-identical**
JSON ASTs versus the Elixir VM.

```
"1+2*3"        => {"ok":["+",1,["*",2,3]]}            # precedence: * binds tighter
"(1+2)*3"      => {"ok":["*",["+",1,2],3]}            # parentheses override
"1+2+3+4"      => {"ok":["+",["+",["+",1,2],3],4]}    # left-associative
"(1+(2*(3+4)))"=> {"ok":["+",1,["*",2,["+",3,4]]]}    # nested recursion
"1+"           => {"error":"unexpected trailing input","at":"+"}
```

The grammar is the classic three precedence layers, with `parsec(:expr)` as the **recursive
self-reference** inside `factor` (the hard part — mutual recursion between generated parsers):

```
expr   = term   (("+" | "-") term)*
term   = factor (("*" | "/") factor)*
factor = integer | "(" expr ")"
```

## Why it matters

This isn't a curated stdlib slice — it's a real third-party parser-combinator library running a
recursive grammar with operator precedence, left-associativity, and runtime AST construction
(`reduce/2` runs the fold *during* the parse). The compiler handles it with **zero unsupported
constructs**; the only externals are pure stdlib delegates (`Keyword`, `Map`, `Enum`, `:lists`),
fed and compiled like any other module.

## Run it

```bash
cd app && mix compile && cd ..
elixir run.exs        # parse 13 expressions on Wasm AND the VM; assert byte-identical JSON
```

`app/lib/calc.ex` is the whole thing: the grammar plus a single `bin -> bin` entry point
(`Calc.parse/1`, expression string → JSON AST), so the same function serves the VM, `run.exs`, and a
Cloudflare Worker. This demo is part of the pinned `verify.exs` manifest.
