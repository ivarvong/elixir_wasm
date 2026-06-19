// A portfolio rebalancer JSON API on Cloudflare Workers: ordinary pure Elixir + the real
// Jason dep, compiled to WasmGC. Unlike the earlier demo workers this one consumes the
// LIBRARY surface — beam2wasm's priv/host.mjs instantiate() — no hand-wired imports.
//
//   POST /rebalance   {cash, tolerance?, targets, positions} -> the trade plan (JSON)
//   GET  /health      "ok <export count>"
//   GET  /            usage
import wasmModule from "./rebalancer.wasm";
import { instantiate } from "./host.mjs";

const m = await instantiate(wasmModule);

const usage = JSON.stringify({
  service: "portfolio rebalancer — pure Elixir on WasmGC, verified bit-exact vs the BEAM",
  post: "/rebalance",
  request: {
    cash: 5000,
    tolerance: 0.0025,
    targets: { VTI: 0.6, VXUS: 0.3, BND: 0.1 },
    positions: [{ symbol: "VTI", shares: 120, price: 262.41 }],
  },
});

const json = (body, status = 200) =>
  new Response(body, { status, headers: { "content-type": "application/json" } });

export default {
  async fetch(req) {
    const url = new URL(req.url);
    try {
      if (url.pathname === "/health") return new Response("ok " + Object.keys(m.exports).length);
      if (url.pathname === "/rebalance" && req.method === "POST") {
        const body = await req.text();
        if (body.length > 65536) return json(JSON.stringify({ error: "request too large" }), 413);
        const out = m.callBin("rebalance", body);
        return json(out, out.startsWith('{"error"') ? 400 : 200);
      }
      return json(usage, req.method === "GET" ? 200 : 405);
    } catch (err) {
      // an honest trap surfaces as a 500 with the demangled frame, never a wrong plan
      const fn = ((err.stack || "").match(/at (\S+) \(wasm/) || [])[1] || String(err.message);
      return json(
        JSON.stringify({ error: "wasm trap: " + fn.replace(/^Elixir_46_/, "").replace(/_46_/g, ".") }),
        500
      );
    }
  },
};
