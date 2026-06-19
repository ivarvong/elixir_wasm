// vs_pyodide.mjs — the honest head-to-head: pyex-on-WasmGC (a tree-walking Python interpreter
// written in Elixir, compiled to WasmGC) vs Pyodide (real CPython compiled to wasm/emscripten),
// same Node, same machine, identical programs. Measures what each architecture is actually
// good at: startup/instantiate, first eval, and warm per-eval.
//
//   node vs_pyodide.mjs <pyex_wasm.wasm> <pyodide_node_modules_dir>
import fs from "node:fs";
import nodeCrypto from "node:crypto";
import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, makeCrypto, memFsBacking } from "../../runtime/imports.mjs";

const [wasmPath, pyodideDir] = process.argv.slice(2);

const PROGRAMS = [
  ["haversine", `import math
R = 6371.0088
lat1, lon1, lat2, lon2 = 33.9416, -118.4085, 40.6413, -73.7781
a = math.sin(math.radians(lat2-lat1)/2)**2 + math.cos(math.radians(lat1))*math.cos(math.radians(lat2))*math.sin(math.radians(lon2-lon1)/2)**2
2*R*math.asin(math.sqrt(a))`],
  ["fib15", `def fib(n):
    return n if n < 2 else fib(n-1) + fib(n-2)
[fib(i) for i in range(15)]`],
  ["loop10k", `total = 0
for i in range(10000):
    total += i * i
total`],
  ["bignum", `2**100 + 2**99`],
  ["dictstr", `d = {}
for w in ["alpha", "beta", "gamma", "delta"] * 25:
    d[w.upper()] = d.get(w.upper(), 0) + 1
sorted(d.items())`],
];

const median = (xs) => xs.sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const bench = (f, n = 30) => {
  f(); f(); f();                                   // warm
  const t = [];
  for (let i = 0; i < n; i++) { const t0 = performance.now(); f(); t.push(performance.now() - t0); }
  return median(t);
};

// ── pyex on WasmGC ──
const t0 = performance.now();
const bytes = fs.readFileSync(wasmPath);
const mod = new WebAssembly.Module(bytes);
const tCompile = performance.now() - t0;
const big = makeBig(), math = makeMath();
let e;
const str = makeStr(() => e);
const { proc, sched } = makeProcStubs();
const t1 = performance.now();
e = new WebAssembly.Instance(mod, {
  big, math, str, proc, sched, fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e),
  crypto: makeCrypto(() => e, nodeCrypto), http: { get: () => { throw new Error("x"); } },
}).exports;
const tInst = performance.now() - t1;
const enc = new TextEncoder(), dec = new TextDecoder();
const toBin = (s) => { const u = enc.encode(s); const b = e.bin_alloc(u.length); for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]); return b; };
const fromBin = (b) => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return dec.decode(u); };
const t2 = performance.now();
fromBin(e.eval(toBin("1 + 1")));
const tFirst = performance.now() - t2;
console.log(`pyex-wasm:  compile=${tCompile.toFixed(0)}ms instantiate=${tInst.toFixed(1)}ms first_eval=${tFirst.toFixed(1)}ms  (module ${(bytes.length / 1048576).toFixed(1)}MB raw)`);

const pyexTimes = {};
for (const [name, src] of PROGRAMS) {
  pyexTimes[name] = bench(() => fromBin(e.eval(toBin(src))));
}

// ── Pyodide (real CPython on wasm) ──
const t3 = performance.now();
const { loadPyodide } = await import(pyodideDir + "/pyodide/pyodide.mjs");
const py = await loadPyodide({ indexURL: pyodideDir + "/pyodide" });
const tLoad = performance.now() - t3;
const t4 = performance.now();
py.runPython("1 + 1");
const tFirstPy = performance.now() - t4;
console.log(`pyodide:    load=${tLoad.toFixed(0)}ms first_eval=${tFirstPy.toFixed(1)}ms`);

const pyodideTimes = {};
for (const [name, src] of PROGRAMS) {
  pyodideTimes[name] = bench(() => py.runPython(src));
}

console.log("\nwarm per-eval (median of 30):");
console.log("  program     pyex-wasm    pyodide     ratio");
for (const [name] of PROGRAMS) {
  const a = pyexTimes[name], b = pyodideTimes[name];
  console.log(`  ${name.padEnd(11)} ${(a >= 0.1 ? a.toFixed(2) : a.toFixed(3)).padStart(8)}ms ${(b >= 0.1 ? b.toFixed(2) : b.toFixed(3)).padStart(9)}ms   ${(a / b).toFixed(1)}x ${a > b ? "(pyodide faster)" : "(pyex faster)"}`);
}
