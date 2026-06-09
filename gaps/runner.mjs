// gaps/runner.mjs <wasm> <seed> — run Gap.run(seed); print the integer, or "TRAP@<function>" with the
// trapping Wasm function name (needs a -g build). Makes the gap grind a worklist instead of "TRAP".
import fs from "node:fs";
const [wasmPath, seedStr] = process.argv.slice(2);
const encU = new TextEncoder(), decU = new TextDecoder();
const big = {
  from_i64: x => x, from_str: x => BigInt(String(x)),
  add: (a, b) => a + b, sub: (a, b) => a - b, mul: (a, b) => a * b, div: (a, b) => a / b, rem: (a, b) => a % b,
  band: (a, b) => a & b, bor: (a, b) => a | b, bxor: (a, b) => a ^ b,
  bsl: (a, b) => b >= 0n ? a << b : a >> -b, bsr: (a, b) => b >= 0n ? a >> b : a << -b,
  fits_i31: a => (a >= -1073741824n && a < 1073741824n) ? 1 : 0, to_i32: a => Number(a),
  fits_i64: a => (a >= -9223372036854775808n && a <= 9223372036854775807n) ? 1 : 0, to_i64: a => BigInt.asIntN(64, a),
  cmp: (a, b) => a < b ? -1 : a > b ? 1 : 0, bit_length: a => a === 0n ? 0 : a.toString(2).length, to_f64: a => Number(a),
};
const math = Object.fromEntries(["sin","cos","tan","asin","acos","atan","sqrt","exp","log","log2",
  "log10","sinh","cosh","tanh","ceil","floor","atan2","pow"].map(k => [k, Math[k]]));
let e;
const wrBin = s => { const u = encU.encode(s); const b = e.bin_alloc(u.length); u.forEach((c, i) => e.bin_put(b, i, c)); return b; };
const rdBin = b => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return decU.decode(u); };
// Regex.split delegated to JS RegExp: split the subject, frame parts as <<count:32,(len:32,bytes)...>> big-endian.
const reSplit = (patB, subjB) => {
  const parts = rdBin(subjB).split(new RegExp(rdBin(patB)));
  const chunks = parts.map(p => encU.encode(p));
  const total = 4 + chunks.reduce((s, c) => s + 4 + c.length, 0);
  const buf = new Uint8Array(total), dv = new DataView(buf.buffer);
  dv.setUint32(0, chunks.length);
  let o = 4;
  for (const c of chunks) { dv.setUint32(o, c.length); o += 4; buf.set(c, o); o += c.length; }
  const b = e.bin_alloc(total); for (let i = 0; i < total; i++) e.bin_put(b, i, buf[i]); return b;
};
const reRun = (patB, subjB) => {
  const m = rdBin(subjB).match(new RegExp(rdBin(patB)));
  if (!m) { const b = e.bin_alloc(1); e.bin_put(b, 0, 0); return b; }
  let caps = Array.from(m); while (caps.length > 1 && caps[caps.length - 1] === undefined) caps.pop();
  const enc = caps.map(c => encU.encode(c === undefined ? "" : c));
  const total = 5 + enc.reduce((s, c) => s + 4 + c.length, 0);
  const buf = new Uint8Array(total), dv = new DataView(buf.buffer);
  buf[0] = 1; dv.setUint32(1, enc.length);
  let o = 5; for (const c of enc) { dv.setUint32(o, c.length); o += 4; buf.set(c, o); o += c.length; }
  const b = e.bin_alloc(total); for (let i = 0; i < total; i++) e.bin_put(b, i, buf[i]); return b;
};
const titlecase = b => { const s = rdBin(b); return wrBin(s.length ? s[0].toUpperCase() + s.slice(1) : s); };
const str = { upcase: b => wrBin(rdBin(b).toUpperCase()), downcase: b => wrBin(rdBin(b).toLowerCase()), re_split: reSplit, re_run: reRun, titlecase, upchar: cp => String.fromCodePoint(cp).toUpperCase().codePointAt(0) };
try {
  e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { big, math, str }).exports;
  process.stdout.write(String(e.run(Number(seedStr))));
} catch (err) {
  const m = (err.stack || "").match(/at (\S+) \(wasm/);
  const fn = m ? m[1].replace(/^Elixir_46_/, "").replace(/_46_/g, ".") : "?";
  process.stdout.write("TRAP@" + fn);
}
