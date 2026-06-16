#!/usr/bin/env bash
# The tiered-VM seed: an Elixir BEAM interpreter, AOT-compiled by our own compiler, running on
# our runtime, executing a .beam (target.ex) that we NEVER AOT-compiled — bit-exact with the VM.
set -euo pipefail
cd "$(dirname "$0")"
NODE="${NODE:-node}"   # override with NODE=/path/to/node (needs the 24.x line; see BUILD.md)

elixirc target.ex                                  # the program to RUN (becomes data, not code)
elixir gen_code.exs Elixir.Target.beam > prog.ex   # decode target.beam -> Prog.code() (a constant term)
elixirc interp.ex prog.ex demo.ex                  # interpreter + the code table + entry points

# AOT-compile ONLY the interpreter (+ code table) with beam2wasm. The target is never compiled.
EXPORTS="fib:int->int;sum:list->int;upto:int->list" \
  elixir ../compiler/beam2wasm.exs Elixir.Demo.beam Elixir.Interp.beam Elixir.Prog.beam > vm.wat
wasm-as vm.wat -o vm.wasm -all
echo "interpreter: $(wc -c < vm.wasm) bytes, $(grep -c 'STUB fn' vm.wat 2>/dev/null || echo 0) stubs"

$NODE -e '
const fs=require("fs");
const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync("vm.wasm"))).exports;
const toL=a=>a.reduceRight((l,x)=>e.cons(x,l),e.nil());
const toJ=l=>{const o=[];while(e.is_cons(l)){o.push(e.head(l));l=e.tail(l);}return o;};
const chk=(l,g,x)=>{const p=JSON.stringify(g)===JSON.stringify(x);console.log(`  ${l} = ${JSON.stringify(g)}  oracle ${JSON.stringify(x)}  ${p?"PASS":"FAIL"}`);};
console.log("--- interpreting target.beam (never AOT-compiled) on the compiled interpreter ---");
chk("fib(20)", e.fib(20), 6765);
chk("fib(25)", e.fib(25), 75025);
chk("sum([1..5])", e.sum(toL([1,2,3,4,5])), 15);
chk("upto(4)", toJ(e.upto(4)), [4,3,2,1]);
'
