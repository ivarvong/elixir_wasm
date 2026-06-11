# rebalancer — the consumer-journey demo

A portfolio rebalancer as a JSON API, built **exactly the way a consumer of beam2wasm would
build it** — this demo exists to dogfood the library surface, not the compiler internals.

Live: `https://elixir-rebalancer.ivar.workers.dev`

```
curl -s -X POST https://elixir-rebalancer.ivar.workers.dev/rebalance -d '{
  "cash": 5000, "tolerance": 0.0025,
  "targets": {"VTI": 0.6, "VXUS": 0.3, "BND": 0.1},
  "positions": [
    {"symbol": "VTI",  "shares": 120, "price": 262.41},
    {"symbol": "VXUS", "shares": 140, "price": 64.77},
    {"symbol": "BND",  "shares": 95,  "price": 73.12},
    {"symbol": "ARKK", "shares": 30,  "price": 51.05}
  ]}'
```

Returns the whole-share trade plan (sells first — they fund the buys), per-position
weight/target/drift, cash after, and the residual drift. Invalid input is a 400 with
`{"error": reason}` — the error path is part of the verified API.

## The journey (what this demo proves)

| step | command | result |
|---|---|---|
| app | `app/` — ordinary Mix project: pure Elixir + the real unmodified Jason dep | one `rebalance(json) :: json` entry |
| toolchain | `mix wasm.doctor` | install hints for anything missing |
| compile | `mix wasm.build --module Rebalancer --export "rebalance:bin->bin"` | `wasm/rebalancer.wasm` |
| verify | `mix wasm.verify --module Rebalancer --export "rebalance:bin->bin" --runs 15 --cases verify/cases.exs` | 28/28 identical vs the VM |
| local prod gate | `cd worker && elixir smoke.exs` | 13/13 byte-identical over HTTP on workerd; p50 ≈ 0.4 ms |
| deploy | `npx wrangler deploy` | the same staged files, on Cloudflare |
| prod check | curl prod, `cmp` vs `mix run` output | byte-identical |

The worker consumes the **library's** `priv/host.mjs` (`instantiate(wasmModule)`) — no
hand-wired import objects. Building this demo found and fixed a real consumer bug:
host.mjs imported `node:fs` at module top level, which no edge runtime resolves; it is
now lazy and only loaded when `instantiate` is given a file path.

`verify/cases.exs` holds the realistic differential cases (balanced/unbalanced/initial
buy-in/tier-crossing dollar values/every validation error); `mix wasm.verify` adds seeded
garbage binaries on top, which pins the malformed-JSON path to the VM too.
