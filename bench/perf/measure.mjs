// perf/measure.mjs — reproducible timing + attribution for a compiled Elixir->WasmGC module.
//
//   node measure.mjs <module.wasm> <cases.json> [--iters N] [--trials K] [--profile] [--json]
//
// Outputs (human table by default, --json for machine-readable):
//   * timing: median & min us/op over K trials of N iters (warmed up) — the reproducible number.
//   * --profile: self-time per Wasm function (demangled + categorized) from an in-process V8
//     sampling profile, AND host-boundary call counts. Every big.* call is an op that fell to the
//     bignum tier; from_i64 is an i31 operand lifted into a host BigInt. This is the zero-guessing
//     attribution: it says exactly which functions and which tier crossings cost the time.
import { Session } from "node:inspector";
import fs from "node:fs";
import { makeStr, makeProcStubs, makeFs, makeIo, memFsBacking } from "../../runtime/imports.mjs";

const args = process.argv.slice(2);
const wasmPath = args[0], casesPath = args[1];
const opt = (flag, def) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : def; };
const has = (flag) => args.includes(flag);
const ITERS = Number(opt("--iters", "2000"));
const TRIALS = Number(opt("--trials", "12"));
const PROFILE = has("--profile");
const JSON_OUT = has("--json");

const encU = new TextEncoder(), decU = new TextDecoder();

// ---- host imports, with optional call counting ----
const counts = {};
const wrap = (obj, on) => on
  ? Object.fromEntries(Object.entries(obj).map(([k, f]) =>
      [k, (...a) => { counts[k] = (counts[k] || 0) + 1; return f(...a); }]))
  : obj;
const bigRaw = {
  from_i64: x => x, from_float: (x) => BigInt(Math.trunc(x)), from_str: x => BigInt(String(x)),
  add: (a, b) => a + b, sub: (a, b) => a - b, mul: (a, b) => a * b, div: (a, b) => a / b, rem: (a, b) => a % b,
  band: (a, b) => a & b, bor: (a, b) => a | b, bxor: (a, b) => a ^ b,
  bsl: (a, b) => b >= 0n ? a << b : a >> -b, bsr: (a, b) => b >= 0n ? a >> b : a << -b,
  fits_i31: a => (a >= -1073741824n && a < 1073741824n) ? 1 : 0, to_i32: a => Number(a),
  fits_i64: a => (a >= -9223372036854775808n && a <= 9223372036854775807n) ? 1 : 0, to_i64: a => BigInt.asIntN(64, a),
  cmp: (a, b) => a < b ? -1 : a > b ? 1 : 0, to_u64: (a) => BigInt.asIntN(64, a), from_u64: (v) => BigInt.asUintN(64, v), bit_length: a => a === 0n ? 0 : a.toString(2).length,
};
const mathRaw = Object.fromEntries(
  ["sin","cos","tan","asin","acos","atan","sqrt","exp","log","log2","log10",
   "sinh","cosh","tanh","ceil","floor","atan2","pow"].map(k => [k, Math[k]]));

let e;
const rdBin = b => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return decU.decode(u); };
const wrBin = s => { const u = encU.encode(s); const b = e.bin_alloc(u.length); u.forEach((c, i) => e.bin_put(b, i, c)); return b; };
const strRaw = makeStr(() => e);

function instantiate(count) {
  // every import module must be default-provided: feeding stdlib beams flips modes on
  // (Kernel -> proc, IO.warn -> io), and a missing module fails instantiation entirely.
  const { proc, sched } = makeProcStubs();
  const imports = { big: wrap(bigRaw, count), math: wrap(mathRaw, count), str: wrap(strRaw, count),
                    proc, sched, fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e) };
  const inst = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), imports);
  e = inst.exports;
}

instantiate(false);
const cases = JSON.parse(fs.readFileSync(casesPath, "utf8"));
const toL = a => a.reduceRight((l, x) => e.cons(x, l), e.nil());
const encArg = a => a.type === "int" ? a.val : a.type === "bin" ? wrBin(a.val) : a.type === "list" ? toL(a.val) : (() => { throw new Error("bad arg " + a.type); })();
const prepared = cases.map(c => [c.name, c.args.map(encArg)]);
const callsPerPass = prepared.length;

function runPass() { let s = 0n; for (const [n, a] of prepared) s += BigInt(String(e[n](...a))); return s; }

// ---- timing: K trials of N iters, warmed up ----
let sink = 0n;
for (let i = 0; i < Math.min(300, ITERS); i++) sink += runPass();           // warmup (tier-up)
const trials = [];
for (let t = 0; t < TRIALS; t++) {
  const t0 = performance.now();
  for (let i = 0; i < ITERS; i++) sink += runPass();
  const ms = performance.now() - t0;
  trials.push((ms * 1000) / (ITERS * callsPerPass));                          // us per call
}
trials.sort((a, b) => a - b);
const median = trials[Math.floor(trials.length / 2)];
const min = trials[0];
const mad = trials.map(x => Math.abs(x - median)).sort((a, b) => a - b)[Math.floor(trials.length / 2)];

const result = { wasmPath, cases: callsPerPass, iters: ITERS, trials: TRIALS,
  us_per_call_median: round(median), us_per_call_min: round(min), us_per_call_mad: round(mad) };

