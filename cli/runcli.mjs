// runcli.mjs <wasm> <wat> <entry> [intArg...] — instantiate a compiled-Elixir WasmGC
// module, call <entry> with the given integer args, and print its return value as JSON
// (walked out of the WasmGC heap by termToJs). Host effects (IO/File/:math/:crypto/bignum)
// are wired from the shared runtime imports, so IO.puts etc. reach the real stdout.
import fs from "node:fs";
import path from "node:path";
import nodeCrypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { makeBig, makeMath, makeStr, makeFs, makeIo, makeCrypto, makeProcStubs, memFsBacking, termToJs }
  from "../runtime/imports.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const [wasmPath, watPath, entry, ...rawArgs] = process.argv.slice(2);

const big = makeBig();
const math = makeMath();
let e;                                   // exports (needed by the str/fs/io factories)
const str = makeStr(() => e);
const { proc, sched } = makeProcStubs();  // Map-backed process dict (Decimal.Context) + no-op scheduler
const imports = {
  big, math, str, proc, sched,
  crypto: makeCrypto(() => e, nodeCrypto), // :crypto.hash/2 etc. -> node:crypto
  fs: makeFs(() => e, memFsBacking()),   // in-memory VFS; swap for real fs if desired
  io: makeIo(() => e),                   // IO.puts/write -> host stdout
};

const bytes = fs.readFileSync(path.resolve(wasmPath));
e = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports).exports;

// marshal a JS arg into the value the export expects. Integers cross as f64 (exact to 2^53);
// anything else is built into a WasmGC $binary (UTF-8) via the bin_alloc/bin_put bridge, so an
// arg typed `bin`/`term` receives a real Elixir binary. Prefix "@" forces a string ("@42").
const enc = new TextEncoder();
const toBin = (s) => { const u = enc.encode(s); const b = e.bin_alloc(u.length);
  for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]); return b; };
const marshal = (raw) => {
  if (/^-?[0-9]+$/.test(raw)) return Number(raw);
  return toBin(raw.startsWith("@") ? raw.slice(1) : raw);
};
const args = rawArgs.map(marshal);

const fn = e[entry];
if (typeof fn !== "function") {
  console.error(`no exported entry "${entry}". exports: ${Object.keys(e).filter(k => typeof e[k] === "function").join(", ")}`);
  process.exit(2);
}

let ret;
try {
  ret = fn(...args);
} catch (err) {
  // decode a thrown Elixir exception ($exc tag, exported as "exc"; 3 term args) into readable form
  if (e.exc && err instanceof WebAssembly.Exception && err.is(e.exc)) {
    const parts = [0, 1, 2].map((i) => { try { return termToJs(e, err.getArg(e.exc, i)); } catch { return "?"; } });
    console.error("Elixir exception: " + JSON.stringify(parts));
  } else {
    console.error(err.stack || String(err));
  }
  process.exit(1);
}
// int-returning entries in BIGNUM mode hand back a JS BigInt (externref); term entries
// hand back a WasmGC ref that termToJs walks into a plain JS value.
const out = typeof ret === "bigint" ? ret.toString()
          : typeof ret === "number" ? ret
          : termToJs(e, ret);
process.stdout.write(JSON.stringify(out) + "\n");
