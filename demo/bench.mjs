// demo/bench.mjs <wasm> <fixture> — time the REAL Req pipeline on WasmGC, network-free.
// The fetch already happened once (captured to the fixture); the host http.get just hands back those
// in-memory bytes, so e.run() is pure compute: Req.new/merge → URI.parse → step pipeline → decode_body →
// extract JS URLs → :crypto.hash(:sha256). Report module-compile, instantiate, and per-run cost.
import fs from "node:fs";
import nodeCrypto from "node:crypto";
import { makeBig, makeMath, makeStr, makeCrypto, makeProcStubs, binCodec } from "../runtime/imports.mjs";
const [wasmPath, fixturePath] = process.argv.slice(2);
const fixture = fs.readFileSync(fixturePath);
const bytes = fs.readFileSync(wasmPath);

const big = makeBig();
const math = makeMath();
let e;
const { wrBytes } = binCodec(() => e);
const str = makeStr(() => e);
// the response body lives in wasm memory (built ONCE); http.get returns that ref — so we measure the Req
// pipeline + parse + hash, not the byte-by-byte boundary copy. (A real host would bulk-copy once/request.)
let fixtureBin = null;
const http = { get: _ => fixtureBin };
const crypto = makeCrypto(() => e, nodeCrypto);
const { proc, sched } = makeProcStubs();

const ms = () => performance.now();
let t = ms(); const mod = new WebAssembly.Module(bytes); const tCompile = ms() - t;
t = ms(); e = new WebAssembly.Instance(mod, { big, math, str, http, crypto, proc, sched }).exports; const tInstance = ms() - t;
fixtureBin = wrBytes(fixture);                      // build the response binary in wasm ONCE

for (let i = 0; i < 50; i++) e.run();              // warm up (JIT)
const N = 5000;
t = ms(); for (let i = 0; i < N; i++) e.run(); const total = ms() - t;

console.log(JSON.stringify({
  wasm_bytes: bytes.length,
  module_compile_ms: +tCompile.toFixed(2),
  instantiate_ms: +tInstance.toFixed(2),
  runs: N,
  per_run_us: +((total / N) * 1000).toFixed(2),
  runs_per_sec: Math.round(N / (total / 1000)),
}));
