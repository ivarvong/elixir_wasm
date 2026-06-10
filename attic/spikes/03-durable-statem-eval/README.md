# Durable state-machine eval — does OTP discipline prevent double-charges on Durable Objects?

Tests the **differentiator** for the production-shaped target ("durable `gen_statem` at the edge"):
on the same platform (Durable Objects), does the discipline OTP's `gen_statem` enforces prevent
the failures that cause double-charges — failures that naive DO code does not?

Runs on **workerd** (the real Workers runtime) with **real DO transactional storage**. No mocks.

## The two implementations (same workload: an order/payment state machine)
- **NaiveOrder** — quick DO code: a state guard (handles the easy cases), but the external charge
  uses a fresh id (non-idempotent) and the state is committed as a *separate, non-transactional* write.
- **StatemOrder** — the discipline a durable `gen_statem` gives you by construction: the charge is
  **keyed by the idempotency key** (provider-style dedupe), state transitions have **explicit guards**,
  and the state commit runs in a **storage transaction**.

"charged" = sum of ledger entries (a ledger entry models an external charge). Correct = charged once.

## Run
```
workerd serve config.capnp &      # two DO namespaces, transactional storage, :8790
curl 'http://127.0.0.1:8790/?impl={naive|statem}&scenario={happy|retry|concurrent|crash|invalid}'
```

## Result (deterministic across repeated runs)
| scenario                         | NaiveOrder   | StatemOrder |
|----------------------------------|--------------|-------------|
| happy                            | OK (100)     | OK (100)    |
| retry (duplicate, same key)      | OK (100)     | OK (100)    |
| concurrent (5×)                  | OK (100)     | OK (100)    |
| **crash mid-capture, then retry**| **BUG (200)**| OK (100)    |
| **invalid (refund before capture)** | **BUG (−100)** | OK (0)  |

## What it shows
Durable Objects' single-threading + input-gating handles **concurrency** (naive passes 5× concurrent),
and a simple guard handles **sequential retries** — those are the *easy* cases, and the platform gives
them to you. The bugs that actually cause double-charges in production are **crashes** and **invalid
events**, and the platform does nothing for those:
- **crash** — naive charges, then crashes before committing state; the client retries; the guard sees
  "not captured" and **charges again → 200**. The disciplined version's keyed charge dedupes and its
  state commit is transactional, so the retry is exactly-once → 100.
- **invalid transition** — naive applies a refund with no guard → **−100 corruption**; the disciplined
  version rejects the event for the current state → 0.

This is the direct answer to "why not raw TypeScript on a Durable Object": single-threading is the easy
half; **exactly-once under failure** is the hard half, and it's precisely what `gen_statem` + transactional/
idempotent effects enforce by construction. The naive bugs are the kind you ship by accident; the
disciplined version makes them unrepresentable.

## Honest scope
- The discipline here is hand-written in JS to *model* what the Elixir runtime would generate from a
  `gen_statem`; the actual codegen doesn't exist yet. The claim being tested is "the pattern prevents the
  bug," and it does — the next step is having the runtime emit/enforce it so developers get it for free.
- `concurrent` passed for naive because workerd serialized the DO requests (input gating). On a path that
  yields to a non-storage await (e.g. a real external API call) between read and write, naive can also lose
  updates; that's a timing-dependent variant, not shown deterministically here.
- This is the **correctness** half of the eval (runnable on workerd today). The **edge-latency** and
  **$/M-transition** numbers — the vs-Fly-BEAM and vs-Cloudflare-Workflows comparisons — need real
  Cloudflare deployment.
