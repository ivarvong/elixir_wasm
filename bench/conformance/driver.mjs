// Generic conformance driver: load a compiled-Elixir WasmGC module, run each case,
// decode the result to a normalized JSON form. Reads cases from argv[3] (a JSON file).
//   node driver.mjs <wasm> <wat> <cases.json>  ->  prints [{ok, val}] JSON to stdout
// Arg/result types bridged: int | bool | atom | bin(string) | list (list of ints).
import fs from "node:fs";
import { makeBig, makeMath, makeStr, makeFs, makeIo, makeProcStubs, memFsBacking } from "../../runtime/imports.mjs";

const [wasmPath, watPath, casesPath] = process.argv.slice(2);
const atoms = JSON.parse(fs.readFileSync(watPath, "utf8").match(/@atoms (.*)/)[1]);
// big (exact integers), math (libm), str (case/regex) all come from the shared import library.
const big = makeBig();
const math = makeMath();
const encU = new TextEncoder(), decU = new TextDecoder();
let e;
const str = makeStr(() => e);
const vfs = makeFs(() => e, memFsBacking());
const io = makeIo(() => e);
// benign proc/sched stubs: fed stdlib beams (Kernel/...) can flip proc mode on without running processes
const { proc, sched } = makeProcStubs();
e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { big, math, str, fs: vfs, io, proc, sched }).exports;

const toL = a => a.reduceRight((l, x) => e.cons(x, l), e.nil());
const toJ = l => { const o = []; while (e.is_cons(l)) { o.push(e.head(l)); l = e.tail(l); } return o; };
const toBin = s => { const u = encU.encode(s); const b = e.bin_alloc(u.length); u.forEach((c, i) => e.bin_put(b, i, c)); return b; };
const fromBin = b => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return decU.decode(u); };

const encArg = a => {
  switch (a.type) {
    case "int": return a.val;            // wrapper takes an i32 directly
    case "list": return toL(a.val);
    case "bin": return toBin(a.val);
    default: throw new Error("bad arg type " + a.type);
  }
};
// canonical string form, identical to the Elixir oracle's, for line-by-line diffing
const canon = (type, r) => {
  switch (type) {
    case "int": return String(r);
    case "bool": return atoms[r] === "true" ? "true" : "false";
    case "atom": return ":" + atoms[r];
    case "bin": return "b:" + fromBin(r);
    case "list": return "[" + toJ(r).join(",") + "]";
    case "float": {                       // wrapper returns an unboxed f64; hash its IEEE-754 bits (big-endian hex)
      const dv = new DataView(new ArrayBuffer(8)); dv.setFloat64(0, r);
      let h = ""; for (let i = 0; i < 8; i++) h += dv.getUint8(i).toString(16).padStart(2, "0");
      return "f:" + h.toUpperCase();
    }
    default: throw new Error("bad ret type " + type);
  }
};

const cases = JSON.parse(fs.readFileSync(casesPath, "utf8"));
const out = cases.map(c => {
  try { return canon(c.ret, e[c.name](...c.args.map(encArg))); }
  catch (err) { return "TRAP"; }
});
process.stdout.write(out.join("\n"));
