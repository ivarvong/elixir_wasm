// Web Worker: loads the pyex WasmGC interpreter and runs Python off the main thread, so live-compile
// never janks the UI (even a heavy run just occupies the worker for ~1s, bounded by the step budget).
import {
  makeBig, makeMath, makeStr, makeFs, makeIo, makeCrypto, makeProcStubs, makeSys, memFsBacking, termToJs
} from "./imports.mjs";

let e, ready = false;
const cryptoStub = { createHash: () => { throw new Error("hashlib not wired in this demo"); } };
const { proc, sched } = makeProcStubs();
const enc = new TextEncoder();

(async () => {
  try {
    const t0 = performance.now();
    const bytes = await fetch("./pyex.wasm?v=c112dd6f2f8b").then((r) => r.arrayBuffer());
    e = (await WebAssembly.instantiate(await WebAssembly.compile(bytes), {
      big: makeBig(), math: makeMath(), str: makeStr(() => e),
      crypto: makeCrypto(() => e, cryptoStub), sys: makeSys(),
      fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e, []),
      proc, sched,
    })).exports;
    ready = true;
    postMessage({ type: "ready", sizeMB: bytes.byteLength / 1048576, ms: performance.now() - t0 });
  } catch (err) {
    postMessage({ type: "boot-error", message: String(err) });
  }
})();

onmessage = (ev) => {
  const { id, code, maxSteps } = ev.data;
  if (!ready) return;
  const u = enc.encode(code);
  const b = e.bin_alloc(u.length);
  for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]);

  const t0 = performance.now();
  let res, err = null;
  try { res = termToJs(e, e.pyrun(b, maxSteps)); }
  catch (ex) {
    err = (e.exc && ex instanceof WebAssembly.Exception && ex.is(e.exc))
      ? "uncaught Elixir exception" : String(ex);
  }
  const ms = performance.now() - t0;

  if (err) postMessage({ type: "result", id, ok: false, error: "host error: " + err, ms });
  else if (Array.isArray(res) && res[0] === ":ok")
    postMessage({ type: "result", id, ok: true, stdout: res[1] || "", footprint: res[2] || {}, ms });
  else postMessage({ type: "result", id, ok: false, error: "Traceback (pyex):\n" + (Array.isArray(res) ? res[1] : String(res)), ms });
};
