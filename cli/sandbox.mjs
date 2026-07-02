// sandbox.mjs — a persistent, sandboxed Python runtime for AGENT LOOPS.
//
// Compile the WasmGC interpreter ONCE, then run many LLM-generated snippets at ~sub-ms each. Every
// run() is ISOLATED (fresh Python globals) and SANDBOXED (no host filesystem/network unless you wire
// it) and BOUNDED (a deterministic step limit — a runaway `while True` fails instead of hanging).
//
//   import { PyexSandbox } from "./sandbox.mjs";
//   const box = new PyexSandbox();                 // ~30 ms one-time warmup
//   const { ok, stdout, error } = box.run("print(sum(range(10)))");
//   // ok === true, stdout === "45\n"
//
// Options: new PyexSandbox({ wasmPath, maxSteps }). maxSteps caps execution (default 5_000_000,
// ~a few hundred ms worst case; set 0 for pyex's default 10M). Pass 0 to disable the cap.
import fs from "node:fs";
import path from "node:path";
import nodeCrypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { makeBig, makeMath, makeStr, makeFs, makeIo, makeCrypto, makeProcStubs, makeSys, memFsBacking, termToJs }
  from "../runtime/imports.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_WASM = path.join(HERE, "..", "..", "pyex", "wasm", "pyex.wasm");

export class PyexSandbox {
  constructor({ wasmPath = DEFAULT_WASM, maxSteps = 5_000_000 } = {}) {
    if (!fs.existsSync(wasmPath)) {
      throw new Error(`pyex wasm not found at ${wasmPath}. Build it once with: cli/pyex -c "pass"`);
    }
    this.maxSteps = maxSteps;
    this.enc = new TextEncoder();
    const big = makeBig(), math = makeMath();
    let e;
    const str = makeStr(() => e);
    const { proc, sched } = makeProcStubs();
    // No real fs/network is wired: makeFs is an in-memory VFS, http is absent. Guest code that
    // reaches for a real effect gets an honest error, never host access.
    e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), {
      big, math, str, proc, sched,
      crypto: makeCrypto(() => e, nodeCrypto),
      sys: makeSys(),
      fs: makeFs(() => e, memFsBacking()),
      io: makeIo(() => e),
    }).exports;
    this.e = e;
  }

  // run(code[, {maxSteps}]) -> { ok, stdout, error }. Never throws for guest errors; isolated per call.
  run(code, { maxSteps = this.maxSteps } = {}) {
    const e = this.e;
    const u = this.enc.encode(code);
    const b = e.bin_alloc(u.length);
    for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]);
    let out;
    try {
      out = termToJs(e, e.pyrun(b, maxSteps));
    } catch (err) {
      const msg = (e.exc && err instanceof WebAssembly.Exception && err.is(e.exc))
        ? "uncaught: " + JSON.stringify((() => { try { return termToJs(e, err.getArg(e.exc, 1)); } catch { return "?"; } })())
        : String(err.stack || err);
      return { ok: false, stdout: "", error: msg };
    }
    if (Array.isArray(out) && out[0] === ":ok") return { ok: true, stdout: out[1] ?? "", error: null };
    return { ok: false, stdout: "", error: Array.isArray(out) ? out[1] : String(out) };
  }
}

export default PyexSandbox;
