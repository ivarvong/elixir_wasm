// Smoketest: load a REAL .beam (Erlang/OTP compiler output), parse its container,
// decode its bytecode (BEAM compact operand encoding), and interpret it.
// Validated against the real BEAM VM's answers.
//   node runbeam.mjs smoke.beam
import fs from "node:fs";

const beamPath = process.argv[2] || "smoke.beam";
const buf = fs.readFileSync(beamPath);

// ---- opcode table (Op -> {name, arity}) from this OTP build ----
const OPC = new Map();
for (const line of fs.readFileSync("opcodes.txt", "utf8").trim().split("\n")) {
  const [op, name, ar] = line.trim().split(/\s+/);
  OPC.set(+op, { name, arity: +ar });
}

// ============ 1. container parser (IFF: "FOR1" <len> "BEAM" then chunks) ============
function u32(b, o) { return (b[o] << 24 | b[o+1] << 16 | b[o+2] << 8 | b[o+3]) >>> 0; }
if (buf.toString("latin1", 0, 4) !== "FOR1" || buf.toString("latin1", 8, 12) !== "BEAM")
  throw new Error("not a BEAM file");
const chunks = {};
let p = 12;
while (p < buf.length) {
  const id = buf.toString("latin1", p, p + 4);
  const size = u32(buf, p + 4);
  chunks[id] = buf.subarray(p + 8, p + 8 + size);
  p += 8 + size + ((4 - (size % 4)) % 4); // 4-byte aligned
}

// atoms: AtU8 = <u32 count> then count x (<u8 len><utf8 bytes>); 1-indexed
function parseAtoms(c) {
  const atoms = [null]; let o = 4, n = u32(c, 0);
  for (let i = 0; i < n; i++) { const len = c[o++]; atoms.push(c.toString("utf8", o, o + len)); o += len; }
  return atoms;
}
// table of u32 triples
function parseTriples(c) {
  const n = u32(c, 0), out = []; let o = 4;
  for (let i = 0; i < n; i++) { out.push([u32(c, o), u32(c, o + 4), u32(c, o + 8)]); o += 12; }
  return out;
}
const atoms   = parseAtoms(chunks.AtU8 || chunks.Atom);
const imports = parseTriples(chunks.ImpT).map(([m, f, a]) => ({ m: atoms[m], f: atoms[f], a }));
const exports = parseTriples(chunks.ExpT).map(([f, a, lbl]) => ({ f: atoms[f], a, label: lbl }));

console.log(`module: ${atoms[1]}   atoms:${atoms.length-1} imports:${imports.length} exports:${exports.length}`);
console.log("imports:", imports.map(i => `${i.m}:${i.f}/${i.a}`).join(", "));
console.log("exports:", exports.map(e => `${e.f}/${e.a}@L${e.label}`).join(", "));

// ============ 2. bytecode decoder (compact operand encoding) ============
const TAGS = ["u", "i", "a", "x", "y", "f", "h", "z"];
function operand(r) {
  const byte = r.b[r.p++], tag = byte & 7;
  let val;
  if ((byte & 0x08) === 0)       val = byte >> 4;                       // 4-bit
  else if ((byte & 0x10) === 0)  val = ((byte >> 5) << 8) | r.b[r.p++]; // 11-bit
  else {                                                                // n-byte
    let n = byte >> 5;
    if (n === 7) { n = operand(r).val + 9; } else { n = n + 2; }
    let v = 0n; for (let i = 0; i < n; i++) v = (v << 8n) | BigInt(r.b[r.p++]);
    if (tag === 1 && (r.b[r.p - n] & 0x80)) v -= (1n << BigInt(8 * n));  // signed int
    val = Number(v);
  }
  if (tag === 7) {                       // extended operand; subtype = val
    if (val === 1) {                     // list (select_val / select_tuple_arity)
      const cnt = operand(r).val, items = [];
      for (let i = 0; i < cnt; i++) items.push(operand(r));
      return { tag: "list", items };
    }
    if (val === 4) return { tag: "literal", val: operand(r).val }; // LitT index
    if (val === 2) return { tag: "fr",    val: operand(r).val };
    if (val === 3) return { tag: "alloc", val: operand(r).val };
    if (val === 0) { const f = Buffer.from(r.b.subarray(r.p, r.p + 8)).readDoubleBE(0); r.p += 8; return { tag: "float", val: f }; }
    return { tag: "z", val };
  }
  return { tag: TAGS[tag], val };
}

// Code chunk: <u32 subSize> <set> <opcode_max> <labels> <functions> then bytecode
const code = chunks.Code;
const subSize = u32(code, 0);
const bcStart = 4 + subSize;
const r = { b: code, p: bcStart };
const instrs = [];          // {op,name,args}
const label2idx = new Map();
let unknown = null;
while (r.p < code.length) {
  const op = r.b[r.p++];
  const meta = OPC.get(op);
  if (!meta) { unknown = { op, at: r.p - 1 }; break; }
  const args = [];
  for (let i = 0; i < meta.arity; i++) args.push(operand(r));
  if (meta.name === "label") label2idx.set(args[0].val, instrs.length);
  instrs.push({ op, name: meta.name, args });
}
console.log(`\ndecoded ${instrs.length} instructions from Code chunk` + (unknown ? ` (stopped at unknown opcode ${unknown.op}@${unknown.at})` : " (clean to end)"));

