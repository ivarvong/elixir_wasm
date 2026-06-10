# Portfolio GenServer Durable Object

This example uses a Durable Object as the durable backing process for a compiled Elixir GenServer-style state machine.

## Architecture

- One Durable Object per account: `env.PORTFOLIOS.getByName(accountId)`.
- The DO stores durable state: `cash`, `aapl`, `msft`, `events`.
- The transition logic is written as an Elixir module using `use GenServer` and idiomatic `handle_call/3` callbacks.
- A small `PortfolioAbi` module exposes primitive Wasm exports so the DO can drive callback transitions.
- The DO persists state after every accepted event.

This avoids requiring the JSPI process scheduler in Workers. The Durable Object is the single-owner process; the compiled Elixir GenServer callback module is the state transition brain.

## Build

```sh
npm install
npm run build:wasm
npm run types
npm run typecheck
```

## Run Locally

```sh
npm run dev
```

Example requests:

```sh
curl -X POST http://127.0.0.1:8787/accounts/alice/reset \
  -H 'content-type: application/json' \
  -d '{"cash":100000}'

curl -X POST http://127.0.0.1:8787/accounts/alice/events \
  -H 'content-type: application/json' \
  -d '{"type":"buy_aapl","amount":3}'

curl -X POST http://127.0.0.1:8787/accounts/alice/events \
  -H 'content-type: application/json' \
  -d '{"type":"rebalance"}'

curl http://127.0.0.1:8787/accounts/alice
```

## Event Types

- `deposit` with `amount` in cents
- `withdraw` with `amount` in cents
- `buy_aapl` with `amount` in shares
- `sell_aapl` with `amount` in shares
- `buy_msft` with `amount` in shares
- `sell_msft` with `amount` in shares
- `rebalance` with no amount

## Why This Is Useful

It maps the OTP mental model to Cloudflare primitives:

- Durable Object = addressable, durable, single-owner process.
- Elixir GenServer callbacks = transition logic.
- DO storage = state backing that survives eviction and restart.
- Worker fetch handler = HTTP API and routing layer.
