// Walk the transitive .beam import closure of a seed module over installed OTP,
// excluding preloaded/BIF modules (they map to native runtime, not shipped bytecode).
// Reports raw + gzipped sizes; the gz bytecode is the interpreted-tier payload and the
// basis for the AOT projection (× the WasmGC expansion multiplier from the perf half).
import fs from "node:fs";
import zlib from "node:zlib";

const index = new Map();
for (const line of fs.readFileSync("beam_index.txt", "utf8").trim().split("\n")) {
  const [m, p] = line.split("\t"); index.set(m, p);
}
const preloaded = new Set([...fs.readFileSync("preloaded.txt","utf8").trim().split(/\s+/), ...(fs.existsSync("cut.txt")?fs.readFileSync("cut.txt","utf8").trim().split(/\s+/):[])]);

const u32 = (b, o) => (b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3]) >>> 0;
function parse(buf) {
  const chunks = {}; let p = 12;
  while (p < buf.length) { const id = buf.toString("latin1", p, p + 4); const size = u32(buf, p + 4); chunks[id] = buf.subarray(p + 8, p + 8 + size); p += 8 + size + ((4 - size % 4) % 4); }
  const ac = chunks.AtU8 || chunks.Atom; const atoms = [null];
  { let o = 4, n = u32(ac, 0); for (let i = 0; i < n; i++) { const len = ac[o++]; atoms.push(ac.toString("utf8", o, o + len)); o += len; } }
  const mods = new Set();
  if (chunks.ImpT) { const c = chunks.ImpT, n = u32(c, 0); let o = 4; for (let i = 0; i < n; i++) { mods.add(atoms[u32(c, o)]); o += 12; } }
  return { mods, code: chunks.Code || Buffer.alloc(0) };
}

const seedPath = process.argv[2] || "seed.beam";
const seedName = seedPath.replace(/.*\//, "").replace(/\.beam$/, "");
const visited = new Set(), excluded = new Set(), shipped = [];
const seedBuf = fs.readFileSync(seedPath), seedP = parse(seedBuf);
shipped.push({ name: seedName, file: seedBuf, code: seedP.code });
const queue = [...seedP.mods];

while (queue.length) {
  const m = queue.shift();
  if (visited.has(m)) continue;
  if (preloaded.has(m) || m === seedName) { excluded.add(m); continue; }
  const p = index.get(m);
  if (!p) { excluded.add(m); continue; }
  visited.add(m);
  const buf = fs.readFileSync(p), pr = parse(buf);
  shipped.push({ name: m, file: buf, code: pr.code });
  for (const dep of pr.mods) if (!visited.has(dep)) queue.push(dep);
}

const gz = b => zlib.gzipSync(b, { level: 9 }).length;
const kb = n => (n / 1024).toFixed(0) + " KB";
const totalFile = shipped.reduce((a, s) => a + s.file.length, 0);
const totalCode = shipped.reduce((a, s) => a + s.code.length, 0);
const gzCode = gz(Buffer.concat(shipped.map(s => s.code)));
const gzFile = gz(Buffer.concat(shipped.map(s => s.file)));

console.log(`seed: ${seedName}`);
console.log(`closure: ${shipped.length} modules shipped, ${excluded.size} excluded (preloaded/BIF/app)\n`);
console.log(`raw .beam total:        ${kb(totalFile)}`);
console.log(`raw Code (bytecode):    ${kb(totalCode)}`);
console.log(`gz Code (concat l9):    ${kb(gzCode)}   <- interpreted-tier bytecode payload`);
console.log(`gz .beam (concat l9):   ${kb(gzFile)}`);
console.log(`\nGZCODE_BYTES=${gz(Buffer.concat(shipped.map(s => s.code)))}`);
console.log(`\nexcluded: ${[...excluded].sort().join(" ")}`);
console.log(`\nshipped: ${shipped.map(s => s.name).sort().join(" ")}`);
