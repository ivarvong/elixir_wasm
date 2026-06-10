// durable-sql Wasm runner: per seed, a FRESH instance + a FRESH in-memory SQLite — mirroring
// the VM oracle (one sqlsrv per seed). Prints one base64(report) line per seed.
//   node runner.mjs <wasm> <seed> [<seed> ...]
import fs from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, makeSql, memFsBacking, nodeSqliteBacking } from "../../runtime/imports.mjs";

const [wasmPath, ...seeds] = process.argv.slice(2);
const bytes = fs.readFileSync(wasmPath);
const mod = new WebAssembly.Module(bytes);

for (const seed of seeds) {
  const big = makeBig(), math = makeMath();
  let e;
  const str = makeStr(() => e);
  const { proc, sched } = makeProcStubs();
  const db = new DatabaseSync(":memory:");
  e = new WebAssembly.Instance(mod, {
    big, math, str, proc, sched,
    fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e),
    sql: makeSql(() => e, nodeSqliteBacking(db)),
  }).exports;
  let out;
  try {
    const r = e.run(Number(seed));
    const n = e.bin_len(r);
    const u = new Uint8Array(n);
    for (let i = 0; i < n; i++) u[i] = e.bin_get(r, i);
    out = Buffer.from(u).toString("base64");
  } catch (err) {
    out = "TRAP:" + Buffer.from(String(err.message).slice(0, 80)).toString("base64");
  }
  process.stdout.write(out + "\n");
}
