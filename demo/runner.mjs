// demo/runner.mjs <wasm> <fixture-html> — run Resy.run() on WasmGC.
// The `http.get` host import returns the captured fixture (the single, controlled HTTP effect),
// so the Wasm sees byte-identical input to the VM. Reads the returned binary (the JS-URL list) out.
import fs from "node:fs";
import nodeCrypto from "node:crypto";
const [wasmPath, fixturePath] = process.argv.slice(2);
const encU = new TextEncoder(), decU = new TextDecoder();
const fixture = fs.readFileSync(fixturePath);

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
const wrBytes = u => { const b = e.bin_alloc(u.length); for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]); return b; };
const rdBin = b => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return decU.decode(u); };
const reSplit = (patB, subjB) => {
  const parts = rdBin(subjB).split(new RegExp(rdBin(patB)));
  const chunks = parts.map(p => encU.encode(p));
  const total = 4 + chunks.reduce((s, c) => s + 4 + c.length, 0);
  const buf = new Uint8Array(total), dv = new DataView(buf.buffer);
  dv.setUint32(0, chunks.length);
  let o = 4;
  for (const c of chunks) { dv.setUint32(o, c.length); o += 4; buf.set(c, o); o += c.length; }
  return wrBytes(buf);
};
// Regex.run -> JS .match. Frame: <<matched:8, count:32, (len:32|0xFFFFFFFF for nil, bytes)...>>.
const reRun = (patB, subjB) => {
  const m = rdBin(subjB).match(new RegExp(rdBin(patB)));
  if (!m) { const b = e.bin_alloc(1); e.bin_put(b, 0, 0); return b; }
  const caps = Array.from(m); // [full, g1, g2, …]
  // match Erlang :re.run / Regex.run: drop TRAILING non-participating groups; empty-string the rest.
  while (caps.length > 1 && caps[caps.length - 1] === undefined) caps.pop();
  const enc = caps.map(c => encU.encode(c === undefined ? "" : c));
  const total = 5 + enc.reduce((s, c) => s + 4 + (c ? c.length : 0), 0);
  const buf = new Uint8Array(total), dv = new DataView(buf.buffer);
  buf[0] = 1; dv.setUint32(1, enc.length);
  let o = 5;
  for (const c of enc) {
    if (c === null) { dv.setUint32(o, 0xFFFFFFFF); o += 4; }
    else { dv.setUint32(o, c.length); o += 4; buf.set(c, o); o += c.length; }
  }
  return wrBytes(buf);
};
const str = {
  upcase: b => wrBytes(encU.encode(rdBin(b).toUpperCase())),
  downcase: b => wrBytes(encU.encode(rdBin(b).toLowerCase())),
  re_split: reSplit,
  re_run: reRun,
  titlecase: b => { const s = rdBin(b); return wrBytes(encU.encode(s.length ? s[0].toUpperCase() + s.slice(1) : s)); },
};
// the host owns the socket: Req.get!(url) -> this. Returns the captured response body, as a binary.
const http = { get: _url => wrBytes(fixture) };
// the host owns the NIF: :crypto.hash(algo, data) -> the real digest via node crypto (= OpenSSL).
const rawBytes = b => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return u; };
const nodeAlgo = { sha: "sha1", sha224: "sha224", sha256: "sha256", sha384: "sha384", sha512: "sha512", md5: "md5" };
const crypto = {
  hash: (algoB, dataB) => {
    const algo = decU.decode(rawBytes(algoB));
    const d = nodeCrypto.createHash(nodeAlgo[algo] || algo).update(Buffer.from(rawBytes(dataB))).digest();
    return wrBytes(new Uint8Array(d));
  },
};

// Real Req reaches GenServer/process code (Finch's pool callbacks, kept by apply-dispatch DCE) but never
// EXECUTES it on the happy path — the adapter is overridden, so no transport/pool runs. Benign stubs
// satisfy the imports; a real process dictionary in case a lib uses it for caching.
const pdict = new Map();
const proc = {
  spawn: () => 999, spawn_link: () => 999, spawn_opt: () => 999,
  send: (_p, m) => m, self: () => 1,
  recv_has: () => 0, recv_cur: () => null, recv_remove: () => {}, recv_advance: () => {}, recv_wait: () => {},
  exit: () => {}, set_trap_exit: () => {}, register: () => {}, whereis: () => 0,
  monitor: () => 1, demonitor: () => {}, alias_pid: p => p,
  pdict_get: k => pdict.has(k) ? pdict.get(k) : null,
  pdict_put: (k, v) => { const old = pdict.has(k) ? pdict.get(k) : null; pdict.set(k, v); return old; },
};
const sched = { yield: () => {} };

e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { big, math, str, http, crypto, proc, sched }).exports;
process.stdout.write(rdBin(e.run()));
