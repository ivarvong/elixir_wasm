// Generic conformance driver: load a compiled-Elixir WasmGC module, run each case,
// decode the result to a normalized JSON form. Reads cases from argv[3] (a JSON file).
//   node driver.mjs <wasm> <wat> <cases.json>  ->  prints [{ok, val}] JSON to stdout
// Arg/result types bridged: int | bool | atom | bin(string) | list (list of ints).
import fs from "node:fs";

const [wasmPath, watPath, casesPath] = process.argv.slice(2);
const atoms = JSON.parse(fs.readFileSync(watPath, "utf8").match(/@atoms (.*)/)[1]);
// Exact arbitrary-precision integers (BIGNUM mode): the $big box wraps a host BigInt.
// Provided unconditionally — a module that doesn't import "big" simply ignores it.
const big = {
  from_i64: x => x, from_str: x => BigInt(String(x)), add: (a, b) => a + b, sub: (a, b) => a - b, mul: (a, b) => a * b,
  div: (a, b) => a / b, rem: (a, b) => a % b,
  band: (a, b) => a & b, bor: (a, b) => a | b, bxor: (a, b) => a ^ b,
  bsl: (a, b) => b >= 0n ? a << b : a >> -b, bsr: (a, b) => b >= 0n ? a >> b : a << -b,
  fits_i31: a => (a >= -1073741824n && a < 1073741824n) ? 1 : 0, to_i32: a => Number(a),
  fits_i64: a => (a >= -9223372036854775808n && a <= 9223372036854775807n) ? 1 : 0, to_i64: a => BigInt.asIntN(64, a),
  cmp: (a, b) => a < b ? -1 : (a > b ? 1 : 0), bit_length: a => a === 0n ? 0 : a.toString(2).length, to_f64: a => Number(a),
};
// Floats: :math.* lowers to host (JS Math) imports. Provided unconditionally, like `big`.
const math = Object.fromEntries(
  ["sin","cos","tan","asin","acos","atan","sqrt","exp","log","log2","log10",
   "sinh","cosh","tanh","ceil","floor","atan2","pow"].map(k => [k, Math[k]]));
const encU = new TextEncoder(), decU = new TextDecoder();
// String case mapping is delegated to the host (genuinely Unicode-table-backed, like math/big).
// The host reads/writes the WasmGC $binary through the exported bin_* helpers (e is assigned below).
let e;
const rdBin = b => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return decU.decode(u); };
const wrBin = s => { const u = encU.encode(s); const b = e.bin_alloc(u.length); u.forEach((c, i) => e.bin_put(b, i, c)); return b; };
const str = { upcase: b => wrBin(rdBin(b).toUpperCase()), downcase: b => wrBin(rdBin(b).toLowerCase()) };
e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { big, math, str }).exports;

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
    default: throw new Error("bad ret type " + type);
  }
};

const cases = JSON.parse(fs.readFileSync(casesPath, "utf8"));
const out = cases.map(c => {
  try { return canon(c.ret, e[c.name](...c.args.map(encArg))); }
  catch (err) { return "TRAP"; }
});
process.stdout.write(out.join("\n"));
