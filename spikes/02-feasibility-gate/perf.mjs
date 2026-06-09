// Spike A perf: same workload (fib N) three ways —
//   (1) our BEAM bytecode interpreter (the hot-reload / dynamic tier)
//   (2) the WasmGC lowering over i31 terms (the AOT tier)
//   (3) an idiomatic JS-backend port (the "why not just compile to JS" baseline)
// Plus the AOT size multiplier: WasmGC code bytes per byte of BEAM bytecode.
import fs from "node:fs";
import zlib from "node:zlib";

const BEAM = "../beam-smoke/smoke.beam";
const OPC = new Map();
for (const l of fs.readFileSync("../beam-smoke/opcodes.txt", "utf8").trim().split("\n")) { const [o, n, a] = l.trim().split(/\s+/); OPC.set(+o, { name: n, arity: +a }); }

// ---- parse + decode (trimmed from runbeam) ----
const buf = fs.readFileSync(BEAM);
const u32 = (b, o) => (b[o] << 24 | b[o+1] << 16 | b[o+2] << 8 | b[o+3]) >>> 0;
const chunks = {}; { let p = 12; while (p < buf.length) { const id = buf.toString("latin1", p, p+4), s = u32(buf, p+4); chunks[id] = buf.subarray(p+8, p+8+s); p += 8 + s + ((4 - s%4)%4); } }
const atoms = [null]; { const c = chunks.AtU8; let o = 4, n = u32(c, 0); for (let i = 0; i < n; i++) { const len = c[o++]; atoms.push(c.toString("utf8", o, o+len)); o += len; } }
const imports = []; { const c = chunks.ImpT, n = u32(c, 0); let o = 4; for (let i = 0; i < n; i++) { imports.push({ m: atoms[u32(c,o)], f: atoms[u32(c,o+4)], a: u32(c,o+8) }); o += 12; } }
const exports = []; { const c = chunks.ExpT, n = u32(c, 0); let o = 4; for (let i = 0; i < n; i++) { exports.push({ f: atoms[u32(c,o)], a: u32(c,o+4), label: u32(c,o+8) }); o += 12; } }
const TAGS = ["u","i","a","x","y","f","h","z"];
function operand(r) {
  const byte = r.b[r.p++], tag = byte & 7; let val;
  if ((byte & 8) === 0) val = byte >> 4;
  else if ((byte & 16) === 0) val = ((byte >> 5) << 8) | r.b[r.p++];
  else { let n = byte >> 5; n = n === 7 ? operand(r).val + 9 : n + 2; let v = 0n; for (let i = 0; i < n; i++) v = (v<<8n)|BigInt(r.b[r.p++]); val = Number(v); }
  if (tag === 7) { if (val === 1) { const cnt = operand(r).val, items = []; for (let i=0;i<cnt;i++) items.push(operand(r)); return { tag:"list", items }; } return { tag:"z", val }; }
  return { tag: TAGS[tag], val };
}
const code = chunks.Code, sub = u32(code, 0); const r = { b: code, p: 4 + sub };
const instrs = [], L = new Map();
while (r.p < code.length) { const op = r.b[r.p++], m = OPC.get(op); if (!m) break; const args = []; for (let i=0;i<m.arity;i++) args.push(operand(r)); if (m.name === "label") L.set(args[0].val, instrs.length); instrs.push({ name: m.name, args }); }

function bif(imp, a, b) { return imp.f === "+" ? a+b : imp.f === "-" ? a-b : imp.f === "*" ? a*b : (()=>{throw 0})(); }
function interp(fn, ar, args) {
  const ex = exports.find(e => e.f === fn && e.a === ar);
  const X = args.slice(), F = []; let CP = -1, IP = L.get(ex.label);
  const rd = a => a.tag === "x" ? X[a.val] : a.tag === "y" ? F[F.length-1].y[a.val] : a.val;
  const wr = (a, v) => { if (a.tag === "x") X[a.val] = v; else F[F.length-1].y[a.val] = v; };
  for (;;) {
    if (IP === -1) return X[0];
    const ins = instrs[IP], A = ins.args;
    switch (ins.name) {
      case "label": IP++; break;
      case "func_info": throw new Error("function_clause");
      case "move": wr(A[1], rd(A[0])); IP++; break;
      case "gc_bif2": wr(A[5], bif(imports[A[2].val], rd(A[3]), rd(A[4]))); IP++; break;
      case "gc_bif1": wr(A[4], bif(imports[A[2].val], rd(A[3]))); IP++; break;
      case "is_eq_exact": IP = rd(A[1]) === rd(A[2]) ? IP+1 : L.get(A[0].val); break;
      case "is_lt": IP = rd(A[1]) < rd(A[2]) ? IP+1 : L.get(A[0].val); break;
      case "select_val": { const v = rd(A[0]), lst = A[2].items; let t = A[1].val; for (let i=0;i<lst.length;i+=2) if (rd(lst[i]) === v) { t = lst[i+1].val; break; } IP = L.get(t); break; }
      case "allocate": case "allocate_heap": F.push({ cp: CP, y: new Array(A[0].val).fill(0) }); IP++; break;
      case "test_heap": IP++; break;
      case "deallocate": CP = F[F.length-1].cp; F.pop(); IP++; break;
      case "call": CP = IP+1; IP = L.get(A[1].val); break;
      case "return": IP = CP; break;
      default: throw new Error("op " + ins.name);
    }
  }
}

