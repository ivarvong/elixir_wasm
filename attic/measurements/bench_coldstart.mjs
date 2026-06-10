import fs from "node:fs";
const pct=(a,p)=>{const s=[...a].sort((x,y)=>x-y);return s[Math.min(s.length-1,Math.floor(p/100*s.length))];};
const hr=()=>process.hrtime.bigint();
console.log("module                 size    COMPILE (µs)        INSTANTIATE (µs)");
console.log("                              p50     p99        p50      p99");
for (const f of process.argv.slice(2)) {
  const bytes=new Uint8Array(fs.readFileSync(f));
  const ct=[]; for(let i=0;i<300;i++){const t=hr();await WebAssembly.compile(bytes);ct.push(Number(hr()-t)/1000);}
  const mod=await WebAssembly.compile(bytes);
  const it=[]; for(let i=0;i<5000;i++){const t=hr();new WebAssembly.Instance(mod,{});it.push(Number(hr()-t)/1000);}
  const name=f.replace(/.*\//,'').replace(/_aot|\.wasm/g,'');
  console.log(`${name.padEnd(20)} ${String(bytes.length).padStart(7)} ${pct(ct,50).toFixed(1).padStart(7)} ${pct(ct,99).toFixed(1).padStart(8)}   ${pct(it,50).toFixed(2).padStart(7)} ${pct(it,99).toFixed(2).padStart(8)}`);
}
