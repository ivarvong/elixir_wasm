import fs from "node:fs";
const hr=()=>process.hrtime.bigint();
const load=async(f,imp)=>(await WebAssembly.instantiate(new Uint8Array(fs.readFileSync(f)),imp||{})).instance.exports;
const N=30, CALLS=2*1346269-1;            // exact recursive call count of fib(30)
let yields=0;
const susp={sched:{yield:new WebAssembly.Suspending(async()=>{yields++;})}};
const base=await load("Smoke_aot.wasm");
const count=await load("smoke_count.wasm",susp);
const yld=await load("smoke_yield.wasm",susp);
const med=(fn,it=9)=>{const t=[];for(let i=0;i<it;i++){const s=hr();fn();t.push(Number(hr()-s)/1e6);}t.sort((a,b)=>a-b);return t[it>>1];};
base.fib(25);count.fib(25);               // warmup
const tB=med(()=>base.fib(N)), tC=med(()=>count.fib(N));
console.log("=== overhead of reduction counting (fib(30), "+(CALLS/1e6).toFixed(2)+"M calls) ===");
console.log(`  baseline (no counting)     : ${tB.toFixed(1)} ms`);
console.log(`  +reduction count, no yield : ${tC.toFixed(1)} ms   -> +${((tC/tB-1)*100).toFixed(0)}%  (${((tC-tB)*1e6/CALLS).toFixed(2)} ns / reduction)`);
yields=0;
const fibY=WebAssembly.promising(yld.fib);
const s=hr(); const r=await fibY(N); const tY=Number(hr()-s)/1e6;
console.log(`  +count +yield(budget 50k)  : ${tY.toFixed(1)} ms   result=${r} ${r===832040?"OK":"FAIL"}, suspended ${yields}x (~${Math.floor(CALLS/50000)} expected)`);

console.log("\n=== preemption: does a long computation monopolize the thread? ===");
// (a) blocking: synchronous fib while a microtask ticker tries to run
let blocked=0, done=false;
const t1=(async()=>{while(!done){blocked++;await Promise.resolve();}})();
await Promise.resolve(); const b0=blocked; base.fib(32); const b1=blocked; done=true; await t1;
console.log(`  blocking (sync fib(32))      : co-runner advanced ${b1-b0}x DURING the call  -> thread monopolized`);
// (b) preemptive: yielding fib while the same ticker runs
yields=0; let work=0, fibDone=false;
const t2=(async()=>{while(!fibDone){work++;await Promise.resolve();}})();
const fy=WebAssembly.promising(yld.fib);
const rr=await fy(32); fibDone=true; await t2;
console.log(`  preemptive (yielding fib(32)): co-runner advanced ${work}x DURING the call  -> thread SHARED (fib yielded ${yields}x)`);
