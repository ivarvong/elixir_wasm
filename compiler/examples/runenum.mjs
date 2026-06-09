// EnumDemo: real, UNMODIFIED Elixir `Enum` compiled to WasmGC alongside a user module.
// Proves closures (make_fun3/call_fun) + module namespacing + a BIF shim (:lists.reverse/2)
// are enough to run idiomatic Enum pipelines over lists — no protocols, no exceptions.
//
// Build (see runenum.sh for the one-liner that locates Enum.beam):
//   elixirc enum_demo.ex
//   ENUM=$(elixir -e 'IO.puts(:code.which(Enum))')
//   STUB=1 EXPORTS="sumsq_evens:list->int;cnt:list->int;rev:list->list;anybig:list->atom;allpos:list->atom;mapsum:list->int" \
//     elixir ../beam2wasm.exs Elixir.EnumDemo.beam "$ENUM" > enum_demo.wat
//   wasm-as enum_demo.wat -o enum_demo.wasm -all
//   node runenum.mjs enum_demo.wasm enum_demo.wat
import fs from "node:fs";
const [wasmPath, watPath] = [process.argv[2], process.argv[3] || process.argv[2].replace(/\.wasm$/, ".wat")];
const atoms = JSON.parse(fs.readFileSync(watPath, "utf8").match(/@atoms (.*)/)[1]);
const e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath))).exports;

const toL = a => a.reduceRight((l, x) => e.cons(x, l), e.nil());
const toJ = l => { const o = []; while (e.is_cons(l)) { o.push(e.head(l)); l = e.tail(l); } return o; };
const L = [3, 1, 4, 1, 5, 9, 2, 6];

console.log("--- EnumDemo: real unmodified Elixir Enum -> :beam_disasm -> beam2wasm -> WasmGC ---");
let ok = true;
const chk = (lbl, got, exp) => { const p = JSON.stringify(got) === JSON.stringify(exp); ok &&= p;
  console.log(`  ${lbl} = ${JSON.stringify(got)}  oracle ${JSON.stringify(exp)}  ${p ? "PASS" : "FAIL"}`); };

chk("sumsq_evens  (Enum.filter |> map |> reduce)", e.sumsq_evens(toL(L)), 56);
chk("cnt          (Enum.count)",                   e.cnt(toL(L)), 8);
chk("rev          (Enum.reverse, :lists BIF shim)", toJ(e.rev(toL(L))), [6, 2, 9, 5, 1, 4, 1, 3]);
chk("anybig       (Enum.any?  >100)", atoms[e.anybig(toL(L))], "false");
chk("allpos       (Enum.all?  >0)",   atoms[e.allpos(toL(L))], "true");
chk("mapsum       (Enum.map |> Enum.sum)", e.mapsum(toL(L)), 39);
console.log(ok ? "\nALL PASS" : "\nFAILED");
