// perf/alloc.mjs — measure WasmGC allocation rate (bytes/op) for a compiled Elixir->WasmGC module.
//
// WasmGC objects live on V8's managed heap but are NOT visible to the JS HeapProfiler sampler, so we
// measure allocation the way it actually shows up: as GC churn. The parent spawns a `--trace-gc`
// child that runs the workload between two markers; the parent sums new-space allocation (each
// Scavenge frees what was allocated since the previous one) over the marked window and divides by ops.
//
//   node alloc.mjs <module.wasm> <cases.json> [--ops N] [--json]
//
// This is a TOTAL bytes/op number (it can't attribute per-function — the JS profiler can't see WasmGC
// allocs). For per-type attribution use the compiler's ALLOCPROF counters (next).
import fs from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { makeStr, makeProcStubs, makeFs, makeIo, memFsBacking } from "../../runtime/imports.mjs";

const args = process.argv.slice(2);

// ---------- child mode: run the workload, bracket it with GC markers ----------
if (args[0] === "--child") {
  const [, wasmPath, casesPath, opsStr] = args;
  const OPS_PASSES = Number(opsStr);
  const encU = new TextEncoder(), decU = new TextDecoder();
  const big = {
    from_i64: x => x, from_float: (x) => BigInt(Math.trunc(x)), from_str: x => BigInt(String(x)),
    add: (a, b) => a + b, sub: (a, b) => a - b, mul: (a, b) => a * b, div: (a, b) => a / b, rem: (a, b) => a % b,
    band: (a, b) => a & b, bor: (a, b) => a | b, bxor: (a, b) => a ^ b,
    bsl: (a, b) => b >= 0n ? a << b : a >> -b, bsr: (a, b) => b >= 0n ? a >> b : a << -b,
    fits_i31: a => (a >= -1073741824n && a < 1073741824n) ? 1 : 0, to_i32: a => Number(a),
    fits_i64: a => (a >= -9223372036854775808n && a <= 9223372036854775807n) ? 1 : 0, to_i64: a => BigInt.asIntN(64, a),
    cmp: (a, b) => a < b ? -1 : a > b ? 1 : 0, to_u64: (a) => BigInt.asIntN(64, a), from_u64: (v) => BigInt.asUintN(64, v), bit_length: a => a === 0n ? 0 : a.toString(2).length,
  };
  const math = Object.fromEntries(["sin","cos","tan","asin","acos","atan","sqrt","exp","log","log2",
    "log10","sinh","cosh","tanh","ceil","floor","atan2","pow"].map(k => [k, Math[k]]));
  let e;
  const wrBin = s => { const u = encU.encode(s); const b = e.bin_alloc(u.length); u.forEach((c, i) => e.bin_put(b, i, c)); return b; };
  const rdBin = b => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return decU.decode(u); };
  // every import module must be default-provided (stdlib beams flip proc/io modes on)
  const str = makeStr(() => e);
  const { proc, sched } = makeProcStubs();
  e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)),
    { big, math, str, proc, sched, fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e) }).exports;
  const cases = JSON.parse(fs.readFileSync(casesPath, "utf8"));
  const toL = a => a.reduceRight((l, x) => e.cons(x, l), e.nil());
  const encArg = a => a.type === "int" ? a.val : a.type === "bin" ? wrBin(a.val) : a.type === "list" ? toL(a.val) : (() => { throw 0; })();
  const prepared = cases.map(c => [c.name, c.args.map(encArg)]);
  let sink = 0n;
  const runPass = () => { for (const [n, a] of prepared) sink += BigInt(String(e[n](...a))); };
  for (let i = 0; i < 300; i++) runPass();                 // warmup
  process.stdout.write("=ALLOC_START=\n");                 // markers on stdout (interleave w/ --trace-gc)
  for (let i = 0; i < OPS_PASSES; i++) runPass();
  process.stdout.write("=ALLOC_END=\n");
  process.stdout.write("=OPS=" + (OPS_PASSES * prepared.length) + "\n");
  process.exit(0);
}

// ---------- parent mode: spawn the --trace-gc child, parse the window ----------
const wasmPath = args[0], casesPath = args[1];
const opt = (f, d) => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : d; };
const JSON_OUT = args.includes("--json");
const PASSES = opt("--ops", "6000");
const self = fileURLToPath(import.meta.url);
const node = process.execPath;

const r = spawnSync(node, ["--trace-gc", self, "--child", wasmPath, casesPath, PASSES], { encoding: "utf8", maxBuffer: 1 << 28 });
const gc = r.stdout;
const ops = Number((gc.match(/=OPS=(\d+)/) || [])[1] || 0);

// only the GC lines between the markers
const win = gc.slice(gc.indexOf("=ALLOC_START="), gc.indexOf("=ALLOC_END="));
// each GC line: "... Scavenge 20.3 (37.5) -> 4.3 (37.5) MB ..."  — allocation since the previous GC
// is (before_k - after_{k-1}). Sum over the window.
const re = /(?:Scavenge|Mark-Compact|Mark-compact)\s+([\d.]+)\s*\([\d.]+\)\s*->\s*([\d.]+)\s*\([\d.]+\)\s*MB/g;
let m, prevAfter = null, totalMB = 0, gcs = 0;
while ((m = re.exec(win))) {
  const before = parseFloat(m[1]), after = parseFloat(m[2]);
  if (prevAfter !== null) totalMB += Math.max(0, before - prevAfter);
  prevAfter = after; gcs++;
}
const bytesPerOp = ops > 0 ? (totalMB * 1024 * 1024) / ops : 0;
const result = { wasmPath, ops, gcs, total_mb: Number(totalMB.toFixed(1)), bytes_per_op: Number(bytesPerOp.toFixed(1)) };

if (JSON_OUT) process.stdout.write(JSON.stringify(result));
else {
  console.log(`\n  ${result.wasmPath}`);
  console.log(`  allocated: ${result.bytes_per_op} bytes/op   (${result.total_mb} MB over ${result.ops} ops, ${result.gcs} scavenges)\n`);
}
