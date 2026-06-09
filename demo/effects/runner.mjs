// effects runner: virtual in-memory fs + captured console; prints JSON {result, output_hex, stdout}.
//   node runner.mjs <wasm> <seed> <input-fixture-path>
import fs from "node:fs";
import { makeBig, makeMath, makeStr, makeFs, makeIo, makeProcStubs, memFsBacking } from "../../runtime/imports.mjs";
const [wasmPath, seed, fixturePath] = process.argv.slice(2);
const big = makeBig(), math = makeMath();
let e;
const str = makeStr(() => e);
const backing = memFsBacking(new Map([["data/input.txt", new Uint8Array(fs.readFileSync(fixturePath))]]));
const vfs = makeFs(() => e, backing);
const sink = [];
const io = makeIo(() => e, sink);
const { proc, sched } = makeProcStubs();
e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { big, math, str, fs: vfs, io, proc, sched }).exports;
try {
  const r = e.run(Number(seed));
  const out = backing.files.get("data/output.txt");
  process.stdout.write(JSON.stringify({
    result: String(r),
    output_hex: out ? Buffer.from(out).toString("hex") : null,
    stdout: sink,
  }));
} catch (err) {
  const fn = ((err.stack || "").match(/at (\S+) \(wasm/) || [])[1] || "?";
  process.stdout.write(JSON.stringify({ trap: fn.replace(/^Elixir_46_/, "").replace(/_46_/g, ".") + ": " + err.message }));
}