// ---- JS-backend port (terms are JS numbers) ----
function jsFib(n) { return n < 2 ? n : jsFib(n-1) + jsFib(n-2); }

// ---- WasmGC tier ----
const { instance } = await WebAssembly.instantiate(new Uint8Array(fs.readFileSync("fib_lift.wasm")), {});
const wasmFib = instance.exports.fib;

// ---- run ----
const N = 30;
const calls = (() => { const c = [1,1]; for (let i=2;i<=N;i++) c[i]=1+c[i-1]+c[i-2]; return c[N]; })(); // $fib invocations
const time = (f, iters) => { const t0 = process.hrtime.bigint(); for (let i=0;i<iters;i++) f(); return Number(process.hrtime.bigint()-t0)/iters; };

// warm + correctness
console.log(`fib(${N}): interp=${interp("fib",1,[N])} wasm=${wasmFib(N)} js=${jsFib(N)}  (${calls.toLocaleString()} calls each)\n`);

const tInterp = Math.min(time(()=>interp("fib",1,[N]),3), time(()=>interp("fib",1,[N]),3));
const tJs     = Math.min(time(()=>jsFib(N),20), time(()=>jsFib(N),20));
const tWasm   = Math.min(time(()=>wasmFib(N),50), time(()=>wasmFib(N),50));

const row = (label, ns) => console.log(`  ${label.padEnd(22)} ${(ns/1e6).toFixed(2).padStart(8)} ms   ${(ns/calls).toFixed(1).padStart(6)} ns/call   ${(tWasm/ns).toFixed(3)}x wasm`);
console.log("tier                     time/fib(30)   per-call      speed vs WasmGC");
row("WasmGC (AOT)", tWasm);
row("JS backend", tJs);
row("BEAM interpreter", tInterp);

// ---- size multiplier ----
const gz = b => zlib.gzipSync(b, { level: 9 }).length;
const beamCode = chunks.Code;                 // bytecode for add/dbl/fact/fib/module_info
const wasm = fs.readFileSync("fib_lift.wasm"); // WasmGC for add/dbl/fact/fib
console.log(`\nsize (same fns, add/dbl/fact/fib):`);
console.log(`  BEAM Code chunk:  ${beamCode.length} B raw, ${gz(beamCode)} B gz`);
console.log(`  WasmGC module:    ${wasm.length} B raw, ${gz(wasm)} B gz`);
console.log(`  AOT multiplier:   ${(wasm.length/beamCode.length).toFixed(2)}x raw, ${(gz(wasm)/gz(beamCode)).toFixed(2)}x gz  (WasmGC bytes per BEAM-bytecode byte)`);

// ---- project the closure against 10 MB ----
const GZCODE = 373204;        // pruned gen_server closure, gz bytecode (from closure.mjs)
const GZCODE_FULL = 1112707;  // unpruned upper bound
const mult = gz(wasm)/gz(beamCode);
const fmtMB = b => (b/1024/1024).toFixed(2) + " MB";
console.log(`\nproject vs 10 MB module limit (gen_server actor closure):`);
console.log(`  interpreted tier (bytecode):  pruned ${fmtMB(GZCODE)} | unpruned ${fmtMB(GZCODE_FULL)}`);
console.log(`  AOT tier (bytecode x ${mult.toFixed(1)}):     pruned ${fmtMB(GZCODE*mult)} | unpruned ${fmtMB(GZCODE_FULL*mult)}`);
