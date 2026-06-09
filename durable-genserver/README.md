# Durable GenServer in a Durable Object — the product thesis, closed

A real **GenServer**, compiled from Elixir, running inside a **Cloudflare Durable Object** on
`workerd`, with its state **durable across restart**. This is exactly the repo's pitch — "Durable
Objects with OTP discipline" — made literal: the OTP callback (`handle_call/3`, multi-clause +
guards) is compiled Elixir; the DO supplies per-actor durable state, which the BEAM does *not* have
natively (ARCHITECTURE §11 — on the durability axis we are *ahead* of BEAM).

```bash
workerd serve config.capnp        # 127.0.0.1:8797 ; state persists to ./state
curl 'http://127.0.0.1:8797/?acct=alice&op=deposit&amount=50'    # {"reply":":ok","balance":150}
curl 'http://127.0.0.1:8797/?acct=alice&op=withdraw&amount=999'  # {"reply":":insufficient","balance":150}
# kill workerd, restart, then:
curl 'http://127.0.0.1:8797/?acct=alice&op=balance'              # balance survived on disk
```

## What runs where
- **`bank.wasm`** — `Bank.handle_call/3` (a real GenServer callback module: `:balance`,
  `{:deposit, n}`, `{:withdraw, n}` with a `when amt <= balance` guard → `:ok` / `:insufficient`),
  plus a thin `BankAbi` that turns an int event-code into the request term. Compiled from Elixir by
  `beam2wasm.exs`.
- **`worker.js`** — a DO that instantiates the module once (`new WebAssembly.Instance` — no runtime
  compilation), loads the balance from DO storage, drives **one GenServer step** per request
  (`handle/3` → `{:reply, reply, new_state}`, decoded via the tuple JS-bridge), persists the new
  state, and returns the reply.
- **`config.capnp`** — binds the wasm, the `BankDO` namespace, and `localDisk` storage so state
  survives process restart.

## Honest scope
State here is an integer (a balance) — trivially serializable. A richer term state (maps, lists)
needs a term codec (ETF-lite) to persist across restart; that's the next step and is also what
cross-isolate messaging (§10) needs. The DO drives *one* GenServer transition per request rather
than running the in-isolate `spawn`/`receive` loop (that loop lives in `runtime/` and can't span DO
requests, since an isolate may be evicted) — which is the correct edge model: ephemeral process,
durable state. Latency/throughput/cost still need real Cloudflare, not local workerd. But the
structural claim — a real GenServer's logic as the durable edge actor, surviving restart — runs.
