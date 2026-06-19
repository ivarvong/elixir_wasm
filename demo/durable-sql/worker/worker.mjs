// A SQLite client INSIDE compiled Elixir, querying the Durable Object's OWN database —
// now with a full-CRUD webapp in front. The CRUD logic (schema, INSERT/SELECT/UPDATE/DELETE
// with RETURNING, aggregates) is SqlLedger.ledger_op/1: real Elixir + real Jason, compiled.
//
//   GET  /                          -> the webapp (HTML, calls the JSON API below)
//   POST /api?actor=X  {op,...}     -> the DO -> compiled Elixir -> its SQLite
//   GET  /?actor=X&op=...&...       -> same ops, curl-friendly
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
    try {
      const op = await req.json();
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
    const url = new URL(req.url);
    const actor = url.searchParams.get("actor") || "default";
    const stub = () => env.LEDGER.get(env.LEDGER.idFromName(actor));

    if (url.pathname === "/api" && req.method === "POST") {
      return stub().fetch(new Request(req.url, { method: "POST", body: await req.text() }));
    }
    if (url.searchParams.has("op")) {
      // curl-friendly GET form: build the op JSON from query params
      const op = { op: url.searchParams.get("op") };
      for (const k of ["kind"]) if (url.searchParams.has(k)) op[k] = url.searchParams.get(k);
      for (const k of ["amount", "id"]) if (url.searchParams.has(k)) op[k] = parseInt(url.searchParams.get(k), 10);
      return stub().fetch(new Request(url.origin + "/api", { method: "POST", body: JSON.stringify(op) }));
    }
    return new Response(PAGE, { headers: { "content-type": "text/html; charset=utf-8" } });
  },
};

const PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Elixir × SQLite × Durable Objects</title>
<style>
  :root { color-scheme: light dark; --line: #d7d2c5; --ink: #2c2a26; --bg: #faf8f2; --accent: #4f46e5; --soft: #f0ede4; }
  @media (prefers-color-scheme: dark) { :root { --line: #3a3a3a; --ink: #e8e6e0; --bg: #1c1b19; --soft: #2a2926; } }
  * { box-sizing: border-box; }
  body { font: 15px/1.5 ui-monospace, "SF Mono", Menlo, monospace; color: var(--ink); background: var(--bg); max-width: 760px; margin: 2rem auto; padding: 0 1rem; }
  h1 { font-size: 1.15rem; } h1 small { font-weight: 400; opacity: .65; display: block; font-size: .8rem; }
  .bar { display: flex; gap: .5rem; align-items: center; margin: 1rem 0; flex-wrap: wrap; }
  input, select, button { font: inherit; padding: .35rem .55rem; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); color: var(--ink); }
  input[type=number] { width: 6.5rem; } #kind { width: 9rem; }
  button { cursor: pointer; background: var(--soft); } button.primary { background: var(--accent); color: #fff; border-color: var(--accent); }
  table { width: 100%; border-collapse: collapse; margin-top: 1rem; }
  th, td { text-align: left; padding: .4rem .5rem; border-bottom: 1px solid var(--line); }
  td.num, th.num { text-align: right; } tr.editing { background: var(--soft); }
  .pill { display: inline-block; padding: .05rem .5rem; border: 1px solid var(--line); border-radius: 999px; font-size: .8rem; }
  #balance { font-size: 1.3rem; font-weight: 700; }
  #bykind { margin-top: .5rem; opacity: .8; font-size: .85rem; }
  .neg { color: #c0392b; } .row-actions button { padding: .1rem .45rem; font-size: .8rem; }
  footer { margin-top: 2rem; font-size: .75rem; opacity: .6; }
</style></head><body>
<h1>ledger<small>every row below is SELECTed by compiled Elixir from this actor's own SQLite, inside a Durable Object</small></h1>
<div class="bar">
  <label>actor <input id="actor" value="demo" size="10"></label>
  <span id="balance">…</span>
</div>
<div id="bykind"></div>
<div class="bar">
  <input id="kind" placeholder="kind (e.g. coffee)">
  <input id="amount" type="number" placeholder="amount">
  <button class="primary" onclick="createEntry()">add</button>
</div>
<table><thead><tr><th>id</th><th>kind</th><th class="num">amount</th><th></th></tr></thead><tbody id="rows"></tbody></table>
<footer>CRUD via <code>SqlLedger.ledger_op/1</code> — Elixir compiled to WasmGC, SQL through the <code>sql</code> host import to <code>ctx.storage.sql</code>. Switch the actor to get a different (isolated, durable) database.</footer>
<script>
const $ = (id) => document.getElementById(id);
async function api(op) {
  const r = await fetch("/api?actor=" + encodeURIComponent($("actor").value || "default"),
    { method: "POST", body: JSON.stringify(op) });
  return r.json();
}
function esc(s) { const d = document.createElement("div"); d.textContent = s; return d.innerHTML; }
async function refresh() {
  const data = await api({ op: "list" });
  $("balance").textContent = "balance " + data.balance;
  $("balance").className = data.balance < 0 ? "neg" : "";
  $("bykind").innerHTML = (data.by_kind || []).map(k => '<span class="pill">' + esc(k.kind) + " · " + k.n + " · " + k.total + "</span>").join(" ");
  $("rows").innerHTML = data.entries.map(e =>
    '<tr id="r' + e.id + '"><td>' + e.id + '</td><td>' + esc(e.kind) + '</td><td class="num' + (e.amount < 0 ? " neg" : "") + '">' + e.amount + '</td>' +
    '<td class="row-actions"><button onclick="editEntry(' + e.id + ',this)">edit</button> <button onclick="deleteEntry(' + e.id + ')">delete</button></td></tr>'
  ).join("");
}
async function createEntry() {
  const kind = $("kind").value.trim(), amount = parseInt($("amount").value, 10);
  if (!kind || isNaN(amount)) return;
  await api({ op: "add", kind, amount });
  $("kind").value = ""; $("amount").value = "";
  refresh();
}
function editEntry(id, btn) {
  const tr = $("r" + id), tds = tr.children;
  const kind = tds[1].textContent, amount = tds[2].textContent;
  tr.classList.add("editing");
  tds[1].innerHTML = '<input id="ek' + id + '" value="' + esc(kind) + '" size="8">';
  tds[2].innerHTML = '<input id="ea' + id + '" type="number" value="' + amount + '">';
  tds[3].innerHTML = '<button onclick="saveEntry(' + id + ')">save</button> <button onclick="refresh()">cancel</button>';
  $("ek" + id).focus();
}
async function saveEntry(id) {
  await api({ op: "update", id, kind: $("ek" + id).value.trim(), amount: parseInt($("ea" + id).value, 10) });
  refresh();
}
async function deleteEntry(id) { await api({ op: "delete", id }); refresh(); }
$("actor").addEventListener("change", refresh);
$("amount").addEventListener("keydown", (e) => { if (e.key === "Enter") createEntry(); });
refresh();
</script></body></html>`;
