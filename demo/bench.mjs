// demo/bench.mjs <wasm> <fixture> — time the REAL Req pipeline on WasmGC, network-free.
// The fetch already happened once (captured to the fixture); the host http.get just hands back those
// in-memory bytes, so e.run() is pure compute: Req.new/merge → URI.parse → step pipeline → decode_body →
// extract JS URLs → :crypto.hash(:sha256). Report module-compile, instantiate, and per-run cost.
import fs from "node:fs";
import nodeCrypto from "node:crypto";
const [wasmPath, fixturePath] = process.argv.slice(2);
const encU = new TextEncoder(), decU = new TextDecoder();
const fixture = fs.readFileSync(fixturePath);
const bytes = fs.readFileSync(wasmPath);

const big = { from_i64: x => x, from_str: x => BigInt(String(x)), add: (a,b)=>a+b, sub:(a,b)=>a-b, mul:(a,b)=>a*b, div:(a,b)=>a/b, rem:(a,b)=>a%b, band:(a,b)=>a&b, bor:(a,b)=>a|b, bxor:(a,b)=>a^b, bsl:(a,b)=>b>=0n?a<<b:a>>-b, bsr:(a,b)=>b>=0n?a>>b:a<<-b, fits_i31:a=>(a>=-1073741824n&&a<1073741824n)?1:0, to_i32:a=>Number(a), fits_i64:a=>(a>=-9223372036854775808n&&a<=9223372036854775807n)?1:0, to_i64:a=>BigInt.asIntN(64,a), cmp:(a,b)=>a<b?-1:a>b?1:0, bit_length:a=>a===0n?0:a.toString(2).length, to_f64:a=>Number(a) };
const math = Object.fromEntries(["sin","cos","tan","asin","acos","atan","sqrt","exp","log","log2","log10","sinh","cosh","tanh","ceil","floor","atan2","pow"].map(k=>[k,Math[k]]));
let e;
const wrBytes = u => { const b = e.bin_alloc(u.length); for (let i=0;i<u.length;i++) e.bin_put(b,i,u[i]); return b; };
const rdBin = b => { const n=e.bin_len(b); const u=new Uint8Array(n); for (let i=0;i<n;i++) u[i]=e.bin_get(b,i); return decU.decode(u); };
const rawBytes = b => { const n=e.bin_len(b); const u=new Uint8Array(n); for (let i=0;i<n;i++) u[i]=e.bin_get(b,i); return u; };
const reSplit = (p,s)=>{ const parts=rdBin(s).split(new RegExp(rdBin(p))); const ch=parts.map(x=>encU.encode(x)); const tot=4+ch.reduce((a,c)=>a+4+c.length,0); const buf=new Uint8Array(tot),dv=new DataView(buf.buffer); dv.setUint32(0,ch.length); let o=4; for(const c of ch){dv.setUint32(o,c.length);o+=4;buf.set(c,o);o+=c.length;} return wrBytes(buf); };
const reRun = (p,s)=>{ const m=rdBin(s).match(new RegExp(rdBin(p))); if(!m){const b=e.bin_alloc(1);e.bin_put(b,0,0);return b;} let caps=Array.from(m); while(caps.length>1&&caps[caps.length-1]===undefined)caps.pop(); const enc=caps.map(c=>encU.encode(c===undefined?"":c)); const tot=5+enc.reduce((a,c)=>a+4+c.length,0); const buf=new Uint8Array(tot),dv=new DataView(buf.buffer); buf[0]=1;dv.setUint32(1,enc.length); let o=5; for(const c of enc){dv.setUint32(o,c.length);o+=4;buf.set(c,o);o+=c.length;} return wrBytes(buf); };
const str = { upcase:b=>wrBytes(encU.encode(rdBin(b).toUpperCase())), downcase:b=>wrBytes(encU.encode(rdBin(b).toLowerCase())), re_split:reSplit, re_run:reRun, titlecase:b=>{const s=rdBin(b);return wrBytes(encU.encode(s.length?s[0].toUpperCase()+s.slice(1):s));} };
// the response body lives in wasm memory (built ONCE); http.get returns that ref — so we measure the Req
// pipeline + parse + hash, not the byte-by-byte boundary copy. (A real host would bulk-copy once/request.)
let fixtureBin = null;
const http = { get: _ => fixtureBin };
const nodeAlgo = { sha:"sha1", sha224:"sha224", sha256:"sha256", sha384:"sha384", sha512:"sha512", md5:"md5" };
const crypto = { hash:(a,d)=>wrBytes(new Uint8Array(nodeCrypto.createHash(nodeAlgo[decU.decode(rawBytes(a))]||decU.decode(rawBytes(a))).update(Buffer.from(rawBytes(d))).digest())) };
const pdict = new Map();
const proc = { spawn:()=>999, spawn_link:()=>999, spawn_opt:()=>999, send:(_,m)=>m, self:()=>1, recv_has:()=>0, recv_cur:()=>null, recv_remove:()=>{}, recv_advance:()=>{}, recv_wait:()=>{}, exit:()=>{}, set_trap_exit:()=>{}, register:()=>{}, whereis:()=>0, monitor:()=>1, demonitor:()=>{}, alias_pid:p=>p, pdict_get:k=>pdict.has(k)?pdict.get(k):null, pdict_put:(k,v)=>{const o=pdict.has(k)?pdict.get(k):null;pdict.set(k,v);return o;} };
const sched = { yield:()=>{} };

const ms = () => performance.now();
let t = ms(); const mod = new WebAssembly.Module(bytes); const tCompile = ms() - t;
t = ms(); e = new WebAssembly.Instance(mod, { big, math, str, http, crypto, proc, sched }).exports; const tInstance = ms() - t;
fixtureBin = wrBytes(fixture);                      // build the response binary in wasm ONCE

for (let i = 0; i < 50; i++) e.run();              // warm up (JIT)
const N = 5000;
t = ms(); for (let i = 0; i < N; i++) e.run(); const total = ms() - t;

console.log(JSON.stringify({
  wasm_bytes: bytes.length,
  module_compile_ms: +tCompile.toFixed(2),
  instantiate_ms: +tInstance.toFixed(2),
  runs: N,
  per_run_us: +((total / N) * 1000).toFixed(2),
  runs_per_sec: Math.round(N / (total / 1000)),
}));
