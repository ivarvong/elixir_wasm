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
  ~0.8 ms/render  (~1,200 full markdown-parses+renders/sec)
```

## Head-to-head vs JS renderers (`bench_vs_js.exs`)

A realistic 3.7 KB markdown document through four renderers on the same machine — with a
byte-identical correctness gate vs the VM before any timing is reported:

```
✅ Wasm output BYTE-IDENTICAL to the real Elixir VM (5570 bytes of HTML)

   Earmark 1.4.49 (real, WasmGC)         11451 µs/render      87/sec    1.0x
   Earmark (native BEAM, same machine)    3724 µs/render     269/sec    3.1x
   marked 15.0.12 (JS)                     131 µs/render   7,648/sec   87.6x
   markdown-it 14.2.0 (JS)                  75 µs/render  13,263/sec  151.9x

   cold start (2.9 MB module): compile=1.9ms instantiate=1.5ms first_render=13.5ms total=17.1ms
```

Read the decomposition honestly: Wasm-Earmark is **3.1× the native BEAM** (the compiler's
overhead, consistent with the perf suite), while Earmark-the-library is itself ~28× slower
than `marked` *natively* — an AST-building parser vs a lean line-regex renderer. The JS gap
is mostly a library-design difference, not Wasm overhead. The comparison is work-rate on
identical input; the three engines emit different (all valid) HTML, so output equivalence is
asserted only Wasm-vs-VM.

This benchmark found and fixed two real gaps on first run: `binary:split` with a *list* of
patterns + `:trim_all` (what `String.split/1` uses — built, multi-pattern leftmost-longest),
and per-call `new RegExp` construction in the host regex shim (now cached; −22% per render).

## Run it

```bash
cd app && mix deps.get && mix compile && cd ..
elixir run.exs                       # 3-page pipeline, byte-identical + bench
(cd vs_js && npm install) && elixir bench_vs_js.exs   # head-to-head vs marked/markdown-it
```

## In production (`worker/`) — DEPLOYED on Cloudflare Workers

The same compiled module serves at **https://elixir-markdown.ivar.workers.dev** — real Jason +
real Earmark on Cloudflare's edge (`GET /?seed=N`, `POST /render` with markdown body).

```bash
cd worker
elixir smoke.exs        # local workerd gate: byte-identical over HTTP before any deploy
npx wrangler deploy     # ship the same three files workerd just served
```

Measured 2026-06-10 (deploy `71c3b65f`, PoP EWR):
- **All 4 production responses BYTE-IDENTICAL to the real Elixir VM** (3 article pages +
  the 3.7 KB document through `POST /render`) — the same differential gate as every suite,
  now over the public internet.
- Local workerd (compute floor): p50 = 1.0 ms end-to-end HTTP per render.
- **Load test** (autocannon from a residential client, warm sustained load):
  - `GET /?seed=1` — 25 connections × 30 s = **15,000 requests, ~500 req/s, zero errors**:
    p50 = 46 ms · p90 = 75 ms · **p99 = 134 ms** · p99.9 = 505 ms (the cold-isolate tail).
    The earlier "p99 414 ms" figure was 50 *sequential* fresh-TLS curls — handshake + cold-start
    noise, not service latency.
  - `POST /render` (3.7 KB markdown upload, the heavy ~12 ms-CPU render) — 15 connections × 20 s
    = 2,000 requests, zero errors: p50 = 152 ms · p99 = 567 ms.
  - Byte-identical re-verified after the 17k requests.
- Network floor from this client: ~25 ms RTT to EWR — subtract that to read the numbers as
  service time. Local workerd compute floor: p50 = 1.0 ms.
- Upload: 2995 KiB raw, **505 KiB gzipped**.

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
