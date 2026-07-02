// pyex.ivar.workers.dev — the Python-on-WasmGC demo, browser AND server.
//   /                → index.html   (static asset; Python runs in the visitor's browser)
//   /pyex.wasm       → the interpreter, streamed from R2 for the browser. Served RAW — the edge
//                      compresses it once over the wire (~1.7 MB brotli). NB: do NOT pre-compress +
//                      set Content-Encoding here — the edge then double-compresses (advertising only
//                      one layer), and the browser hands WebAssembly.compile still-compressed bytes.
//   POST /api/run    → run Python IN THE WORKER: the same wasm, bundled as a module binding
//                      (workerd forbids runtime WebAssembly.compile, so the API can't reuse the R2
//                      copy — keep worker/pyex.wasm in sync with the R2 object when deploying).
//                      Body: {"code": "...", "files": {"/path": "content"}, "max_steps": 5000000}
//                      or text/plain = raw Python. Reply mirrors the browser worker's result shape:
//                      {ok, ms, stdout, files, footprint, spans} | {ok: false, ms, error}.
//   GET  /api/health → boots the interpreter and runs a 1-liner.
//
// One instance per isolate, booted lazily on the first API hit (asset/wasm requests never pay it).
// Each pyrun call builds a fresh interpreter Ctx + VFS seeded from `files`, so requests share
// nothing but the compiled module. A runaway program burns its step budget and returns a clean
// Python error; the platform CPU cap is the hard backstop behind that.
import pyexModule from "./pyex.wasm";
import {
  makeBig, makeMath, makeStr, makeFs, makeIo, makeCrypto, makeProcStubs, makeSys,
  memFsBacking, termToJs,
} from "../app/src/imports.mjs";

const KEY = "pyex.wasm";
const MAX_CODE = 65_536; // the lexer's per-char recursion depth is the platform stack bound
const MAX_FILES_JSON = 1_048_576;
const DEFAULT_STEPS = 5_000_000;
const MAX_STEPS = 20_000_000;

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "POST, GET, OPTIONS",
  "access-control-allow-headers": "content-type",
};

let e = null;
const enc = new TextEncoder();

function boot() {
  if (e) return e;
  const { proc, sched } = makeProcStubs();
  e = new WebAssembly.Instance(pyexModule, {
    big: makeBig(),
    math: makeMath(),
    str: makeStr(() => e),
    crypto: makeCrypto(() => e, { createHash: () => { throw new Error("hashlib not wired in this host"); } }),
    sys: makeSys(),
    fs: makeFs(() => e, memFsBacking()),
    io: makeIo(() => e, []),
    proc, sched,
  }).exports;
  return e;
}

const bin = (s) => {
  const u = enc.encode(s), b = e.bin_alloc(u.length);
  for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]);
  return b;
};

const safeParse = (s, fallback) => { try { return JSON.parse(s); } catch { return fallback; } };
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", ...CORS } });

function runPython(code, files, maxSteps) {
  boot();
  const t0 = Date.now();
  let res;
  try {
    res = termToJs(e, e.pyrun(bin(code), bin(JSON.stringify(files)), maxSteps));
  } catch (ex) {
    // A wasm trap (a Python corner the compiler doesn't lower yet) can't be caught as an Elixir
    // error — surface it honestly instead of leaking a raw RuntimeError stack.
    const raw = e.exc && ex instanceof WebAssembly.Exception && ex.is(e.exc) ? "uncaught Elixir exception" : String(ex);
    const friendly = /unreachable|Elixir exception/.test(raw)
      ? "this program hit a corner of Python the sandbox doesn't support yet"
      : "host error: " + raw;
    return { ok: false, ms: Date.now() - t0, error: friendly };
  }
  const ms = Date.now() - t0;
  if (Array.isArray(res) && res[0] === ":ok") {
    return {
      ok: true, ms,
      stdout: res[1] || "",
      footprint: res[2] || {},
      files: safeParse(res[3], {}),
      spans: safeParse(res[4], []),
    };
  }
  return { ok: false, ms, error: Array.isArray(res) ? res[1] : String(res) };
}

async function handleRun(request) {
  let code, files = {}, maxSteps = DEFAULT_STEPS;
  const ctype = request.headers.get("content-type") || "";
  if (ctype.includes("application/json")) {
    let body;
    try { body = await request.json(); } catch { return json({ ok: false, error: "invalid JSON body" }, 400); }
    code = String(body.code ?? "");
    if (body.files != null) {
      if (typeof body.files !== "object" || Array.isArray(body.files)) {
        return json({ ok: false, error: "files must be an object of path -> content strings" }, 400);
      }
      files = body.files;
    }
    if (body.max_steps != null) maxSteps = Math.min(Math.max(1, Number(body.max_steps) || DEFAULT_STEPS), MAX_STEPS);
  } else {
    code = await request.text();
  }
  if (!code.trim()) return json({ ok: false, error: "no code provided" }, 400);
  if (code.length > MAX_CODE) return json({ ok: false, error: `code too large (${MAX_CODE} bytes max)` }, 413);
  const filesJson = JSON.stringify(files);
  if (filesJson.length > MAX_FILES_JSON) return json({ ok: false, error: `files too large (${MAX_FILES_JSON} bytes max)` }, 413);
  return json(runPython(code, files, maxSteps));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname.startsWith("/api/")) {
      if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
      if (url.pathname === "/api/health") {
        const r = runPython("print(1 + 1)", {}, 100_000);
        return json({ ok: r.ok && r.stdout === "2\n", exports: Object.keys(boot()).length });
      }
      if (url.pathname === "/api/run" && request.method === "POST") return handleRun(request);
      return json({ ok: false, error: "POST /api/run — body {code, files?, max_steps?} or text/plain Python" }, 404);
    }

    if (url.pathname === "/pyex.wasm") {
      const obj = await env.WASM.get(KEY);
      if (!obj) return new Response("interpreter not uploaded to R2 yet", { status: 503 });

      return new Response(obj.body, {
        headers: {
          "content-type": "application/wasm",
          "etag": obj.httpEtag,
          "cache-control": "public, max-age=31536000, immutable",
        },
      });
    }

    // index.html, assets, and any 404s fall through to the static-asset handler.
    return env.ASSETS.fetch(request);
  },
};
