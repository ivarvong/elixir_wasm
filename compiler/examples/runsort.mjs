import fs from "node:fs";
import { makeBig } from "../../runtime/imports.mjs";
// The compiler emits `big.*` host imports for the integer tiers (i31 -> i64 -> host bignum);
// makeBig() is the canonical backing the whole repo uses (see runtime/imports.mjs).
const { instance } = await WebAssembly.instantiate(new Uint8Array(fs.readFileSync(process.argv[2])), { big: makeBig() });
const e = instance.exports;
const toWasm = arr => arr.reduceRight((l, x) => e.cons(x, l), e.nil());
const toJs = l => { const o = []; while (e.is_cons(l)) { o.push(e.head(l)); l = e.tail(l); } return o; };
const inputs = [[5,3,8,1,9,2,7,4,6,0], [3,1,2], [], [42], [9,8,7,6,5,4,3,2,1], [1,1,2,2,1]];
console.log("--- merge sort: real Elixir -> :beam_disasm -> Elixir compiler -> WasmGC ---");
let ok = true;
for (const inp of inputs) {
  const got = toJs(e.sort(toWasm(inp)));
  const exp = [...inp].sort((a,b)=>a-b);
  const p = JSON.stringify(got) === JSON.stringify(exp); ok &&= p;
  console.log(`  sort(${JSON.stringify(inp)}) = ${JSON.stringify(got)}  ${p?"PASS":"FAIL exp "+JSON.stringify(exp)}`);
}
console.log(ok ? "\nALL PASS" : "\nFAILED");
