// Web Worker: loads the pyex WasmGC interpreter and runs Python off the main thread.
// @ts-ignore — imports.mjs is untyped host glue.
import {
  makeBig, makeMath, makeStr, makeFs, makeIo, makeCrypto, makeProcStubs, makeSys, memFsBacking, termToJs,
  // @ts-ignore
} from "./imports.mjs";

type RunMsg = { id: number; code: string; filesJson: string; maxSteps: number };

let e: any, ready = false;
const cryptoStub = { createHash: () => { throw new Error("hashlib not wired in this demo"); } };
const { proc, sched } = makeProcStubs();
const enc = new TextEncoder();

const WASM_URL = "/pyex.wasm?v=" + ((import.meta as any).env?.VITE_WASM_V || "dev");

(async () => {
  try {
    const t0 = performance.now();
    const bytes = await fetch(WASM_URL).then((r) => r.arrayBuffer());
    e = (await WebAssembly.instantiate(await WebAssembly.compile(bytes), {
      big: makeBig(), math: makeMath(), str: makeStr(() => e),
      crypto: makeCrypto(() => e, cryptoStub), sys: makeSys(),
      fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e, [] as any),
      proc, sched,
    })).exports;
    ready = true;
    postMessage({ type: "ready", sizeMB: bytes.byteLength / 1048576, ms: performance.now() - t0 });
  } catch (err) {
    postMessage({ type: "boot-error", message: String(err) });
  }
})();

const bin = (s: string) => {
  const u = enc.encode(s), b = e.bin_alloc(u.length);
  for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]);
  return b;
};

onmessage = (ev: MessageEvent<RunMsg>) => {
  const { id, code, filesJson, maxSteps } = ev.data;
  if (!ready) return;
  const t0 = performance.now();
  let res: any, err: string | null = null;
  try { res = termToJs(e, e.pyrun(bin(code), bin(filesJson), maxSteps)); }
  catch (ex: any) {
    err = (e.exc && ex instanceof (WebAssembly as any).Exception && ex.is(e.exc)) ? "uncaught Elixir exception" : String(ex);
  }
  const ms = performance.now() - t0;

  if (err) {
    // A wasm trap (e.g. a Python corner the interpreter doesn't lower yet) can't be caught as an
    // Elixir error — surface it honestly instead of leaking a raw RuntimeError stack.
    const friendly = /unreachable|Elixir exception/.test(err)
      ? "This program hit a corner of Python the sandbox doesn't support yet."
      : "host error: " + err;
    postMessage({ type: "result", id, ok: false, error: friendly, ms });
    return;
  }
  if (Array.isArray(res) && res[0] === ":ok") {
    postMessage({
      type: "result", id, ok: true, ms,
      stdout: res[1] || "",
      footprint: res[2] || {},
      files: safeParse(res[3], {}),
      spans: safeParse(res[4], []),
    });
  } else {
    postMessage({ type: "result", id, ok: false, ms, error: "Traceback (pyex):\n" + (Array.isArray(res) ? res[1] : String(res)) });
  }
};

function safeParse(s: any, fallback: any) { try { return JSON.parse(s); } catch { return fallback; } }
