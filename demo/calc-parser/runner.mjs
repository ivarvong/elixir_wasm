// demo/calc-parser runner: instantiate the compiled parser, parse(arg) -> "b:<json>" (the driver's
// bin form). nimble_parsec/Jason pull in Kernel/process code, so "proc"/"sched" imports are declared
// and satisfied by the benign stubs (no process runs on the parse path).
//   node runner.mjs <wasm> "<expression>"
import fs from "node:fs";
import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, memFsBacking } from "../../runtime/imports.mjs";
const [wasmPath, expr] = process.argv.slice(2);
const big = makeBig(), math = makeMath();
let e;
const str = makeStr(() => e);
const { proc, sched } = makeProcStubs();
try {
  e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { big, math, str, proc, sched, fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e) }).exports;
  const inb = new TextEncoder().encode(expr);
  const ib = e.bin_alloc(inb.length);
  inb.forEach((c, i) => e.bin_put(ib, i, c));
  const r = e.parse(ib);
  const n = e.bin_len(r);
  const u = new Uint8Array(n);
  for (let i = 0; i < n; i++) u[i] = e.bin_get(r, i);
  process.stdout.write("b:" + new TextDecoder().decode(u));
} catch (err) {
  const fn = ((err.stack || "").match(/at (\S+) \(wasm/) || [])[1] || "?";
  process.stdout.write("TRAP@" + fn.replace(/^Elixir_46_/, "").replace(/_46_/g, "."));
}
