// Run real Elixir list code from its .beam: extends the smoketest interpreter with the
// cons/list opcodes (put_list/get_list/is_nonempty_list/is_nil) + tail calls (call_last/only).
// Terms: small int = JS number, [] = NIL, cons = {h,t}. Validated vs the Elixir VM.
import fs from "node:fs";
const BEAM = process.argv[2] || "Elixir.Lists.beam";
const OPC = new Map();
for (const l of fs.readFileSync("opcodes.txt", "utf8").trim().split("\n")) { const [o, n, a] = l.trim().split(/\s+/); OPC.set(+o, { name: n, arity: +a }); }

const buf = fs.readFileSync(BEAM);
const u32 = (b, o) => (b[o]<<24|b[o+1]<<16|b[o+2]<<8|b[o+3])>>>0;
const C = {}; { let p = 12; while (p < buf.length) { const id = buf.toString("latin1", p, p+4), s = u32(buf, p+4); C[id] = buf.subarray(p+8, p+8+s); p += 8 + s + ((4 - s%4)%4); } }
const atoms = [null]; { const c = C.AtU8; let o = 4, n = u32(c, 0); for (let i = 0; i < n; i++) { const len = c[o++]; atoms.push(c.toString("utf8", o, o+len)); o += len; } }
const imports = []; { const c = C.ImpT, n = u32(c, 0); let o = 4; for (let i = 0; i < n; i++) { imports.push({ m: atoms[u32(c,o)], f: atoms[u32(c,o+4)], a: u32(c,o+8) }); o += 12; } }
const exports = []; { const c = C.ExpT, n = u32(c, 0); let o = 4; for (let i = 0; i < n; i++) { exports.push({ f: atoms[u32(c,o)], a: u32(c,o+4), label: u32(c,o+8) }); o += 12; } }
const TAGS = ["u","i","a","x","y","f","h","z"];
function operand(r) {
  const byte = r.b[r.p++], tag = byte & 7; let val;
  if ((byte & 8) === 0) val = byte >> 4;
  else if ((byte & 16) === 0) val = ((byte >> 5) << 8) | r.b[r.p++];
  else { let n = byte >> 5; n = n === 7 ? operand(r).val + 9 : n + 2; let v = 0n; for (let i = 0; i < n; i++) v = (v<<8n)|BigInt(r.b[r.p++]); val = Number(v); }
  if (tag === 7) { if (val === 1) { const cnt = operand(r).val, it = []; for (let i=0;i<cnt;i++) it.push(operand(r)); return { tag:"list", it }; } return { tag:"z", val }; }
  return { tag: TAGS[tag], val };
}
const code = C.Code, sub = u32(code, 0); const r = { b: code, p: 4 + sub };
const instrs = [], L = new Map();
while (r.p < code.length) { const op = r.b[r.p++], m = OPC.get(op); if (!m) break; const args = []; for (let i=0;i<m.arity;i++) args.push(operand(r)); if (m.name === "label") L.set(args[0].val, instrs.length); instrs.push({ name: m.name, args }); }

const NIL = Symbol("[]");
const isCons = v => typeof v === "object" && v !== null && "t" in v;
const bif = (imp, a, b) => imp.f === "+" ? a+b : imp.f === "-" ? a-b : imp.f === "*" ? a*b : (()=>{throw new Error("bif " + imp.f)})();
function run(fn, ar, args) {
  const ex = exports.find(e => e.f === fn && e.a === ar);
  if (!ex) throw new Error(`no export ${fn}/${ar}`);
  const X = args.slice(), F = []; let CP = -1, IP = L.get(ex.label);
  const rd = a => a.tag === "x" ? X[a.val] : a.tag === "y" ? F[F.length-1].y[a.val] : a.tag === "a" ? (a.val === 0 ? NIL : atoms[a.val]) : a.val;
  const wr = (a, v) => { if (a.tag === "x") X[a.val] = v; else F[F.length-1].y[a.val] = v; };
  for (;;) {
    if (IP === -1) return X[0];
    const ins = instrs[IP], A = ins.args;
    switch (ins.name) {
      case "label": case "line": IP++; break;
      case "func_info": throw new Error(`function_clause in ${fn}/${ar}`);
      case "move": wr(A[1], rd(A[0])); IP++; break;
      case "gc_bif2": wr(A[5], bif(imports[A[2].val], rd(A[3]), rd(A[4]))); IP++; break;
      case "gc_bif1": wr(A[4], bif(imports[A[2].val], rd(A[3]))); IP++; break;
      case "is_eq_exact": IP = rd(A[1]) === rd(A[2]) ? IP+1 : L.get(A[0].val); break;
      case "is_lt": IP = rd(A[1]) < rd(A[2]) ? IP+1 : L.get(A[0].val); break;
      // --- list / cons ---
      case "is_nonempty_list": IP = isCons(rd(A[1])) ? IP+1 : L.get(A[0].val); break;
      case "is_nil": IP = rd(A[1]) === NIL ? IP+1 : L.get(A[0].val); break;
      case "get_list": { const c = rd(A[0]); wr(A[1], c.h); wr(A[2], c.t); IP++; break; }
      case "put_list": wr(A[2], { h: rd(A[0]), t: rd(A[1]) }); IP++; break;
      // --- control ---
      case "select_val": { const v = rd(A[0]), lst = A[2].it; let t = A[1].val; for (let i=0;i<lst.length;i+=2) if (rd(lst[i]) === v) { t = lst[i+1].val; break; } IP = L.get(t); break; }
      case "jump": IP = L.get(A[0].val); break;
      case "allocate": case "allocate_heap": F.push({ cp: CP, y: new Array(A[0].val).fill(NIL) }); IP++; break;
      case "test_heap": IP++; break;
      case "deallocate": CP = F[F.length-1].cp; F.pop(); IP++; break;
      case "call": CP = IP+1; IP = L.get(A[1].val); break;
      case "call_only": IP = L.get(A[1].val); break;                                   // tail call
      case "call_last": CP = F[F.length-1].cp; F.pop(); IP = L.get(A[1].val); break;    // dealloc + tail call
      case "return": IP = CP; break;
      default: throw new Error(`unimplemented opcode '${ins.name}' at IP=${IP}`);
    }
  }
}
function term(v) { if (v === NIL) return "[]"; if (isCons(v)) { let s = "[", first = true, c = v; while (isCons(c)) { s += (first?"":",") + term(c.h); first = false; c = c.t; } return s + "]"; } return String(v); }
const cons = arr => arr.reduceRight((t, h) => ({ h, t }), NIL);   // JS array -> cons list term

console.log(`module: ${atoms[1]}  (decoded ${instrs.length} instrs)\n`);
const cases = [
  ["sumto", 1, [100], 5050],
  ["sumto", 1, [1000], 500500],
  ["upto",  1, [5], "[5,4,3,2,1]"],            // list construction (put_list)
  ["sum",   1, [cons([1,2,3])], 6],            // pass a real list term, pattern-match it
  ["sum",   1, [cons([10,20,30,40])], 100],
];
console.log("--- real Elixir, executed on our interpreter, vs the Elixir VM ---");
for (const [fn, ar, args, expect] of cases) {
  const got = term(run(fn, ar, args));
  const inp = args.map(term).join(",");
  console.log(`  Lists.${fn}(${inp})`.padEnd(34) + `= ${String(got).padEnd(12)} oracle ${expect}  ${String(got) === String(expect) ? "PASS" : "FAIL"}`);
}
