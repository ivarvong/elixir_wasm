# Account as a Durable Object — compiled Elixir running on workerd

This closes the loop: the Elixir state machine in `account.ex` is compiled to WasmGC by
`beam2wasm.exs` (via OTP's `:beam_disasm`), then **instantiated inside a Cloudflare Durable Object
and run on `workerd`** — the actual target runtime — with state in durable (disk-backed) DO storage.

## What runs where
- **`account_aot.wasm`** — `Account.step/2` (multi-clause, guards, `%{k => v}` map pattern matching,
  `%{s | ...}` updates) plus an integer ABI (`AccountAbi.transition_balance/4`,
  `transition_status/4`), compiled from two Elixir modules into one WasmGC module.
- **`worker.js`** — a DO class that instantiates the module once (`new WebAssembly.Instance` — no
  runtime compilation), keeps primitive state (`balance`, `status`, `history`) in `state.storage`, and
  drives each transition **through the compiled Elixir** (`this.e.transition_*`). One transactional
  `storage.put` per event.
- **`config.capnp`** — binds the wasm module, an `Account` DO namespace, and `durableObjectStorage =
  (localDisk = "do-disk")` so state persists to disk across process restarts.

## Run
    workerd serve config.capnp        # serves on 127.0.0.1:8791
    curl 'http://127.0.0.1:8791/?id=alice&event=new&amount=100'
    curl 'http://127.0.0.1:8791/?id=alice&event=deposit&amount=50'
    curl 'http://127.0.0.1:8791/?id=alice&event=freeze'
    curl 'http://127.0.0.1:8791/?id=alice&event=deposit&amount=1000'   # ignored while frozen

## Observed (this is real workerd output)
Event sequence on `alice`: new 100 → deposit 50 (150) → withdraw 30 (120) → freeze (frozen) →
**deposit 1000 while frozen → still 120** (the Elixir guard rejected it) → unfreeze → withdraw 120 (0).
A second account `bob` (new 500) is fully isolated.

**Durability across restart:** after killing workerd and starting a fresh process, a plain GET returned
alice = balance 0 / open / 7-event history and bob = 500, read back from disk; alice then continued from
that restored state (deposit 25 → 25). The actor's state outlived the process.

## Why this is the thesis, made literal
The whole argument for an Elixir-flavored durable edge runtime was: a single-owner, strongly-consistent,
durable state machine at the edge — "Durable Objects with OTP discipline." Here the OTP-style transition
function (pattern match + guards + immutable update) is *compiled Elixir executing in the DO*, and the DO
provides the durability BEAM itself lacks (per-actor persisted state + single-threaded execution).

## Honest scope
The state crosses the JS↔Wasm boundary as primitives (balance int, status code), so two pure transition
calls recompute the step rather than passing the map term across; a richer host ABI (or serializing the
WasmGC term) would remove that. The map is the flat representation from the compiler (fine for small
entity state). Latency/throughput/cost still need real Cloudflare, not local workerd. But the structural
claim — compiled Elixir as the durable actor, surviving restart — runs.
