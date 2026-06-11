// host.mjs — one-call instantiation for compiled-Elixir WasmGC modules.
//
//   import { instantiate } from "beam2wasm/priv/host.mjs";   // or a relative path
//   const m = await instantiate("path/to/app.wasm");          // or bytes / WebAssembly.Module
//   m.exports.f(...)                                          // raw exports
//   m.callBin("render_md", "## hi")                           // bin->bin convenience
//   m.toJs(m.exports.f(1))                                    // walk a returned TERM into JS
//
// Provides the full default import surface (big/math/str/proc/sched/fs/io + honest stubs for
// crypto/http/sql) so any module this compiler emits instantiates without boilerplate.
// Override any backing via opts: instantiate(src, { sql: myBacking, fs: myFsBacking, ... }).
//
// Edge-runtime safe: node:fs is imported lazily and ONLY when src is a file path, so on
// Cloudflare Workers pass the WebAssembly.Module (`import mod from "./app.wasm"`) or bytes.
import {
  makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, makeSql,
  memFsBacking, termToJs,
} from "./imports.mjs";

const honestStub = (name) => new Proxy({}, {
  get: (_t, fn) => () => { throw new Error(`${name}.${String(fn)} not wired in this host`); },
});

export async function instantiate(src, opts = {}) {
  const mod =
    src instanceof WebAssembly.Module ? src :
    new WebAssembly.Module(
      typeof src === "string" ? (await import("node:fs")).readFileSync(src) : src);

  const big = makeBig(), math = makeMath();
  let e;
  const str = makeStr(() => e);
  const { proc, sched } = makeProcStubs();
  const imports = {
    big, math, str, proc, sched,
    fs: makeFs(() => e, opts.fs ?? memFsBacking()),
    io: makeIo(() => e, opts.ioSink),
    crypto: opts.crypto ?? honestStub("crypto"),
    http: opts.http ?? honestStub("http"),
    sql: opts.sql ? makeSql(() => e, opts.sql) : honestStub("sql"),
    ...(opts.imports ?? {}),
  };
  e = new WebAssembly.Instance(mod, imports).exports;

  const enc = new TextEncoder(), dec = new TextDecoder();
  const toBin = (s) => {
    const u = typeof s === "string" ? enc.encode(s) : s;
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

  return {
    module: mod,
    exports: e,
    toBin,
    fromBin,
    toJs: (term) => termToJs(e, term),
    callBin: (name, arg) => fromBin(e[name](toBin(arg))),
  };
}

export { termToJs };
