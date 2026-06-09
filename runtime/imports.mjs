// Shared host imports for compiled-Elixir WasmGC modules — the single source of truth
// so the import surfaces (big, math, str, crypto) can't drift between the various runners
// (runtime/scheduler.mjs, conformance/driver.mjs, gaps/runner.mjs, demo/*). Before this,
// each runner hand-rolled its own `str`, and they had already diverged (only some had
// re_split/re_run/titlecase/upchar), so a module compiled against the richer surface would
// LinkError under a leaner runner.
//
// `str` and `crypto` need the instance's exports (to read/write the WasmGC $binary via the
// exported bin_* helpers), but the instance is created AFTER the import object is built — the
// classic chicken-and-egg. So those factories take a getter, `getExports`, that returns the
// live exports; call them only at runtime (after instantiation), which every runner does.
//
//   import { makeBig, makeMath, makeStr } from "./imports.mjs";
//   const imports = { big: makeBig(), math: makeMath(), str: makeStr(() => instance.exports) };
//   const instance = new WebAssembly.Instance(module, imports);

// Exact arbitrary-precision integers (BIGNUM mode): the $big box wraps a host BigInt. Provided
// unconditionally — a module that doesn't import "big" simply ignores the extra import object.
export const makeBig = () => ({
  from_i64: (x) => x,
  from_str: (x) => BigInt(String(x)),
  add: (a, b) => a + b,
  sub: (a, b) => a - b,
  mul: (a, b) => a * b,
  div: (a, b) => a / b,
  rem: (a, b) => a % b,
  band: (a, b) => a & b,
  bor: (a, b) => a | b,
  bxor: (a, b) => a ^ b,
  bsl: (a, b) => (b >= 0n ? a << b : a >> -b),
  bsr: (a, b) => (b >= 0n ? a >> b : a << -b),
  fits_i31: (a) => (a >= -1073741824n && a < 1073741824n ? 1 : 0),
  to_i32: (a) => Number(a),
  fits_i64: (a) => (a >= -9223372036854775808n && a <= 9223372036854775807n ? 1 : 0),
  to_i64: (a) => BigInt.asIntN(64, a),
  cmp: (a, b) => (a < b ? -1 : a > b ? 1 : 0),
  bit_length: (a) => (a === 0n ? 0 : a.toString(2).length),
  to_f64: (a) => Number(a),
});

// Floats: :math.* lowers to host (JS Math) imports. Provided unconditionally, like `big`.
const MATH_FNS = [
  "sin", "cos", "tan", "asin", "acos", "atan", "sqrt", "exp", "log", "log2",
  "log10", "sinh", "cosh", "tanh", "ceil", "floor", "atan2", "pow",
];
export const makeMath = () => Object.fromEntries(MATH_FNS.map((k) => [k, Math[k]]));

const encU = new TextEncoder();
const decU = new TextDecoder();

// Binary <-> JS helpers over the WasmGC $binary, via the exported bin_* helpers. `getExports`
// returns the live instance exports (resolved lazily; the instance exists by call time).
export const binCodec = (getExports) => {
  const rawBytes = (b) => {
    const e = getExports();
    const n = e.bin_len(b);
    const u = new Uint8Array(n);
    for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i);
    return u;
  };
  const wrBytes = (u) => {
    const e = getExports();
    const b = e.bin_alloc(u.length);
    for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]);
    return b;
  };
  const rdBin = (b) => decU.decode(rawBytes(b));
  const wrBin = (s) => wrBytes(encU.encode(s));
  return { rawBytes, wrBytes, rdBin, wrBin };
};

