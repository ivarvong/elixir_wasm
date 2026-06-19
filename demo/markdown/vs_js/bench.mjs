// vs_js/bench.mjs — head-to-head: the REAL Earmark engine compiled to WasmGC vs the markdown
// renderers a JS developer would actually deploy on an edge runtime (marked, markdown-it),
// all rendering the IDENTICAL input document.
//
//   node bench.mjs <blog.wasm> <doc.md> <expected.html>
//
// Reports: (1) correctness — Wasm output byte-identical vs the real Elixir VM (expected.html);
// (2) warm throughput per renderer; (3) cold start — fresh compile+instantiate+first-render,
// median over K runs; (4) steady-state RSS. Honest-scope note: Earmark/marked/markdown-it
// produce *different HTML* (different dialect choices) — the comparison is work-rate on the
// same input, not output equivalence. Output equivalence is only asserted Wasm-vs-VM.
import fs from "node:fs";
import { createRequire } from "node:module";
import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, memFsBacking } from "../../../runtime/imports.mjs";
import { marked } from "marked";
import MarkdownIt from "markdown-it";

const require = createRequire(import.meta.url);
const ver = (p) => require(`${p}/package.json`).version;

const [wasmPath, docPath, expectedPath] = process.argv.slice(2);
const docStr = fs.readFileSync(docPath, "utf8");
const expected = fs.readFileSync(expectedPath, "utf8");
const bytes = fs.readFileSync(wasmPath);

function fresh() {
  const big = makeBig(), math = makeMath();
  let e;
  const str = makeStr(() => e);
  const { proc, sched } = makeProcStubs();
  const t0 = performance.now();
  const mod = new WebAssembly.Module(bytes);
  const t1 = performance.now();
  e = new WebAssembly.Instance(mod, { big, math, str, proc, sched, fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e) }).exports;
  const t2 = performance.now();
  return { e, compile: t1 - t0, instantiate: t2 - t1 };
}

const enc = new TextEncoder(), dec = new TextDecoder();
const wrBin = (e, s) => { const u = enc.encode(s); const b = e.bin_alloc(u.length); for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]); return b; };
const rdBin = (e, b) => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return dec.decode(u); };

// ---- correctness gate: Wasm must be byte-identical to the VM before any timing is reported
const { e } = fresh();
const wasmHtml = rdBin(e, e.render_md(wrBin(e, docStr)));
if (wasmHtml !== expected) {
  let i = 0; while (i < Math.min(wasmHtml.length, expected.length) && wasmHtml[i] === expected[i]) i++;
  console.log(`  ❌ Wasm output DIFFERS from the VM at byte ${i}:`);
  console.log(`     vm:   ${JSON.stringify(expected.slice(Math.max(0, i - 20), i + 40))}`);
  console.log(`     wasm: ${JSON.stringify(wasmHtml.slice(Math.max(0, i - 20), i + 40))}`);
  process.exit(1);
}
console.log(`  ✅ Wasm output BYTE-IDENTICAL to the real Elixir VM (${Buffer.byteLength(expected)} bytes of HTML from ${Buffer.byteLength(docStr)} bytes of markdown)`);

// ---- warm throughput, identical input ----
const md = new MarkdownIt();
function bench(f, N) {
  for (let i = 0; i < 100; i++) f();                          // warm (tier-up)
  const trials = [];
  for (let t = 0; t < 7; t++) {
    const t0 = performance.now();
    for (let i = 0; i < N; i++) f();
    trials.push((performance.now() - t0) * 1000 / N);          // us/render
  }
  trials.sort((a, b) => a - b);
  return trials[Math.floor(trials.length / 2)];                // median of trials
}
const N = 200;
const rows = [
  [`Earmark ${process.env.EARMARK_VSN || ""} (real, WasmGC)`.replace(/\s+/g, " "), bench(() => rdBin(e, e.render_md(wrBin(e, docStr))), N), Buffer.byteLength(wasmHtml)],
  [`marked ${ver("marked")} (JS)`, bench(() => marked(docStr), N), Buffer.byteLength(marked(docStr))],
  [`markdown-it ${ver("markdown-it")} (JS)`, bench(() => md.render(docStr), N), Buffer.byteLength(md.render(docStr))],
];
const vmUs = Number(process.env.EARMARK_VM_US || 0);
if (vmUs > 0) rows.splice(1, 0, [`Earmark (native BEAM, same machine)`, vmUs, Buffer.byteLength(expected)]);
const wasmUs = rows[0][1];
console.log(`\n  warm throughput (${Buffer.byteLength(docStr)}-byte document, median of 7×${N}):`);
for (const [label, us, outBytes] of rows)
  console.log(`     ${label.padEnd(36)} ${us.toFixed(1).padStart(8)} µs/render  ${Math.round(1e6 / us).toLocaleString().padStart(8)}/sec   (${outBytes} B out)  ${(wasmUs / us).toFixed(1)}x`);

// ---- cold start: fresh module compile + instantiate + first render, median over K ----
const K = 15;
const cold = { compile: [], inst: [], first: [], total: [] };
for (let i = 0; i < K; i++) {
  const t0 = performance.now();
  const { e: e2, compile, instantiate } = fresh();
  const tf = performance.now();
  rdBin(e2, e2.render_md(wrBin(e2, docStr)));
  const first = performance.now() - tf;
  cold.compile.push(compile); cold.inst.push(instantiate); cold.first.push(first);
  cold.total.push(performance.now() - t0);
}
const med = (a) => a.sort((x, y) => x - y)[Math.floor(a.length / 2)];
console.log(`\n  cold start (${(bytes.length / 1024 / 1024).toFixed(1)} MB module, median of ${K}):`);
console.log(`     compile=${med(cold.compile).toFixed(1)}ms  instantiate=${med(cold.inst).toFixed(2)}ms  first_render=${med(cold.first).toFixed(2)}ms  total=${med(cold.total).toFixed(1)}ms`);

// ---- steady-state memory ----
global.gc?.();
const rss = process.memoryUsage();
console.log(`\n  steady-state memory: rss=${(rss.rss / 1024 / 1024).toFixed(0)} MB  heapUsed=${(rss.heapUsed / 1024 / 1024).toFixed(1)} MB (includes Node itself + both JS renderers)`);
