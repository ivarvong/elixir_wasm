// demo/markdown runner: instantiate the compiled pipeline and print "b:<html>" (the driver's bin form).
// Earmark pulls in Kernel/process code, so the module declares "proc"/"sched" imports — satisfied by the
// shared benign stubs (no process actually runs on the render path).
//   node runner.mjs <wasm> <seed>
import fs from "node:fs";
import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, memFsBacking } from "../../runtime/imports.mjs";
const [wasmPath, seed] = process.argv.slice(2);
const big = makeBig(), math = makeMath();
let e;
const str = makeStr(() => e);
const { proc, sched } = makeProcStubs();
try {
  e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { big, math, str, proc, sched, fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e) }).exports;
  const r = e.render(Number(seed));
  const n = e.bin_len(r);
  const u = new Uint8Array(n);
  for (let i = 0; i < n; i++) u[i] = e.bin_get(r, i);
  process.stdout.write("b:" + new TextDecoder().decode(u));
} catch (err) {
  const fn = ((err.stack || "").match(/at (\S+) \(wasm/) || [])[1] || "?";
  process.stdout.write("TRAP@" + fn.replace(/^Elixir_46_/, "").replace(/_46_/g, "."));
}
