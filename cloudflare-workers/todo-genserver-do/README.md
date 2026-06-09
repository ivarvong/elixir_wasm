# Todo GenServer Durable Object

This is the canonical demo: a stateful todo-list API where a Cloudflare Durable Object is the durable process backing an Elixir GenServer-style state machine compiled to WasmGC.

## Architecture

- Durable Object = one durable todo-list process per `list` name.
- DO SQLite storage = persistent todo rows and counters.
- Compiled Elixir = `TodoServer.handle_call/3` transition logic.
- Worker = HTTP API and routing.

The DO owns durable state and serializes access. The Elixir GenServer callback module decides whether transitions are accepted and computes the next counters (`next_id`, `open`, `done`, `version`). The DO persists rows and counters after each accepted transition.

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

Examples:

```sh
curl -X POST 'http://127.0.0.1:8787/todos?list=home' \
  -H 'content-type: application/json' \
  -d '{"text":"Ship the Elixir-on-WasmGC demo"}'

curl 'http://127.0.0.1:8787/todos?list=home'

curl -X POST 'http://127.0.0.1:8787/todos/1/complete?list=home'

curl -X POST 'http://127.0.0.1:8787/todos/clear-completed?list=home'
```

## API

- `GET /todos?list=name`
- `POST /todos?list=name` with `{ "text": "..." }`
- `POST /todos/:id/complete?list=name`
- `POST /todos/:id/reopen?list=name`
- `DELETE /todos/:id?list=name`
- `POST /todos/clear-completed?list=name`

## Why This Is The Right Shape

This mirrors OTP without embedding the full BEAM process scheduler in Workers:

- Durable Object identity is the process name.
- DO storage is durable GenServer state.
- Elixir GenServer callbacks are the transition brain.
- WasmGC runs the compiled Elixir transition code inside the Worker runtime.

That gives us a practical Cloudflare-native “durable GenServer” model today.
