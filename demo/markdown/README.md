# Markdown pipeline — real `Jason` + a renderer, on WasmGC, bit-exact vs the VM

A real-world content pipeline compiled to WebAssembly GC:

```
JSON article  --Jason.decode!-->  map  --markdown→HTML render + template-->  HTML page
```

`Blog.render/1` (in `app/lib/blog.ex`) decodes a JSON article with the **real, unmodified `Jason` 1.4.5**
hex package, renders the markdown body to HTML (headings, **bold**/*italic*/`code`, links, bullet/ordered
lists, blockquotes, fenced code), and wraps it in an HTML template. The harness renders each article on
**WasmGC and on the real Elixir VM** and asserts the HTML is **byte-identical**, then benches throughput.

## Result

```
built 218 KB wasm from 45 beams (Blog + real Jason + stdlib)
  ✅ seed 0   742 bytes  "Running Elixir on the Edge"
  ✅ seed 1   642 bytes  "Durable Objects with OTP Discipline"
  ✅ seed 2   478 bytes  "Exact Integers, Bit-for-Bit"
  3/3 pages BYTE-IDENTICAL (real Jason.decode! + markdown render -> HTML)
  module_compile=0.4ms  instantiate=0.09ms
  27.3 µs/render   ~36,700 renders/sec
```

The headline: **`Jason.decode!` runs on WasmGC** — the real library, parsing real JSON into Elixir maps,
bit-exact with the VM. (Previously only Jason *encode* was demonstrated; decode was thought to be blocked
on a 64-bit integer tier. Decode of strings/arrays/objects/booleans works today.)

## Run it

```bash
cd app && mix deps.get && mix compile && cd ..
NODE=/path/to/node24 elixir run.exs
```

(The `app/` mix project pins `{:jason, "~> 1.4"}`; `mix.lock` is committed. `deps/` and `_build/` are
gitignored — `mix deps.get` refetches them.)

## Honest scope — what this exercises, and the gaps it found

- **Real `Jason.decode!`** drives the parse: `Jason`, `Jason.Decoder`, the `Jason.Decoder.Unescape` path,
  `Map`/`:maps`. The sample articles contain strings/arrays/objects only; **decoding JSON *numbers* is not
  yet covered** — Jason's number path calls `:erlang.binary_to_integer/2` (and float parsing), which the
  compiler doesn't support yet (see below).
- **Markdown rendering is hand-written** (`app/lib/blog.ex`), not a hex dep — because of a real gap this
  demo *found*:
  - **Earmark** (the real markdown library) **compiles** to WasmGC (152k lines of WAT, 28 reachable
    stubs) but **traps at runtime** in `Earmark.Options.make_options/1` → `Kernel.struct/1`: building a
    struct dynamically from a module atom (`struct(Earmark.Options, opts)` → `mod.__struct__()` via the
    generic apply dispatch) hits an unsupported path. A good next target — it would unlock a whole class
    of libraries that build structs dynamically.
  - The renderer avoids `Integer.parse/1` for ordered-list detection (it routes through the unsupported
    `binary_to_integer`), using **binary pattern matching** instead — the same idiom real Elixir code uses
    on hot paths.
- **Compiler fix this demo surfaced:** `erlang:exit/1` outside *proc mode* used to reference a
  proc-only import (`$exit_raw`) and fail to assemble. It now traps (it's an unrecoverable error path with
  no process to unwind) — Earmark's error handling reaches it. Verified the full suite is unchanged
  (conformance 161/161, fuzz 33/33, gaps 19/20).

So: the **parse half is a real, unmodified hex dependency**; the render half is hand-written because the
real markdown lib exposed a concrete, documented gap. Both halves run bit-exact vs the VM.
