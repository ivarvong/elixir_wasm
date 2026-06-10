# Spec — Cloudflare Workflows vs OTP-on-DO: does Workflows commoditize the differentiator?

## 1. The question this settles
Cloudflare Workflows is a GA durable-execution engine on the *same platform*. If it already delivers the
durability + correctness + ergonomics we're claiming for OTP-on-DO, the wedge collapses. This eval decides,
**per workload class**, whether to keep the reactive-durable-entity target, narrow it, or concede to Workflows.

## 2. What Workflows actually is (grounded, June 2026)
- **Model:** a `WorkflowEntrypoint.run(event, step)` script split into `step.do(name, cb)` steps. Each step is
  independently retriable; its result is persisted and **memoized — a completed step never re-runs** on
  restart/retry. `step.sleep`/`sleepUntil` = durable timers (≤ 365 days, exempt from step count).
  `step.waitForEvent` = pause for an external event (webhook / human-in-the-loop), delivered via a CF API HTTP endpoint.
- **Positioning (Cloudflare's own Agents-vs-Workflows table):** Workflows **"run to completion"**; Durable
  Objects/Agents **"run indefinitely."** Workflows have **no real-time comms** (no WebSockets/streaming),
  take external events only via **"pause and wait,"** and provide **automatic retries/recovery**. DO/Agents
  give real-time, **app-defined** failure handling, and built-in SQL state.
- **Limits (Workers Paid):** ≤ **25,000 steps/instance** (10k default; sleeps exempt); **1 GB state/instance**;
  1 MiB per step result and per event payload; 30s–5min CPU/step; **10,000 concurrent instances** (waiting
  instances don't count); **completed-instance state expires after 30 days**. V2 adds deterministic execution,
  50k concurrency, parallel/branching steps, step-level tracing.
- **Cost:** bills **active CPU compute time, not wall time**.
- **Determinism:** V2 makes steps replay-safe by design, but **replay-safety of side effects is the
  developer's responsibility** (the "rules of Workflows").

## 3. The boundary Cloudflare itself draws
Their own docs split it: **Workflows = bounded, run-to-completion orchestration; Durable Objects = unbounded,
real-time, event-reactive entities.** Our production-shaped target (durable `gen_statem` reactive entity) sits
on the **DO side**. So Workflows is *not* a drop-in competitor for the target — it's the competitor for the
orchestration class we explicitly don't target. The eval's job is to confirm that boundary and probe the middle.

## 4. Three workload classes, three hypotheses
| class | example | Workflows fit | hypothesis |
|---|---|---|---|
| **Unbounded reactive entity** | per-account ledger, rate limiter, presence/game room | structurally can't (25k-step cap, 30-day state expiry, run-to-completion, no real-time) | differentiator **SAFE**; competitor is raw DO (already beaten on fault correctness) |
| **Bounded-lifecycle entity** | order: created→authorized→captured→settled/refunded | possible via `waitForEvent` | **CONTESTED MIDDLE — the real test** |
| **Linear orchestration** | fulfillment pipeline, saga, ETL, AI pipeline | purpose-built, excellent | Workflows **WINS — do not target** |

## 5. Experiment
Reuse the order/payment state machine from the DO eval (it *is* the contested middle). Implement 4 ways:
1. **Ours** — `gen_statem`-on-DO (the modeled discipline; from do-eval).
2. **Raw TS Durable Object** — baseline (already built).
3. **Cloudflare Workflow** — order as a workflow instance; `capture`/`refund` arrive via `step.waitForEvent`;
   the external charge runs inside `step.do`.
4. **Elixir `gen_statem` on Fly** — real BEAM baseline.

Plus a second workload to be honest about where we lose: a **linear 4-step fulfillment saga** (check inventory →
charge → email → update DB, with retries), as a Workflow and as `gen_statem`-on-DO.

## 6. Dimensions / SLIs
- **A. Expressiveness & correctness-by-construction**
  - Can each express state-machine guards naturally (reject capture-when-captured; refund-before-capture)? LOC + qualitative.
  - Run the **existing fault-injection suite** (happy / retry / concurrent / crash / invalid). The decisive
    question: does each prevent the **double-charge by construction**, or require the same idempotency-key
    discipline? Expectation: Workflows' step memoization auto-handles *retry-after-clean-failure* (better than
    raw DO), but a **crash mid-charge-step still re-runs the charge → needs an idempotency key** (same
    fundamental constraint as us). Measure whether the *natural* Workflow impl double-charges on crash.
- **B. Latency** — per-event/transition p50/p99/p999: DO round-trip vs Workflow step-persistence overhead. (Real CF.)
- **C. Cost** — $/M events (active-CPU billing vs DO request+duration+storage); idle cost for a long-lived entity.
- **D. Lifetime/limits** — drive a long-lived order over many events: does the Workflow hit the step cap / 30-day
  expiry? Does the DO? (This is where unbounded entities break Workflows.)
- **E. Ops** — observability (Workflows ships step tracing/history; DO you build it), migration (`code_change`
  vs Workflow versioning), real-time (WebSocket) support.

## 7. Test matrix (what each settles)
| test | reveals |
|---|---|
| fault-injection on the Workflow order | whether Workflows commoditizes the *correctness* differentiator (or still needs the discipline) |
| guard/expressiveness on the Workflow order | whether a state machine is awkward to express as a linear workflow |
| long-lived order (many events) on Workflow vs DO | the step-cap / 30-day-expiry wall for entity-shaped work |
| linear saga both ways | quantifies where Workflows legitimately wins (don't compete) |
| per-event latency + $/M (real CF) | whether DO/ours is cheaper/faster for high-frequency entity transitions |

## 8. Kill criteria / decision rule
- **KEEP the full reactive-entity target** if: Workflows can't cleanly express unbounded entities (expected),
  AND for the bounded order it's worse on ≥2 of {expressiveness, crash-correctness-by-construction, per-event latency, idle cost}.
- **NARROW to unbounded + real-time only** if: Workflows matches us across the board on the bounded order —
  then concede bounded-lifecycle processes to Workflows and target only perpetual / real-time entities.
- **ABANDON** if: Workflows cleanly expresses unbounded, real-time, reactive entities with competitive
  latency/cost — which contradicts its current limits and would require a Workflows redesign.

## 9. Runnable now vs needs real Cloudflare
- **Now (local):** Workflows runs under `wrangler dev` / Miniflare (each instance is a SQLite "Engine DO"), with
  first-class `cloudflare:test` / vitest support. So the **fault-injection + expressiveness + limits** comparison
  for {ours, raw DO, Workflow} is runnable locally — this settles class 1 and the contested middle's
  *correctness/ergonomics* without touching production.
- **Needs real CF:** edge p50/p99/p999 latency, $/M cost, multi-region. Deploy ours + Workflow to CF; deploy
  Elixir to Fly for the BEAM baseline.

## 10. Sequencing / effort
1. *(local, ~1 day)* Order-as-Workflow + run the existing fault-injection suite against it; add the
   guard/expressiveness comparison. → does Workflows commoditize the *bounded* case on correctness/ergonomics?
2. *(local, ~1 day)* The linear saga both ways → confirm/quantify where Workflows wins (honesty).
3. *(real CF + Fly, ~2–3 days)* Latency + cost across all four.

**Output:** a one-page verdict mapping each workload class to keep / narrow / concede — the input to the go/no-go memo.
