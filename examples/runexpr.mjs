import fs from "node:fs";
const { instance } = await WebAssembly.instantiate(new Uint8Array(fs.readFileSync(process.argv[2])), {});
const e = instance.exports;
console.log("--- expression-language interpreter: Elixir -> :beam_disasm -> Elixir compiler -> WasmGC ---");
console.log("    (AST built + evaluated entirely in compiled WasmGC; demo(x) = x*6 + (x-6))");
let ok = true;
for (const [x, exp] of [[7,43],[10,64],[3,15],[6,36],[0,-6],[100,694]]) {
  const got = e.demo(x); const p = got === exp; ok &&= p;
  console.log(`  demo(${x}) = ${String(got).padStart(4)}   ${p ? "PASS" : "FAIL exp " + exp}`);
}
console.log(ok ? "\nALL PASS" : "\nFAILED");
