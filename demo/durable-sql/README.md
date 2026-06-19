# A SQLite client inside compiled Elixir — the database as a host effect

**LIVE: https://elixir-sqlite-ledger.ivar.workers.dev** — open it: a full-CRUD webapp whose
every operation is `SqlLedger.ledger_op/1`, real Elixir compiled to WasmGC, running SQL
against the Durable Object's own SQLite. Switch the actor field and you're in a different
(isolated, durable, per-tenant) database.

```elixir
defmodule Sqlite do
  def query!(sql, params \\ []), do: :sql_host.exec(sql, Jason.encode!(params)) |> Jason.decode!()
end

SqlLedger.update(id, kind, amount)
# => Sqlite.query!("UPDATE entries SET kind = ?, amount = ? WHERE id = ? RETURNING id, kind, amount", ...)
```

`:sql_host.exec/2` is a host import in exactly the `:file`/NIF mold (LIMITATIONS §1.2): the
host decides the engine. Three backings ship in `runtime/imports.mjs`:

| backing | engine | used by |
|---|---|---|
| `nodeSqliteBacking` | `node:sqlite` DatabaseSync | the differential gate, local runs |
| `doSqliteBacking` | the DO's **synchronous** `ctx.storage.sql` | production |
| (VM oracle) | `node:sqlite` via a line-server Port | `run.exs` BEAM side |

The DO's SQL API being synchronous is what makes this clean: compiled Elixir queries
mid-computation through a plain import — no JSPI, no promises. Params and rows ride **real
compiled Jason** both directions, so a row is just `%{"kind" => "coffee", "amount" => 4}`.

## Verified

- **Differential gate** (`elixir run.exs`): the same seed-driven CRUD session — schema,
  parameterized INSERT/UPDATE/DELETE with `RETURNING`, GROUP BY aggregates, and an
  Elixir-side `Enum` fold that must agree with SQL `SUM` — on the BEAM and on WasmGC,
  both against the identical engine: **6/6 sessions byte-identical**.
- **Production**: full CRUD over `POST /api?actor=X` verified live; per-actor isolation;
  and actor data written before a worker redeploy was intact after it (durable across
  deploys, not just restarts).

## Run it

```bash
cd app && mix deps.get && mix compile && cd ..
elixir run.exs                          # the differential gate
cd worker && cp ../_work/ledger.wasm . && cp ../../../runtime/imports.mjs .
workerd serve config.capnp              # local: http://127.0.0.1:8801
npx wrangler deploy                     # production
```
