// PYTHON ON CLOUDFLARE WORKERS — via two layers of compiled Elixir:
//   your POST body (Python) -> pyex (a Python 3 interpreter in pure Elixir) -> WasmGC.
//
//   POST /            body = Python source        -> transcript (print output + repr/error)
//   GET  /            a minimal playground page
//   GET  /health      "ok <export count>"
//
// One instance per isolate; each request evals in a fresh pyex Ctx (the only shared state is
// pyex's pure builtins-env cache). A runaway program hits the platform CPU cap and returns 500.
import pyexModule from "./pyex_wasm.wasm";
import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, memFsBacking, termToJs } from "./imports.mjs";

const big = makeBig(), math = makeMath();
let e;
const str = makeStr(() => e);
const { proc, sched } = makeProcStubs();
e = new WebAssembly.Instance(pyexModule, {
  big, math, str, proc, sched,
  fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e),
  // capability-style honest stubs: pyex's host-effect stdlib traps cleanly if a program asks
  crypto: { hash: () => { throw new Error("crypto not wired in this host"); } },
  http: { get: () => { throw new Error("http not wired in this host"); } },
}).exports;

const enc = new TextEncoder(), dec = new TextDecoder();
const toBin = (s) => { const u = enc.encode(s); const b = e.bin_alloc(u.length); for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]); return b; };
const fromBin = (b) => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return dec.decode(u); };

export default {
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/health") return new Response("ok " + Object.keys(e).length);
    if (req.method === "POST") {
      // query params become Python variables, prepended as assignments: numbers stay numeric
      // literals, everything else a (escaped) string. ?lat1=33.94&code1=LAX -> lat1 = 33.94 ...
      const prelude = [...url.searchParams]
        .filter(([k]) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(k))
        .slice(0, 32)
        .map(([k, v]) => `${k} = ${/^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(v) ? v : JSON.stringify(String(v).slice(0, 256))}`)
        .join("\n");
      const body = await req.text();
      const source = prelude ? prelude + "\n" + body : body;
      // the 64KB cap guards the LEXER (per-char recursion depth); /json data rides a separate
      // channel decoded by compiled Jason and is capped at 1MB instead.
      const isJson = url.pathname === "/json" && (req.headers.get("content-type") || "").includes("application/json");
      if (!isJson && source.length > 65536) return new Response("source too large (64KB max)", { status: 413 });
      if (isJson && source.length > 1048576) return new Response("payload too large (1MB max)", { status: 413 });
      try {
        const t0 = Date.now();
        if (url.pathname === "/json") {
          // terms across the boundary: the export returns {:ok, value, stdout} | {:error, kind, msg}
          // as a LIVE WasmGC term; termToJs walks the graph and JSON is just the last-inch render.
          // Body may be {"code": ..., "data": ...}: data rides a SEPARATE channel, decoded by
          // compiled Jason and injected as params.data — payloads never pass through the lexer
          // (whose per-char recursion depth is the platform stack bound; LIMITATIONS §1.4).
          let walked;
          if (isJson) {
            const { code, data } = JSON.parse(source);
            if (String(code).length > 65536) return new Response("code too large (64KB max)", { status: 413 });
            walked = termToJs(e, e.eval_data(toBin(String(code)), toBin(JSON.stringify(data ?? null))));
          } else {
            walked = termToJs(e, e.eval_value(toBin(source)));
          }
          const body = walked[0] === ":ok"
            ? { ok: true, result: walked[1], stdout: walked[2] }
            : { ok: false, error: { kind: walked[1], message: walked[2] } };
          return new Response(JSON.stringify(body), {
            headers: { "content-type": "application/json", "x-eval-ms": String(Date.now() - t0) },
          });
        }
        const out = fromBin(e.eval(toBin(source)));
        return new Response(out, {
          headers: { "content-type": "text/plain; charset=utf-8", "x-eval-ms": String(Date.now() - t0) },
        });
      } catch (err) {
        const fn = ((err.stack || "").match(/at (\S+) \(wasm/) || [])[1] || String(err.message);
        return new Response("wasm trap: " + fn.replace(/^Elixir_46_/, "").replace(/_46_/g, "."), { status: 500 });
      }
    }
    return new Response(PAGE, { headers: { "content-type": "text/html; charset=utf-8" } });
  },
};

const PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Python on WasmGC</title>
<style>
  :root { color-scheme: light dark; --line: #d7d2c5; --ink: #2c2a26; --bg: #faf8f2; --accent: #3b7443; --soft: #f0ede4; }
  @media (prefers-color-scheme: dark) { :root { --line: #3a3a3a; --ink: #e8e6e0; --bg: #1c1b19; --soft: #2a2926; } }
  * { box-sizing: border-box; }
  body { font: 15px/1.5 ui-monospace, "SF Mono", Menlo, monospace; color: var(--ink); background: var(--bg); max-width: 820px; margin: 2rem auto; padding: 0 1rem; }
  h1 { font-size: 1.15rem; } h1 small { font-weight: 400; opacity: .65; display: block; font-size: .78rem; margin-top: .2rem; }
  textarea { width: 100%; height: 16rem; font: inherit; padding: .7rem; border: 1px solid var(--line); border-radius: 8px; background: var(--soft); color: var(--ink); resize: vertical; tab-size: 4; }
  .bar { display: flex; gap: .6rem; align-items: center; margin: .7rem 0; }
  button { font: inherit; padding: .4rem 1.1rem; border: 1px solid var(--accent); border-radius: 6px; background: var(--accent); color: #fff; cursor: pointer; }
  #ms { opacity: .6; font-size: .8rem; }
  pre { background: var(--soft); border: 1px solid var(--line); border-radius: 8px; padding: .8rem; white-space: pre-wrap; min-height: 4rem; }
  footer { margin-top: 1.6rem; font-size: .75rem; opacity: .6; line-height: 1.6; }
</style></head><body>
<h1>python, twice removed<small>your code → pyex (a Python interpreter in Elixir) → compiled BEAM bytecode → WasmGC → this Worker</small></h1>
<textarea id="src" spellcheck="false">def fib(n):
    return n if n < 2 else fib(n-1) + fib(n-2)

print([fib(i) for i in range(15)])
print(f"2**100 = {2**100}")
</textarea>
<div class="bar"><button onclick="run()">run</button><span id="ms"></span></div>
<pre id="out">…</pre>
<footer>Stateless: every request evaluates in a fresh interpreter context. The interpreter is
<a href="https://github.com/ivarvong/pyex">pyex</a>, pure Elixir, compiled to WasmGC by beam2wasm —
the same compiled module runs transcript-identical to the BEAM (16/16 differential battery).
Ints are exact to arbitrary precision; floats are IEEE-754; round() is banker's via Decimal.</footer>
<script>
async function run() {
  const t0 = performance.now();
  document.getElementById("out").textContent = "…";
  const r = await fetch("/", { method: "POST", body: document.getElementById("src").value });
  const text = await r.text();
  document.getElementById("ms").textContent = (performance.now() - t0).toFixed(0) + " ms (server " + (r.headers.get("x-eval-ms") || "?") + " ms)";
  document.getElementById("out").textContent = text;
}
document.getElementById("src").addEventListener("keydown", (ev) => {
  if ((ev.metaKey || ev.ctrlKey) && ev.key === "Enter") run();
});
</script></body></html>`;
