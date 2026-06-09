// Strix: real string-processing Elixir -> :beam_disasm -> beam2wasm -> WasmGC.
// Exercises binaries end to end: construction (<>, <<>>, integer segments),
// byte_size/len, and binary pattern matching with match-context threading.
// Build:  EXPORTS="count:bin,int,int->int;upcase:bin->bin;len:bin,int->int" \
//           elixir ../beam2wasm.exs Elixir.Strix.beam > strix.wat
//         wasm-as strix.wat -o strix.wasm -all
// Run:    node runstrix.mjs strix.wasm
import fs from "node:fs";
const { instance } = await WebAssembly.instantiate(new Uint8Array(fs.readFileSync(process.argv[2])), {});
const e = instance.exports;

const enc = new TextEncoder(), dec = new TextDecoder();
const toBin = s => { const u = enc.encode(s); const b = e.bin_alloc(u.length); u.forEach((c, i) => e.bin_put(b, i, c)); return b; };
const fromBin = b => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return dec.decode(u); };

// Oracle = the byte-level semantics the Elixir VM produces (verified against `elixir`).
const upcase = s => Buffer.from(enc.encode(s)).map(b => (b >= 97 && b <= 122) ? b - 32 : b);
const count = (s, c) => [...enc.encode(s)].filter(b => b === c.charCodeAt(0)).length;
const len = s => enc.encode(s).length;

console.log("--- Strix: real Elixir binaries -> :beam_disasm -> Elixir compiler -> WasmGC ---");
let ok = true;
const chk = (label, got, exp) => { const p = JSON.stringify(got) === JSON.stringify(exp); ok &&= p;
  console.log(`  ${label} = ${JSON.stringify(got)}  oracle ${JSON.stringify(exp)}  ${p ? "PASS" : "FAIL"}`); };

for (const s of ["Hello, World! 42", "héllo", "", "MiXeD cAsE"]) {
  chk(`upcase(${JSON.stringify(s)})`, fromBin(e.upcase(toBin(s))), dec.decode(upcase(s)));
}
for (const [s, c] of [["banana", "a"], ["mississippi", "s"], ["", "x"]]) {
  chk(`count(${JSON.stringify(s)},?${c})`, e.count(toBin(s), c.charCodeAt(0), 0), count(s, c));
}
for (const s of ["héllo", "abc", ""]) {
  chk(`len(${JSON.stringify(s)})`, e.len(toBin(s), 0), len(s));
}
console.log(ok ? "\nALL PASS" : "\nFAILED");
