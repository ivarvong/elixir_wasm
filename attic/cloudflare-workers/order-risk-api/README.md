# Order Risk API on Cloudflare Workers

This is a useful edge API example: a Cloudflare Worker runs an Elixir business-logic module compiled to WasmGC.

The Elixir source is the `RealisticOrderTarget` from `conformance/realistic_order.exs`. It decodes a checkout event with Jason-style JSON data, computes order totals, discounts, shipping, tax, and fraud/risk signals, then returns a deterministic exact-integer score.

## Why This Is Useful

This is the shape of a real serverless workload:

- Validate and score checkout events at the edge.
- Keep domain logic in Elixir.
- Run the compiled Elixir module inside a Worker with no BEAM VM deployed.
- Return a deterministic score that downstream systems can use for routing, review, or fulfillment.

## Build

```sh
npm install
npm run build:wasm
npm run types
npm run typecheck
```

`npm run build:wasm` runs the existing conformance program and copies the generated `RealisticOrderTarget.wasm` into `src/` for Wrangler to bundle.

## Run Locally

```sh
npm run dev
```

In another shell:

```sh
curl http://127.0.0.1:8787/sample \
  | curl -X POST http://127.0.0.1:8787/score \
      -H 'content-type: application/json' \
      --data-binary @-
```

Expected response shape:

```json
{
  "score": "1559258",
  "elapsed_ms": 1,
  "engine": "elixir-wasmgc"
}
```

## Deploy

```sh
npm run deploy
```

## Notes

- The Worker enforces a 64 KiB request body limit before handing payloads to the Wasm module.
- The Wasm instance is cached at module scope, but request-scoped state is not.
- Logs are structured JSON and observability is enabled in `wrangler.jsonc`.
- This example intentionally uses no secrets and no Cloudflare REST API calls from inside the Worker.
