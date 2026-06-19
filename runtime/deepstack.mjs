// deepstack.mjs — run a compiled module's export on a LARGE stack (Node hosts).
//
// Body-recursive Elixir (deep non-tail recursion, e.g. `1 + f(n-1)`) grows the Wasm stack one
// frame per element. On V8's default ~1MB stack that overflows around 10^4 frames — the VM
// handles millions. JSPI stacks don't help (same limit, measured). What does: a worker thread
// with `resourceLimits.stackSizeMb` — measured on this repo's deeprec probe:
//
//   default stack:            f(10_000)    -> RangeError (overflow)
//   worker stackSizeMb: 256:  f(5_000_000) -> ok
//
// Usage:
//   import { runDeep } from "./deepstack.mjs";
//   const result = await runDeep("/path/mod.wasm", "f", [5_000_000], { stackSizeMb: 256 });
//
// The worker instantiates the module with the standard shared imports (imports.mjs) and calls
// the export once. String(result) crosses the thread boundary (covers ints incl. BigInt). This
// is the documented Node-side mitigation; workerd's stack is platform-fixed (LIMITATIONS §1.4),
// where the forward fix is compiler-level trampolining of body recursion.
import { Worker } from "node:worker_threads";
import { fileURLToPath } from "node:url";

const importsUrl = new URL("./imports.mjs", import.meta.url).href;

export function runDeep(wasmPath, exportName, args = [], { stackSizeMb = 256 } = {}) {
  const code = `
    const { parentPort, workerData } = require("node:worker_threads");
    import(${JSON.stringify(importsUrl)}).then(async (im) => {
      const fs = await import("node:fs");
      const big = im.makeBig(), math = im.makeMath();
      let e; const str = im.makeStr(() => e);
      const { proc, sched } = im.makeProcStubs();
      e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(workerData.wasmPath)),
        { big, math, str, proc, sched, fs: im.makeFs(() => e, im.memFsBacking()), io: im.makeIo(() => e) }).exports;
      try {
        parentPort.postMessage({ ok: true, value: String(e[workerData.exportName](...workerData.args)) });
      } catch (err) {
        parentPort.postMessage({ ok: false, error: String(err.message) });
      }
    });`;
  return new Promise((resolve, reject) => {
    const w = new Worker(code, {
      eval: true,
      workerData: { wasmPath, exportName, args },
      resourceLimits: { stackSizeMb },
    });
    w.on("message", (m) => (m.ok ? resolve(m.value) : reject(new Error(m.error))));
    w.on("error", reject);
  });
}
