import fs from "node:fs";
const { instance } = await WebAssembly.instantiate(new Uint8Array(fs.readFileSync(process.argv[2])), {});
const e = instance.exports;
console.log("--- durable-account state machine: Elixir (maps) -> :beam_disasm -> Elixir compiler -> WasmGC ---");
console.log("    state = %{balance, status}; transitions pattern-match the map and produce %{s | ...}");
console.log("    demo(x): +50, -30, freeze, +100(ignored), -5(ignored), unfreeze, -999(overdraw,ignored), -5  => x+15");
let ok = true;
for (const [x, exp] of [[100,115],[0,15],[50,65],[978,993]]) {
  const got = e.demo(x); const p = got === exp; ok &&= p;
  console.log(`  demo(${String(x).padStart(3)}) = ${String(got).padStart(4)}   ${p ? "PASS" : "FAIL exp " + exp}`);
}
console.log(ok ? "\nALL PASS" : "\nFAILED");
