# pyex-web — the Python-on-WasmGC playground + HTTP API

Live at **https://pyex.dev**: [pyex](https://github.com/ivarvong/pyex)
(a Python 3 interpreter written in Elixir) compiled to WebAssembly GC, running
two ways from one Cloudflare Worker:

- **In your browser** — the playground UI. The Worker streams `pyex.wasm` from R2;
  Python executes client-side in a Web Worker, with a Files panel, stdout, and an
  OpenTelemetry trace waterfall emitted by the guest program itself.
- **At the edge** — `POST /api/run`. The same wasm, bundled into the Worker as a
  precompiled module binding, runs Python server-side in the isolate:

  ```bash
  curl -s https://pyex.dev/api/run \
    -H 'content-type: application/json' \
    -d '{"code": "print(sum(range(10)))", "files": {"/in.json": "[1,2,3]"}, "max_steps": 5000000}'
  # -> {ok, ms, stdout, files, footprint, spans} | {ok: false, ms, error}
  ```

  `text/plain` bodies are raw Python. Every run gets a fresh interpreter Ctx and
  in-memory VFS; runaways die on their step budget (default 150k, cap 300k) with
  a clean Python `LimitError`. The cap sits deliberately below the isolate's
  memory death line: V8 can't collect WasmGC garbage during a synchronous wasm
  call, so per-step allocations accumulate for the whole run — past ~400k steps
  that hits the 128 MB isolate ceiling and the platform (not the sandbox) kills
  the request. The response carries the guest's OTel spans and the resource
  footprint — the same observability the browser UI renders.

## Layout

- `app/` — Vite + React + Tailwind playground (`src/pyex.worker.ts` is the browser
  glue; `src/imports.mjs` the wasm host imports, shared by the Worker API).
- `worker/` — the Cloudflare Worker: static assets, R2-streamed wasm, `/api/run`.

## Dev loop

```bash
cd app
curl --compressed -o public/pyex.wasm https://pyex.dev/pyex.wasm  # or a fresh build
npm run dev -- --port 5199
npm run check:mobile         # closed-loop mobile-UX check: headless Chrome at iPhone
                             # geometry; boots wasm, runs an example, walks every tab,
                             # screenshots to scripts/shots/, fails on overflow/console
                             # errors/React warnings/small tap targets.
node scripts/lru-check.mjs   # proves the lru example (chained assignment) runs
cd ../worker && npx wrangler dev --port 8799   # local /api/run
```

Both checks take `PYEX_URL=...` to target production instead. They need a browser
with wasm `exnref` support (Chrome 137+; the scripts point at system Chrome).

## Deploy

```bash
./deploy.sh [path/to/pyex.wasm]   # default: ../../../pyex/wasm/pyex.wasm
```

The wasm lives in TWO places that must stay in sync — R2 (browser path) and
`worker/pyex.wasm` (API path; workerd forbids runtime `WebAssembly.compile`).
`deploy.sh` updates both, cache-busts the browser URL by content hash
(`VITE_WASM_V`), deploys, and then validates production end-to-end.

To build a fresh interpreter: `mix wasm.build` in the pyex repo (needs the
`wasm:` config in its mix.exs pointing at this repo's beam2wasm).
