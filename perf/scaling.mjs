// perf/scaling.mjs — time a set of points on a Wasm module, adaptively.
//   node scaling.mjs <module.wasm> <points.json>   ->  JSON [{name,arg,us_min,us_median,slow,crashed}]
//
// A point is either:
//   {op, arg}                  — bulk: time op(arg). Total work as a function of n.
//   {op, arg, setup, reps}     — isolated: build a handle h=setup(arg) ONCE, then time op(h, reps).
//     This measures the per-operation complexity WITHOUT the build masking it (the handle is a
//     WasmGC ref held in JS and passed back in).
// Each point is timed with auto-calibrated iteration counts; a slow/crashing point is contained.
import fs from "node:fs";
const [wasmPath, pointsPath] = process.argv.slice(2);
const encU = new TextEncoder(), decU = new TextDecoder();
const big = {
  from_i64: x => x, from_float: (x) => BigInt(Math.trunc(x)), from_str: x => BigInt(String(x)),
  add: (a, b) => a + b, sub: (a, b) => a - b, mul: (a, b) => a * b, div: (a, b) => a / b, rem: (a, b) => a % b,
  band: (a, b) => a & b, bor: (a, b) => a | b, bxor: (a, b) => a ^ b,
  bsl: (a, b) => b >= 0n ? a << b : a >> -b, bsr: (a, b) => b >= 0n ? a >> b : a << -b,
  fits_i31: a => (a >= -1073741824n && a < 1073741824n) ? 1 : 0, to_i32: a => Number(a),
  fits_i64: a => (a >= -9223372036854775808n && a <= 9223372036854775807n) ? 1 : 0, to_i64: a => BigInt.asIntN(64, a),
  cmp: (a, b) => a < b ? -1 : a > b ? 1 : 0, bit_length: a => a === 0n ? 0 : a.toString(2).length,
};
const math = Object.fromEntries(["sin","cos","tan","asin","acos","atan","sqrt","exp","log","log2",
  "log10","sinh","cosh","tanh","ceil","floor","atan2","pow"].map(k => [k, Math[k]]));
let e;
const wrBin = s => { const u = encU.encode(s); const b = e.bin_alloc(u.length); u.forEach((c, i) => e.bin_put(b, i, c)); return b; };
const rdBin = b => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return decU.decode(u); };
const str = { upcase: b => wrBin(rdBin(b).toUpperCase()), downcase: b => wrBin(rdBin(b).toLowerCase()) };
e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { big, math, str }).exports;

let sink = 0n;
function time(p) {
  try { return timeInner(p); }
  catch (err) { return { op: p.op, arg: p.arg, crashed: true, error: String(err.message || err).split("\n")[0] }; }
}
function timeInner(p) {
  const f = e[p.op];
  let one;
  if (p.setup !== undefined) {
    const h = e[p.setup](p.arg);                          // build the input ONCE
    one = () => { sink += BigInt(String(f(h, p.reps))); };
  } else {
    one = () => { sink += BigInt(String(f(p.arg))); };
  }
  one();                                                  // warm
  const t0 = performance.now(); one(); const single = performance.now() - t0;
  const slow = single > 20;
  let iters = slow ? 1 : Math.max(1, Math.round(60 / Math.max(single, 0.0005)));
  iters = Math.min(iters, 5_000_000);
  const trials = [];
  const K = slow ? 3 : 9;
  for (let k = 0; k < K; k++) {
    const s = performance.now();
    for (let i = 0; i < iters; i++) one();
    trials.push((performance.now() - s) / iters * 1000);  // us per call
  }
  trials.sort((a, b) => a - b);
  return { op: p.op, arg: p.arg, us_min: trials[0], us_median: trials[Math.floor(K / 2)], slow };
}

const points = JSON.parse(fs.readFileSync(pointsPath, "utf8"));
const out = points.map(time);
out.push({ sink: String(sink).slice(-4) });
process.stdout.write(JSON.stringify(out));