// String/Regex host shims (genuinely Unicode-table-backed case mapping; :re via JS RegExp).
// This is the union of every runner's surface — the richest variant, so any runner can host any
// compiled module. reRun/reSplit framing matches what the compiler's bs_* match code expects.
export const makeStr = (getExports) => {
  const { rdBin, wrBin, wrBytes } = binCodec(getExports);

  // Regex.split -> JS .split. Frame parts as <<count:32, (len:32, bytes)...>> big-endian.
  const re_split = (patB, subjB) => {
    const parts = rdBin(subjB).split(new RegExp(rdBin(patB)));
    const chunks = parts.map((p) => encU.encode(p));
    const total = 4 + chunks.reduce((s, c) => s + 4 + c.length, 0);
    const buf = new Uint8Array(total);
    const dv = new DataView(buf.buffer);
    dv.setUint32(0, chunks.length);
    let o = 4;
    for (const c of chunks) {
      dv.setUint32(o, c.length);
      o += 4;
      buf.set(c, o);
      o += c.length;
    }
    return wrBytes(buf);
  };

  // Regex.run -> JS .match. Frame: <<matched:8, count:32, (len:32, bytes)...>>. Trailing
  // non-participating groups are dropped; remaining undefined groups become empty strings
  // (matches Erlang :re.run / Regex.run semantics).
  const re_run = (patB, subjB) => {
    const m = rdBin(subjB).match(new RegExp(rdBin(patB)));
    if (!m) return wrBytes(new Uint8Array([0]));
    const caps = Array.from(m);
    while (caps.length > 1 && caps[caps.length - 1] === undefined) caps.pop();
    const enc = caps.map((c) => encU.encode(c === undefined ? "" : c));
    const total = 5 + enc.reduce((s, c) => s + 4 + c.length, 0);
    const buf = new Uint8Array(total);
    const dv = new DataView(buf.buffer);
    buf[0] = 1;
    dv.setUint32(1, enc.length);
    let o = 5;
    for (const c of enc) {
      dv.setUint32(o, c.length);
      o += 4;
      buf.set(c, o);
      o += c.length;
    }
    return wrBytes(buf);
  };

  return {
    upcase: (b) => wrBin(rdBin(b).toUpperCase()),
    downcase: (b) => wrBin(rdBin(b).toLowerCase()),
    titlecase: (b) => {
      const s = rdBin(b);
      return wrBin(s.length ? s[0].toUpperCase() + s.slice(1) : s);
    },
    upchar: (cp) => String.fromCodePoint(cp).toUpperCase().codePointAt(0),
    re_split,
    re_run,
  };
};

// :crypto.hash NIF -> real digest via node's crypto (OpenSSL). `nodeCrypto` is injected so this
// module stays free of node-only imports for runners that don't need crypto.
const NODE_ALGO = { sha: "sha1", sha224: "sha224", sha256: "sha256", sha384: "sha384", sha512: "sha512", md5: "md5" };
export const makeCrypto = (getExports, nodeCrypto) => {
  const { rawBytes, wrBytes } = binCodec(getExports);
  return {
    hash: (algoB, dataB) => {
      const algo = decU.decode(rawBytes(algoB));
      const d = nodeCrypto.createHash(NODE_ALGO[algo] || algo).update(Buffer.from(rawBytes(dataB))).digest();
      return wrBytes(new Uint8Array(d));
    },
  };
};

// Benign proc/sched stubs for runners that keep GenServer/Finch code alive via DCE but never
// execute it (the demo overrides the transport adapter). The REAL scheduler lives in
// runtime/scheduler.mjs; do not use these there.
export const makeProcStubs = () => {
  const pdict = new Map();
  const proc = {
    spawn: () => 999, spawn_link: () => 999, spawn_opt: () => 999,
    send: (_p, m) => m, self: () => 1,
    recv_has: () => 0, recv_cur: () => null, recv_remove: () => {}, recv_advance: () => {}, recv_wait: () => {}, recv_wait_timeout: () => 0,
    exit: () => {}, exit2: () => {}, set_trap_exit: () => {}, register: () => {}, whereis: () => 0,
    monitor: () => 1, demonitor: () => {}, alias_pid: (p) => p,
    pdict_get: (k) => (pdict.has(k) ? pdict.get(k) : null),
    pdict_put: (k, v) => { const old = pdict.has(k) ? pdict.get(k) : null; pdict.set(k, v); return old; },
  };
  const sched = { yield: () => {} };
  return { proc, sched };
};