// ---- attribution (optional) ----
if (PROFILE) {
  // host-boundary call counts: a dedicated counted pass over a known number of calls
  instantiate(true);
  const cPrep = cases.map(c => [c.name, c.args.map(encArg)]);
  const COUNT_ITERS = Math.min(ITERS, 2000);
  for (const k in counts) delete counts[k];
  let cs = 0n;
  for (let i = 0; i < COUNT_ITERS; i++) for (const [n, a] of cPrep) cs += BigInt(String(e[n](...a)));
  const perCall = COUNT_ITERS * cPrep.length;
  result.host_calls_per_op = Object.fromEntries(
    Object.entries(counts).sort((a, b) => b[1] - a[1]).map(([k, v]) => [k, round(v / perCall)]));
  result.host_total_per_op = round(Object.values(counts).reduce((a, b) => a + b, 0) / perCall);

  // self-time profile (uncounted instance for clean attribution)
  instantiate(false);
  const cProf = cases.map(c => [c.name, c.args.map(encArg)]);
  const s = new Session(); s.connect();
  const post = (m, p) => new Promise((res, rej) => s.post(m, p || {}, (er, r) => er ? rej(er) : res(r)));
  await post("Profiler.enable");
  await post("Profiler.setSamplingInterval", { interval: 40 });
  await post("Profiler.start");
  const tEnd = performance.now() + 1500;                                      // ~1.5s of samples
  let pc = 0;
  while (performance.now() < tEnd) { for (const [n, a] of cProf) sink += BigInt(String(e[n](...a))); pc++; }
  const { profile } = await post("Profiler.stop");
  result.profile = attribute(profile);
}

result.sink = String(sink).slice(-6);

if (JSON_OUT) { process.stdout.write(JSON.stringify(result)); }
else { printHuman(result); }

// ---- helpers ----
function round(x) { return Number(x.toPrecision(4)); }

function attribute(profile) {
  const id2name = new Map(profile.nodes.map(n => [n.id, n.callFrame.functionName || "(anon)"]));
  const self = new Map();
  const { samples, timeDeltas } = profile;
  for (let i = 0; i < samples.length; i++) {
    const name = id2name.get(samples[i]);
    self.set(name, (self.get(name) || 0) + (timeDeltas[i] || 0));
  }
  const total = [...self.values()].reduce((a, b) => a + b, 0) || 1;
  const rows = [...self.entries()]
    .map(([name, us]) => ({ name: demangle(name), raw: name, cat: categorize(name), pct: (100 * us / total) }))
    .filter(r => !["(program)", "(root)", "(idle)"].includes(r.raw))
    .sort((a, b) => b.pct - a.pct);
  // merge duplicate demangled names
  const merged = new Map();
  for (const r of rows) {
    const k = r.name + "|" + r.cat;
    merged.set(k, (merged.get(k) || 0) + r.pct);
  }
  return [...merged.entries()].map(([k, pct]) => { const [name, cat] = k.split("|"); return { name, cat, self_pct: round(pct) }; })
    .sort((a, b) => b.self_pct - a.self_pct).slice(0, 25);
}

function categorize(n) {
  if (/^Elixir_46_(Enum|Map|Keyword|String|List)\b|^lists\.|^maps\./.test(n)) return "stdlib";
  if (/^Elixir_46_/.test(n)) return "user";
  if (/^(int_|num_|term_|map_|cons|nil|head|tail|bits|list_|to_big|from_big|narrow|atom|bin_|is_|ref_|float)/.test(n)) return "runtime";
  if (/^(add|sub|mul|div|rem|band|bor|bxor|bsl|bsr|cmp|fits_i31|to_i32|from_i64|from_str|bit_length|sin|cos|sqrt|pow|upcase|downcase)$/.test(n)) return "host";
  if (/wasm-to-js|js-to-wasm/.test(n)) return "boundary";
  return "vm/js";
}

function demangle(n) {
  if (!/^Elixir_46_|^lists\.|^maps\./.test(n) && !/_46_|_47_|_45_/.test(n)) return n;
  let s = n.replace(/_46_/g, ".").replace(/_47_/g, "/").replace(/_45_/g, "-").replace(/_94_/g, "^").replace(/_64_/g, "@");
  s = s.replace(/^Elixir\./, "");
  s = s.replace(/_(\d+)$/, "/$1");   // trailing arity
  return s;
}

function printHuman(r) {
  const beam = r._beam_us;   // optionally injected by the orchestrator
  console.log(`\n  ${r.wasmPath}`);
  console.log(`  timing: ${r.us_per_call_median} us/op (median)  ${r.us_per_call_min} (min)  ±${r.us_per_call_mad} mad` +
    `   [${r.iters}×${r.trials}, ${r.cases} cases]`);
  if (r.host_total_per_op !== undefined) {
    console.log(`\n  host-boundary calls per op: ${r.host_total_per_op} total`);
    const top = Object.entries(r.host_calls_per_op).slice(0, 8);
    for (const [k, v] of top) console.log(`     ${String(v).padStart(8)}  big/${k}`);
  }
  if (r.profile) {
    console.log(`\n  self-time attribution (top):`);
    console.log(`     self%   category   function`);
    for (const row of r.profile.slice(0, 18))
      console.log(`     ${String(row.self_pct).padStart(5)}   ${row.cat.padEnd(9)}  ${row.name}`);
  }
  console.log("");
}
