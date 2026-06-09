// gaps/runner.mjs <wasm> <seed> — run Gap.run(seed); print the integer, or "TRAP@<function>" with the
// trapping Wasm function name (needs a -g build). Makes the gap grind a worklist instead of "TRAP".
import fs from "node:fs";
import { makeBig, makeMath, makeStr } from "../runtime/imports.mjs";
const [wasmPath, seedStr] = process.argv.slice(2);
const big = makeBig();
const math = makeMath();
let e;
const str = makeStr(() => e);
try {
  e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { big, math, str }).exports;
  process.stdout.write(String(e.run(Number(seedStr))));
} catch (err) {
  const m = (err.stack || "").match(/at (\S+) \(wasm/);
  const fn = m ? m[1].replace(/^Elixir_46_/, "").replace(/_46_/g, ".") : "?";
  process.stdout.write("TRAP@" + fn);
}
