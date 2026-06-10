// Durable state-machine eval on workerd Durable Objects.
// "charged" = sum of ledger entries; a ledger entry models an external charge.
//   NaiveOrder : charge uses a fresh id (non-idempotent); state committed as a separate write.
//   StatemOrder: charge keyed by idempotency key (provider-style dedupe) + explicit state
//                guards + transactional state commit — the discipline gen_statem enforces.
// The suite asks: under retry / concurrency / crash / invalid events, is anyone double-charged?

function json(o, status = 200) {
  return new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });
}
async function readModel(st) {
  const state = (await st.get("state")) || { status: "new", amount: 0 };
  const map = await st.list({ prefix: "ledger:" });
  let charged = 0, n = 0;
  for (const v of map.values()) { charged += v.amount; n++; }
  return { status: state.status, charged, entries: n };
}

// ---------- naive: quick DO code, with the usual guard but no idempotency/transaction ----------
export class NaiveOrder {
  constructor(state) { this.st = state.storage; }
  async fetch(req) {
    const u = new URL(req.url), op = u.searchParams.get("op");
    const amount = +(u.searchParams.get("amount") || 0);
    const crash = u.searchParams.get("crash") === "1";
    const st = this.st;
    if (op === "read") return json(await readModel(st));
    if (op === "authorize") { await st.put("state", { status: "authorized", amount }); return json({ ok: true }); }
    if (op === "capture") {
      const s = (await st.get("state")) || { status: "new" };
      if (s.status === "captured") return json({ ok: true, already: true });            // guard (handles easy cases)
      if (s.status !== "authorized") return json({ ok: false, error: "invalid_transition" });
      await st.put("ledger:" + crypto.randomUUID(), { type: "capture", amount: s.amount }); // NON-idempotent charge
      if (crash) throw new Error("crash: charged, state not yet committed");
      await st.put("state", { ...s, status: "captured" });                                 // separate, non-transactional
      return json({ ok: true });
    }
    if (op === "refund") {                                                                  // no guard
      await st.put("ledger:" + crypto.randomUUID(), { type: "refund", amount: -amount });
      await st.put("state", { status: "refunded" });
      return json({ ok: true });
    }
    return json({ error: "unknown op" }, 400);
  }
}

// ---------- disciplined: what gen_statem + transactional/idempotent effects give you ----------
export class StatemOrder {
  constructor(state) { this.st = state.storage; }
  async fetch(req) {
    const u = new URL(req.url), op = u.searchParams.get("op");
    const amount = +(u.searchParams.get("amount") || 0);
    const idem = u.searchParams.get("idem") || "";
    const crash = u.searchParams.get("crash") === "1";
    const st = this.st;
    if (op === "read") return json(await readModel(st));
    if (op === "authorize") { await st.put("state", { status: "authorized", amount }); return json({ ok: true }); }
    if (op === "capture") {
      const s = (await st.get("state")) || { status: "new" };
      if (s.captureKey === idem) return json({ ok: true, idempotent: true });              // replay of same command
      if (s.status === "captured") return json({ ok: false, error: "already_captured" });
      if (s.status !== "authorized") return json({ ok: false, error: "invalid_transition" }); // explicit guard
      await st.put("ledger:" + idem, { type: "capture", amount: s.amount });               // IDEMPOTENT charge (keyed)
      if (crash) throw new Error("crash: charged, state not yet committed");
      await st.transaction(async (txn) => txn.put("state", { ...s, status: "captured", captureKey: idem }));
      return json({ ok: true });
    }
    if (op === "refund") {
      const s = (await st.get("state")) || { status: "new" };
      if (s.status !== "captured") return json({ ok: false, error: "invalid_transition" }); // guard: no refund before capture
      await st.put("ledger:refund:" + idem, { type: "refund", amount: -s.amount });
      await st.transaction(async (txn) => txn.put("state", { ...s, status: "refunded" }));
      return json({ ok: true });
    }
    return json({ error: "unknown op" }, 400);
  }
}

// ---------- fault-injection harness ----------
export default {
  async fetch(req, env) {
    const u = new URL(req.url);
    const impl = u.searchParams.get("impl") || "statem";
    const scenario = u.searchParams.get("scenario") || "happy";
    const ns = impl === "naive" ? env.NAIVE : env.STATEM;
    const stub = ns.get(ns.idFromName(`${impl}-${scenario}-${Math.random().toString(36).slice(2)}`)); // fresh order
    const call = (qs) => stub.fetch("https://do/?" + qs);
    const tryCall = async (qs) => { try { const r = await call(qs); return { s: r.status }; } catch (e) { return { threw: true }; } };

    const AMT = 100;
    await call(`op=authorize&amount=${AMT}`);

    if (scenario === "happy")        { await call(`op=capture&idem=k1&amount=${AMT}`); }
    else if (scenario === "retry")   { await call(`op=capture&idem=k1&amount=${AMT}`); await call(`op=capture&idem=k1&amount=${AMT}`); }
    else if (scenario === "concurrent") {
      await Promise.allSettled([0,1,2,3,4].map(() => call(`op=capture&idem=k1&amount=${AMT}`)));
    }
    else if (scenario === "crash")   { await tryCall(`op=capture&idem=k1&amount=${AMT}&crash=1`); await call(`op=capture&idem=k1&amount=${AMT}`); }
    else if (scenario === "invalid") { await call(`op=refund&idem=k1&amount=${AMT}`); }     // refund before capture

    const model = await (await call("op=read")).json();
    const expected = scenario === "invalid" ? 0 : AMT;
    const pass = model.charged === expected;
    return json({ impl, scenario, status: model.status, charged: model.charged, expected,
                  verdict: pass ? "OK" : `BUG: charged ${model.charged}, expected ${expected}` });
  }
};
