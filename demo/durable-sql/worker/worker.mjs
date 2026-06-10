// A SQLite client INSIDE compiled Elixir, querying the Durable Object's OWN database.
// SqlLedger.ledger_op/1 (real Elixir + real Jason) runs schema/INSERT/SELECT against
// ctx.storage.sql via the `sql` host import — synchronous, per-actor, durable.
//
//   GET /?actor=alice&op=add&kind=coffee&amount=4
//   GET /?actor=alice&op=balance
//   GET /?actor=alice&op=report
import ledgerModule from "./ledger.wasm";
import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, makeSql, memFsBacking, doSqliteBacking } from "./imports.mjs";

const enc = new TextEncoder(), dec = new TextDecoder();

function instantiate(sqlStorage) {
  const big = makeBig(), math = makeMath();
  let e;
  const str = makeStr(() => e);
  const { proc, sched } = makeProcStubs();
  e = new WebAssembly.Instance(ledgerModule, {
    big, math, str, proc, sched,
    fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e),
    sql: makeSql(() => e, doSqliteBacking(sqlStorage)),
  }).exports;
  return e;
}

export class LedgerDO {
  constructor(ctx) {
    // one instance per actor: the module binds to THIS actor's SQLite at construction
    this.e = instantiate(ctx.storage.sql);
  }
  async fetch(req) {
    const url = new URL(req.url);
    const op = {
      op: url.searchParams.get("op") || "report",
      kind: url.searchParams.get("kind") || undefined,
      amount: url.searchParams.has("amount") ? parseInt(url.searchParams.get("amount"), 10) : undefined,
    };
    try {
      const e = this.e;
      const u = enc.encode(JSON.stringify(op));
      const b = e.bin_alloc(u.length);
      for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]);
      const r = e.ledger_op(b);
      const n = e.bin_len(r);
      const out = new Uint8Array(n);
      for (let i = 0; i < n; i++) out[i] = e.bin_get(r, i);
      return new Response(dec.decode(out), { headers: { "content-type": "application/json" } });
    } catch (err) {
      const fn = ((err.stack || "").match(/at (\S+) \(wasm/) || [])[1] || String(err.message);
      return new Response(JSON.stringify({ trap: fn.replace(/^Elixir_46_/, "").replace(/_46_/g, ".") }), { status: 500 });
    }
  }
}

export default {
  async fetch(req, env) {
    const actor = new URL(req.url).searchParams.get("actor") || "default";
    return env.LEDGER.get(env.LEDGER.idFromName(actor)).fetch(req);
  },
};
