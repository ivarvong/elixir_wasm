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
  from_i64: (x) => x, from_float: (x) => BigInt(Math.trunc(x)),
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
    // \K (match-start reset) and \G (previous-match anchor) have NO JS equivalent — and JS would
    // silently treat them as literal K/G (a wrong-value lie, not an error). Refuse honestly.
    {
      let inClass = false;
      for (let i = 0; i < s.length; i++) {
        const c = s[i];
        if (c === "\\") {
          const n = s[i + 1];
          if (!inClass && (n === "K" || n === "G")) throw new Error(`unsupported PCRE \\${n} (no JS equivalent)`);
        i++; continue;
        }
        if (c === "[") inClass = true;
        else if (c === "]") inClass = false;
      }
    }
    // PCRE's bare $ (and \Z) match before a FINAL newline; JS $ is absolute end. Rewrite unescaped
    // $ outside character classes to (?=\n?$) in non-multiline mode (with m both engines agree).
    if (!flags.includes("m")) {
      let out = "", inClass = false;
      for (let i = 0; i < s.length; i++) {
        const c = s[i];
        if (c === "\\") { out += c + (s[i + 1] ?? ""); i++; continue; }
        if (c === "[") inClass = true;
        else if (c === "]") inClass = false;
        out += (c === "$" && !inClass) ? "(?=\\n?$)" : c;
      }
      s = out;
    }
    s = s.replace(/\(\?'([^']+)'/g, "(?<$1>");
    s = s.replace(/\\A/g, "^").replace(/\\z/g, "$").replace(/\\Z/g, "(?=\\n?$)");
    s = s.replace(/\\h/g, "[ \\t]").replace(/\\R/g, "(?:\\r\\n|\\r|\\n)");
    s = s.replace(/\\#/g, "#").replace(/\\ /g, " ");   // PCRE x-mode escapes JS rejects
    // PCRE branch-reset (?|...) -> (?:...). Exact when the FIRST alternative participates (shared
    // numbering); a later alternative shifts capture positions — a documented fidelity edge.
    s = s.replace(/\(\?\|/g, "(?:");
    // PCRE atomic group (?>...) -> (?:...). Exact when the group's content cannot backtrack
    // internally (single-token groups like (?>\n) — Earmark's usage); a documented fidelity edge
    // for backtracking-sensitive patterns.
    s = s.replace(/\(\?>/g, "(?:");
    return new RegExp(s, flags);
  };
  // Compiled-RegExp cache: Earmark's LineScanner runs ~30 patterns per LINE, and without this
  // every host call re-runs the PCRE->JS translation + `new RegExp`. lastIndex is reset on every
  // hit because re_scan hands out "g" regexes whose exec loop mutates it.
  const reCache = new Map();
  const jsre = (patB, optsB, extraFlags = "") => {
    const key = rdBin(patB) + "\x00" + rdBin(optsB) + "\x00" + extraFlags;
    let re = reCache.get(key);
    if (!re) {
      re = pcre2js(rdBin(patB), rdBin(optsB), extraFlags);
      if (reCache.size < 4096) reCache.set(key, re);
    }
    re.lastIndex = 0;
    return re;
  };

  // Regex.split via an exec loop — NOT JS .split(), which (a) injects capture-group text into the
  // result and (b) drops the leading/trailing empty parts :re.split keeps. `partsLimit` (0 =
  // unlimited) caps the part count with the remainder UNSPLIT (Regex.split parts:); `incCaps`
  // interleaves the matched text (Regex.split include_captures:). Frame parts as
  // <<count:32, (len:32, bytes)...>> big-endian.
  const re_split = (patB, optsB, subjB, partsLimit = 0, incCaps = 0) => {
    const re = jsre(patB, optsB, "g");
    const s = rdBin(subjB);
    const parts = [];
    let last = 0, m;
    while ((m = re.exec(s)) !== null) {
      if (partsLimit > 0 && parts.length >= (incCaps ? 2 : 1) * (partsLimit - 1)) break;
      parts.push(s.slice(last, m.index));
      if (incCaps) parts.push(m[0]);
      last = m.index + m[0].length;
      if (m[0] === "") re.lastIndex++;        // zero-width match: step forward
    }
    parts.push(s.slice(last));
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

  // Regex.named_captures/2: all NAMED groups of the first match, non-participating -> "".
  // Frame: <<matched:8, count:32, (klen:32, kbytes, vlen:32, vbytes)...>> big-endian.
  const re_named = (patB, optsB, subjB) => {
    const m = rdBin(subjB).match(jsre(patB, optsB));
    if (!m) return wrBytes(new Uint8Array([0]));
    const pairs = Object.entries(m.groups ?? {}).map(([k, v]) => [encU.encode(k), encU.encode(v ?? "")]);
    const total = 5 + pairs.reduce((s, [k, v]) => s + 8 + k.length + v.length, 0);
    const buf = new Uint8Array(total);
    const dv = new DataView(buf.buffer);
    buf[0] = 1;
    dv.setUint32(1, pairs.length);
    let o = 5;
    for (const [k, v] of pairs) {
      dv.setUint32(o, k.length); o += 4; buf.set(k, o); o += k.length;
      dv.setUint32(o, v.length); o += 4; buf.set(v, o); o += v.length;
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
    re_named,
    // :unicode NF* normalization — JS .normalize uses the same Unicode tables
    nfc: (b) => wrBin(rdBin(b).normalize("NFC")),
    nfd: (b) => wrBin(rdBin(b).normalize("NFD")),
    nfkc: (b) => wrBin(rdBin(b).normalize("NFKC")),
    nfkd: (b) => wrBin(rdBin(b).normalize("NFKD")),
    // Erlang float_to_binary(F, [:short]): the shortest round-trip DIGITS are unique (Ryu), and JS
    // produces the same ones — only the formatting convention differs. Empirically-derived Erlang
    // rule (validated by differential fuzz): plain iff -3 <= dp <= 15 and dp - len(digits) <= 2,
    // else scientific d.ddd e(dp-1). Plain always keeps >= 1 fractional digit ("100.0").
    // Erlang float_to_binary. mode 0 = [:short]; 1 = default (20-digit scientific, e+NN);
    // 2 = {:decimals, dec}; 3 = decimals + :compact (strip trailing zeros, keep >= 1).
    // For :short: the shortest round-trip DIGITS are unique (Ryu) and JS produces the same ones —
    // only formatting differs. Empirically-derived Erlang rule (validated by differential fuzz):
    // plain iff -3 <= dp <= 15 and dp - len(digits) <= 2, else scientific d.ddd e(dp-1).
    flt_fmt: (f, mode, dec) => {
      if (mode === 1) {
        const [m, e] = Math.abs(f).toExponential(20).split("e");
        const exp = Number(e);
        const es = (exp < 0 ? "-" : "+") + String(Math.abs(exp)).padStart(2, "0");
        return wrBin((f < 0 || Object.is(f, -0) ? "-" : "") + m + "e" + es);
      }
      if (mode === 2 || mode === 3) {
        let out = Math.abs(f).toFixed(dec);
        if (mode === 3 && out.includes(".")) out = out.replace(/(\.\d*?)0+$/, "$1").replace(/\.$/, ".0");
        if (mode === 3 && !out.includes(".")) out = out + ".0";
        return wrBin((f < 0 || Object.is(f, -0) ? "-" : "") + out);
      }
      // mode 0: :short
      if (f === 0) return wrBin(Object.is(f, -0) ? "-0.0" : "0.0");
      const neg = f < 0 ? "-" : "";
      const s = String(Math.abs(f));
      let digits, dp;
      if (s.includes("e")) {
        const [m, e] = s.split("e");
        digits = m.replace(".", "");
        dp = Number(e) + (m.indexOf(".") === -1 ? m.length : m.indexOf("."));
      } else {
        const i = s.indexOf(".");
        if (i === -1) { dp = s.length; digits = s; }
        else {
          const ip = s.slice(0, i), fp = s.slice(i + 1);
          if (ip === "0") { const z = (fp.match(/^0*/) || [""])[0].length; digits = fp.slice(z); dp = -z; }
          else { digits = ip + fp; dp = ip.length; }
        }
      }
      digits = digits.replace(/0+$/, "") || "0";
      const len = digits.length;
      let out;
      if (dp >= -3 && dp <= 15 && dp - len <= 2) {
        if (dp <= 0) out = "0." + "0".repeat(-dp) + digits;
        else if (dp >= len) out = digits + "0".repeat(dp - len) + ".0";
        else out = digits.slice(0, dp) + "." + digits.slice(dp);
      } else {
        out = digits[0] + "." + (digits.slice(1) || "0") + "e" + (dp - 1);
      }
      return wrBin(neg + out);
    },
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

// ── The effects ABI: IO (file, console) handed back to the HOST ──────────────────────────────
// The host decides the backing: real fs on Node, a VIRTUAL filesystem (in-memory Map, or KV/R2/DO
// on Workers). An unwired effect traps honestly. Frames: fs_read -> <<1, bytes...>> (ok) or
// <<0, errcode>> (1=enoent, 2=eacces, 3=eio); fs_write -> errcode i32 (0 = ok).

// In-memory virtual filesystem backing: `files` is a Map<string, Uint8Array|string>.
export const memFsBacking = (files = new Map()) => ({
  read: (path) => {
    if (!files.has(path)) return { err: 1 };
    const v = files.get(path);
    return typeof v === "string" ? encU.encode(v) : v;
  },
  write: (path, bytes) => { files.set(path, bytes); return 0; },
  files,
});

// Real-filesystem backing (Node host). `nodeFs` = require("node:fs") injected by the runner.
export const nodeFsBacking = (nodeFs) => ({
  read: (path) => {
    try { return new Uint8Array(nodeFs.readFileSync(path)); }
    catch (e) { return { err: e.code === "ENOENT" ? 1 : e.code === "EACCES" ? 2 : 3 }; }
  },
  write: (path, bytes) => {
    try { nodeFs.writeFileSync(path, bytes); return 0; }
    catch (e) { return e.code === "EACCES" ? 2 : 3; }
  },
});

export const makeFs = (getExports, backing) => {
  const { rawBytes, wrBytes, rdBin } = binCodec(getExports);
  return {
    read_file: (pathB) => {
      const r = backing.read(rdBin(pathB));
      if (r.err) return wrBytes(new Uint8Array([0, r.err]));
      const buf = new Uint8Array(1 + r.length);
      buf[0] = 1; buf.set(r, 1);
      return wrBytes(buf);
    },
    write_file: (pathB, dataB) => backing.write(rdBin(pathB), rawBytes(dataB)),
  };
};

// Console IO. `sink` collects lines (for differential capture); default = real console.
export const makeIo = (getExports, sink = null) => {
  const { rdBin } = binCodec(getExports);
  const emit = (s, warn) => { if (sink) sink.push(s); else (warn ? console.error : console.log)(s); };
  return {
    puts: (b) => { emit(rdBin(b), false); return 0; },
    warn: (b) => { emit(rdBin(b), true); return 0; },
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