// pretty-print one function's decoded ops (compare against erlc -S)
function fmt(a) {
  if (a.tag === "x" || a.tag === "y") return a.tag + a.val;
  if (a.tag === "f") return "f" + a.val;
  if (a.tag === "a") return "'" + (atoms[a.val] ?? a.val) + "'";
  if (a.tag === "i" || a.tag === "u") return String(a.val);
  if (a.tag === "list") return "[" + a.items.map(fmt).join(",") + "]";
  return a.tag + (a.val ?? "");
}
const factEntry = exports.find(e => e.f === "fact" && e.a === 1).label;
console.log(`\n--- decoded fact/1 (entry L${factEntry}); compare to erlc -S ---`);
for (let i = label2idx.get(factEntry - 1); i < instrs.length; i++) {  // start at func_info's label
  const ins = instrs[i];
  console.log("  " + ins.name + " " + ins.args.map(fmt).join(", "));
  if (ins.name === "return") break;
}

// ============ 3. minimal interpreter ============
const NIL = Symbol("nil");
const HALT = -1;
function bifApply(imp, a, b) {
  if (imp.m === "erlang" && imp.a === 2) {
    if (imp.f === "+") return a + b;
    if (imp.f === "-") return a - b;
    if (imp.f === "*") return a * b;
  }
  throw new Error(`unimplemented BIF ${imp.m}:${imp.f}/${imp.a}`);
}
function run(fnName, arity, args) {
  const ex = exports.find(e => e.f === fnName && e.a === arity);
  if (!ex) throw new Error(`no export ${fnName}/${arity}`);
  const X = args.slice();        // x registers
  const FRAMES = [];             // [{cp, y:[]}]
  let CP = HALT, IP = label2idx.get(ex.label), reductions = 0, steps = 0;
  const rd = a => a.tag === "x" ? X[a.val]
                : a.tag === "y" ? FRAMES[FRAMES.length-1].y[a.val]
                : (a.tag === "i" || a.tag === "u") ? a.val
                : a.tag === "a" ? atoms[a.val]
                : (() => { throw new Error("rd " + a.tag); })();
  const wr = (a, v) => { if (a.tag === "x") X[a.val] = v; else if (a.tag === "y") FRAMES[FRAMES.length-1].y[a.val] = v; else throw new Error("wr " + a.tag); };
  for (;;) {
    if (IP === HALT) return { value: X[0], reductions, steps };
    const ins = instrs[IP]; steps++;
    const A = ins.args;
    switch (ins.name) {
      case "label": case "line": IP++; break;
      case "func_info": throw new Error(`function_clause in ${fnName}/${arity}`);
      case "move": wr(A[1], rd(A[0])); IP++; break;
      case "gc_bif2": { const imp = imports[A[2].val]; wr(A[5], bifApply(imp, rd(A[3]), rd(A[4]))); IP++; break; }
      case "gc_bif1": { const imp = imports[A[2].val]; wr(A[4], bifApply(imp, rd(A[3]))); IP++; break; }
      case "is_eq_exact": IP = (rd(A[1]) === rd(A[2])) ? IP + 1 : label2idx.get(A[0].val); break;
      case "is_lt":       IP = (rd(A[1]) <   rd(A[2])) ? IP + 1 : label2idx.get(A[0].val); break;
      case "is_ge":       IP = (rd(A[1]) >=  rd(A[2])) ? IP + 1 : label2idx.get(A[0].val); break;
      case "select_val": {
        const v = rd(A[0]); const lst = A[2].items; let tgt = A[1].val;  // default = fail label
        for (let i = 0; i < lst.length; i += 2) if (rd(lst[i]) === v) { tgt = lst[i+1].val; break; }
        IP = label2idx.get(tgt); break;
      }
      case "jump": IP = label2idx.get(A[0].val); break;
      case "allocate": case "allocate_heap":
        FRAMES.push({ cp: CP, y: new Array(A[0].val).fill(NIL) }); IP++; break;
      case "test_heap": IP++; break;                       // GC hint — no-op (host GC)
      case "deallocate": CP = FRAMES[FRAMES.length-1].cp; FRAMES.pop(); IP++; break;
      case "call": reductions++; CP = IP + 1; IP = label2idx.get(A[1].val); break;
      case "return": IP = CP; break;
      default: throw new Error(`unimplemented opcode '${ins.name}' at IP=${IP}`);
    }
  }
}

// ============ validate against the real BEAM VM ============
const ORACLE = { "add(2,3)": 5, "dbl(21)": 42, "fact(10)": 3628800, "fib(20)": 6765 };
const cases = [
  ["add", 2, [2, 3], "add(2,3)"],
  ["dbl", 1, [21],   "dbl(21)"],
  ["fact", 1, [10],  "fact(10)"],
  ["fib", 1, [20],   "fib(20)"],
];
console.log("\n--- execute (interpreter) vs BEAM VM oracle ---");
for (const [fn, ar, args, key] of cases) {
  try {
    const { value, reductions, steps } = run(fn, ar, args);
    const ok = value === ORACLE[key];
    console.log(`  ${key.padEnd(11)} = ${String(value).padEnd(8)} oracle ${ORACLE[key]}  ${ok ? "PASS" : "FAIL"}   (${steps} steps, ${reductions} reductions)`);
  } catch (e) {
    console.log(`  ${key.padEnd(11)} -> ERROR: ${e.message}`);
  }
}
