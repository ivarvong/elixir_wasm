# Markdown pipeline — REAL Jason + REAL Earmark on WasmGC, bit-exact vs the VM

The complete real-dependency content pipeline compiled to WebAssembly GC:

```
JSON article --Jason.decode!--> map --Earmark.as_html!--> HTML --template--> page
```

`Blog.render/1` (`app/lib/blog.ex`) uses **two real, unmodified hex packages**: `Jason` 1.4.5 decodes
the JSON article (numbers included), and `Earmark` 1.4.49 renders the markdown body — the full real
engine: LineScanner (every line-typing regex, including the `/x` extended-mode IAL pattern with PCRE
`(?'name'...)` groups), the block Parser, the AST renderer, the **leex-generated link lexers**, and
OTP's `erl_scan`/`io_lib` underneath. The harness renders each page on **WasmGC and the real Elixir
VM** and asserts the HTML is **byte-identical**, then benches.

## Result

```
built ~2.9 MB wasm from 166 beams (Blog + real Jason + real Earmark + stdlib)
  ✅ seed 0   589 bytes  "Running Elixir on the Edge"
  ✅ seed 1   398 bytes  "Durable Objects with OTP"
  ✅ seed 2   302 bytes  "Exact Integers"
  3/3 pages BYTE-IDENTICAL (real Jason.decode! + real Earmark -> HTML)
  ~1.1 ms/render  (~890 full markdown-parses+renders/sec)
```

## Run it

```bash
cd app && mix deps.get && mix compile && cd ..
elixir run.exs
```

## What it took (each gap BUILT, not worked around — see LIMITATIONS.md)

Getting real Earmark bit-exact drove a long burn-down across the compiler/runtime, every step
verified bit-exact and suite-safe; highlights:

- **A real codegen bug**: `get_map_elements` is ONE instruction in BEAM — destination registers may
  alias the source map (Earmark's `_parse/4` does). Our sequential lowering re-read the clobbered
  register; could corrupt any multi-key map pattern.
- **The full Regex surface** host-shimmed (run/2/3, split, replace incl. FUNCTION replacements, scan,
  match?, escape, runtime compile!) + a **PCRE→JS translation layer** (x-mode, `(?'name'`,
  branch-reset `(?|`, atomic `(?>`, `\A \z \h \R`, opts-as-atom-list).
- `Kernel.struct!` (via `maps:update/3`), exceptions/`raise` machinery, `binary_to_existing_atom`,
  `integer_to_binary/2`, float formatting, sub-byte bitstring match/construct, the OTP-27 map-cursor
  BIFs, `iolist_size`, `epp`/`io` constants — and feeding the right beams (consolidated protocols,
  `List.Chars` impls, `erl_scan`, `io_lib`, the leex lexer beams — all plain `.beam` code).
- **Diagnosability**: an `apply` dispatch miss now raises `{:undef, Mod, Fun}` and the `$exc` tag is
  exported, so the host decodes escaped exceptions symbolically (this found the missing
  `List.Chars.BitString` impl in minutes).

## Honest scope

The PCRE→JS regex translation is exact for everything Earmark exercises (verified byte-identical
output) but two constructs are approximations in general: branch-reset `(?|` capture numbering when a
non-first alternative wins, and atomic `(?>` groups whose contents can backtrack internally. Both are
documented fidelity edges in `LIMITATIONS.md` §1.1.
