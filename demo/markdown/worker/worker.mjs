// The markdown pipeline as a DEPLOYABLE Cloudflare Worker: real unmodified Jason + Earmark,
// compiled to WasmGC, instantiated ONCE per isolate at module scope (no runtime codegen).
//
//   GET  /?seed=N      -> Blog.render(N)        (JSON article -> Jason.decode! -> Earmark -> HTML)
//   POST /render       -> Blog.render_md(body)  (arbitrary markdown -> HTML, real Earmark)
//   GET  /health       -> "ok <module exports count>"
//
// The host-import surface is the same shared imports.mjs every other runner uses — the worker
// wires a virtual in-memory filesystem (memFsBacking) for the effects ABI, exactly as
// LIMITATIONS §1.2 prescribes for Workers.
import blogModule from "./blog.wasm";
import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, memFsBacking } from "./imports.mjs";

const big = makeBig(), math = makeMath();
let e;
const str = makeStr(() => e);
const { proc, sched } = makeProcStubs();
e = new WebAssembly.Instance(blogModule, {
  big, math, str, proc, sched,
  fs: makeFs(() => e, memFsBacking()),
  io: makeIo(() => e),
}).exports;

const enc = new TextEncoder(), dec = new TextDecoder();
const toBin = (s) => {
  const u = enc.encode(s);
  const b = e.bin_alloc(u.length);
  for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]);
  return b;
};
const fromBin = (b) => {
  const n = e.bin_len(b);
  const u = new Uint8Array(n);
  for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i);
  return dec.decode(u);
};

export default {
  async fetch(req) {
    const url = new URL(req.url);
    try {
      if (url.pathname === "/health") return new Response("ok " + Object.keys(e).length);
      if (url.pathname === "/render" && req.method === "POST") {
        const md = await req.text();
        const html = fromBin(e.render_md(toBin(md)));
        return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
      }
      const seed = Number(url.searchParams.get("seed") || "0");
      const html = fromBin(e.render(seed));
      return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
    } catch (err) {
      // an honest trap surfaces as a 500 with the demangled frame, never a wrong page
      const fn = ((err.stack || "").match(/at (\S+) \(wasm/) || [])[1] || String(err.message);
      return new Response("wasm trap: " + fn.replace(/^Elixir_46_/, "").replace(/_46_/g, "."), { status: 500 });
    }
  },
};
