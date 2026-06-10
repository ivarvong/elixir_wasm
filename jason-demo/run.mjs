// Run the compiled-Elixir Jason encoder (WasmGC) and print each result.
//   node --stack-trace-limit=20 run.mjs        (node 24+, for Wasm exceptions)
import { readFileSync } from "node:fs";
const big = { from_i64:x=>x, from_float:x=>BigInt(Math.trunc(x)), add:(a,b)=>a+b, sub:(a,b)=>a-b, mul:(a,b)=>a*b,
  fits_i31:a=>(a>=-1073741824n&&a<1073741824n)?1:0, to_i32:a=>Number(a), cmp:(a,b)=>a<b?-1:a>b?1:0 };
const math = Object.fromEntries(["sin","cos","tan","asin","acos","atan","sqrt","exp","log",
  "log2","log10","sinh","cosh","tanh","ceil","floor","atan2","pow"].map(k=>[k,Math[k]]));
const { instance } = await WebAssembly.instantiate(readFileSync("jason_encode.wasm"), { big, math });
const e = instance.exports, dec = new TextDecoder();
const fromBin = b => { const n=e.bin_len(b); const u=new Uint8Array(n); for(let k=0;k<n;k++)u[k]=e.bin_get(b,k); return dec.decode(u); };
for (const f of ["order_json","report_json","scalars_json"])
  console.log(f.padEnd(14), fromBin(e[f]()));
