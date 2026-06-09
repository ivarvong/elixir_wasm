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

  // PCRE -> JS RegExp translation (the documented NIF-fidelity boundary, maximized):
  // - Elixir regex OPTS map to JS flags (i/m/s/u); x (extended) strips unescaped whitespace +
  //   #-comments outside character classes (JS has no x flag).
  // - PCRE-only syntax JS rejects: (?'name'...) -> (?<name>...); \A -> ^; \z/\Z -> $;
  //   \h -> [ \t]; \R -> any-newline alternation.
  const pcre2js = (src, opts, extraFlags = "") => {
    let flags = extraFlags;
    // NB: PCRE's :unicode is deliberately NOT mapped to JS `u` — PCRE default is byte-mode and JS
    // non-u mode is the closer (and escape-tolerant) semantics.
    for (const f of ["i", "m", "s"]) if (opts.includes(f) && !flags.includes(f)) flags += f;
    let s = src;
    if (opts.includes("x")) {
      let out = "", inClass = false;
      for (let i = 0; i < s.length; i++) {
        const c = s[i];
        if (c === "\\") { out += c + (s[i + 1] ?? ""); i++; continue; }
        if (c === "[") inClass = true;
        else if (c === "]") inClass = false;
        if (!inClass) {
          if (c === "#") { while (i < s.length && s[i] !== "\n") i++; continue; }
          if (/\s/.test(c)) continue;
        }
        out += c;
      }
      s = out;
    }
    s = s.replace(/\(\?'([^']+)'/g, "(?<$1>");
    s = s.replace(/\\A/g, "^").replace(/\\z/g, "$").replace(/\\Z/g, "$");
    s = s.replace(/\\h/g, "[ \\t]").replace(/\\R/g, "(?:\\r\\n|\\r|\\n)");
    s = s.replace(/\\#/g, "#").replace(/\\ /g, " ");   // PCRE x-mode escapes JS rejects
    // PCRE branch-reset (?|...) -> (?:...). Exact when the FIRST alternative participates (shared
    // numbering); a later alternative shifts capture positions — a documented fidelity edge.
    s = s.replace(/\(\?\|/g, "(?:");
    return new RegExp(s, flags);
  };
  const jsre = (patB, optsB, extraFlags = "") => pcre2js(rdBin(patB), rdBin(optsB), extraFlags);

  // Regex.split -> JS .split. Frame parts as <<count:32, (len:32, bytes)...>> big-endian.
  const re_split = (patB, optsB, subjB) => {
    const parts = rdBin(subjB).split(jsre(patB, optsB));
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
  const re_run = (patB, optsB, subjB) => {
    const m = rdBin(subjB).match(jsre(patB, optsB));
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

  // Regex.run(re, subj, return: :index): match positions as BYTE offsets. Frame:
  // <<matched:8, count:32, (off:32, len:32)...>> for [full_match, captures...]; non-participating
  // group -> (0xFFFFFFFF, 0) so the WAT can emit {-1,0} like :re. No match -> <<0>>.
  const re_run_index = (patB, optsB, subjB) => {
    const subj = rdBin(subjB);
    const m = jsre(patB, optsB, "d").exec(subj);
    if (!m) return wrBytes(new Uint8Array([0]));
    const blen = (s) => encU.encode(s).length; // UTF-16 index -> byte offset
    let idx = Array.from(m.indices);
    while (idx.length > 1 && idx[idx.length - 1] === undefined) idx.pop();
    const buf = new Uint8Array(5 + idx.length * 8);
    const dv = new DataView(buf.buffer);
    buf[0] = 1;
    dv.setUint32(1, idx.length);
    let o = 5;
    for (const gi of idx) {
      if (gi === undefined) { dv.setUint32(o, 0xffffffff); dv.setUint32(o + 4, 0); }
      else { const s = blen(subj.slice(0, gi[0])); dv.setUint32(o, s); dv.setUint32(o + 4, blen(subj.slice(0, gi[1])) - s); }
      o += 8;
    }
    return wrBytes(buf);
  };

  // Regex.replace(re, subj, replacement) with a STRING replacement (global). Convert Elixir replacement
  // syntax to JS: \0 -> whole match, \N -> capture N, literal $ -> $$ (so JS doesn't reinterpret it).
  const elixirReplToJs = (r) => {
    let out = "";
    for (let i = 0; i < r.length; i++) {
      const c = r[i];
      if (c === "$") out += "$$";
      else if (c === "\\" && i + 1 < r.length) {
        const n = r[i + 1];
        if (n === "0") { out += "$&"; i++; }
        else if (n >= "1" && n <= "9") { out += "$" + n; i++; }
        else if (n === "\\") { out += "\\"; i++; }
        else out += c;
      } else out += c;
    }
    return out;
  };
  const re_replace = (patB, optsB, subjB, replB, global) =>
    wrBin(rdBin(subjB).replace(jsre(patB, optsB, global ? "g" : ""), elixirReplToJs(rdBin(replB))));

  // Regex.replace with a FUNCTION replacement: per match, call back into the module's exported
  // re_fun_call (which dispatches on the closure's arity: fn(match) or fn(match, cap1)).
  const re_replace_fun = (patB, optsB, subjB, funRef, global) => {
    const re = jsre(patB, optsB, global ? "g" : "");
    const ncaps = new RegExp(re.source + "|").exec("").length - 1;
    const out = rdBin(subjB).replace(re, (...args) => {
      const m = args[0];
      const cap1 = ncaps >= 1 && args[1] !== undefined ? args[1] : "";
      return rdBin(getExports().re_fun_call(funRef, wrBin(m), wrBin(cap1), ncaps));
    });
    return wrBin(out);
  };

  // Regex.match?/2 -> boolean i32.
  const re_test = (patB, optsB, subjB) => (jsre(patB, optsB).test(rdBin(subjB)) ? 1 : 0);

  // Regex.scan/2: ALL matches. Frame: <<nmatches:32, (ncaps:32, (len:32, bytes)...)...>>; each match
  // emits [full, caps...] with a non-participating group as "" (Regex.scan semantics, unlike run's nil).
  const re_scan = (patB, optsB, subjB) => {
    const re = jsre(patB, optsB, "g");
    const s = rdBin(subjB);
    const matches = [];
    let m;
    while ((m = re.exec(s)) !== null) {
      matches.push(Array.from(m, (c) => (c === undefined ? "" : c)));
      if (m[0] === "") re.lastIndex++;        // avoid infinite loop on empty matches
    }
    const enc = matches.map((caps) => caps.map((c) => encU.encode(c)));
    const total = 4 + enc.reduce((s1, caps) => s1 + 4 + caps.reduce((s2, c) => s2 + 4 + c.length, 0), 0);
    const buf = new Uint8Array(total);
    const dv = new DataView(buf.buffer);
    dv.setUint32(0, enc.length);
    let o = 4;
    for (const caps of enc) {
      dv.setUint32(o, caps.length);
      o += 4;
      for (const c of caps) { dv.setUint32(o, c.length); o += 4; buf.set(c, o); o += c.length; }
    }
    return wrBytes(buf);
  };

  // Regex.escape/1 — Elixir's exact escape set: regex metachars, backslash, and whitespace,
  // each prefixed with a backslash (the whitespace char itself is kept, prefixed).
  const re_escape = (b) => wrBin(rdBin(b).replace(/[.^$*+?()[\]{}|#\\\s-]/g, (c) => "\\" + c));

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
    re_run_index,
    re_replace,
    re_replace_fun,
    re_test,
    re_scan,
    re_escape,
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
