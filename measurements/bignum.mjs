import fs from "node:fs";
const big = { from_i64:(x)=>x, from_float:(x)=>BigInt(Math.trunc(x)), add:(a,b)=>a+b, sub:(a,b)=>a-b, mul:(a,b)=>a*b,
              to_u64:(a)=>BigInt.asIntN(64,a), from_u64:(v)=>BigInt.asUintN(64,v), fits_i31:(a)=>(a>=-1073741824n && a<1073741824n)?1:0, to_i32:(a)=>Number(a) };
const e=(await WebAssembly.instantiate(new Uint8Array(fs.readFileSync("smoke_big.wasm")),{big})).instance.exports;
const oracle = { 12:"479001600", 13:"6227020800", 20:"2432902008176640000", 21:"51090942171709440000",
  25:"15511210043330985984000000", 50:"30414093201713378043612608166064768844377641568960512000000000000" };
console.log("=== exact arbitrary-precision factorial (i31 -> boxed BigInt on overflow) ===");
const bound = n => n<13?"i31":(n<=20?"boxed (within i64)":"boxed BigInt (> i64)");
let ok=true;
for (const n of [12,13,20,21,25,50]) {
  const got = e.fact(n).toString(); const p = got===oracle[n]; ok&&=p;
  console.log(`  fact(${String(n).padStart(2)}) [${bound(n).padEnd(20)}] = ${got}  ${p?"EXACT":"WRONG"}`);
}
console.log(ok ? "\nALL EXACT — matches the Elixir VM" : "\nMISMATCH");
