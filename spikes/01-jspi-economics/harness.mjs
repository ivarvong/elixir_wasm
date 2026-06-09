// JSPI economics benchmark for an Elixir-on-Workers process model.
// Each "process" = a promising() activation that blocks in a JSPI suspending recv().
//
// Run one measurement per process invocation for clean baselines:
//   node --experimental-wasm-jspi --expose-gc harness.mjs MODE N DEPTH [M]
// MODE = mem | wake | tput
//
// Emits a single CSV line: mode,N,depth,M,rss_base_mb,rss_after_mb,per_proc_kb,
//                          ext_delta_mb,heap_delta_mb,spawn_ms,work_ms,cycles_per_s
import fs from "node:fs";
import wabtInit from "wabt";

const [, , MODE = "mem", N_s = "1000", DEPTH_s = "0", M_s = "0"] = process.argv;
const N = parseInt(N_s, 10), DEPTH = parseInt(DEPTH_s, 10), M = parseInt(M_s, 10);

const wat = fs.readFileSync(new URL("./process.wat", import.meta.url), "utf8");
const wabt = await wabtInit();
const wasm = new Uint8Array(wabt.parseWat("process.wat", wat).toBinary({}).buffer);

const NEW = typeof WebAssembly.Suspending === "function" && typeof WebAssembly.promising === "function";
if (!NEW) { console.error("stable JSPI API not present"); process.exit(2); }

// Mailboxes + parked resolvers keyed by pid.
const parked = new Map();
const mailbox = new Map();
function recvImpl(pid) {
  const q = mailbox.get(pid);
  if (q && q.length) return q.shift();
  return new Promise((resolve) => parked.set(pid, resolve));
}
function deliver(pid, msg) {
  const r = parked.get(pid);
  if (r) { parked.delete(pid); r(msg); }
  else { let q = mailbox.get(pid); if (!q) { q = []; mailbox.set(pid, q); } q.push(msg); }
}

const recv = new WebAssembly.Suspending(recvImpl);
const { instance } = await WebAssembly.instantiate(wasm, { env: { recv } });
const spawn = WebAssembly.promising(instance.exports.process_main);

function gc2() { global.gc(); global.gc(); }
const MB = (b) => (b / 1048576);
function mem() { const m = process.memoryUsage(); return { rss: m.rss, ext: m.external, heap: m.heapUsed }; }

const csv = (o) => console.log([
  o.mode, o.N, o.depth, o.M,
  MB(o.base.rss).toFixed(1), MB(o.after.rss).toFixed(1),
  (((o.after.rss - o.base.rss) / o.N) / 1024).toFixed(2),
  MB(o.after.ext - o.base.ext).toFixed(1),
  MB(o.after.heap - o.base.heap).toFixed(1),
  o.spawn_ms ?? "", o.work_ms ?? "", o.cps ?? "",
].join(","));

if (MODE === "mem" || MODE === "wake") {
  // Spawn N processes; each blocks in recv() at the bottom of DEPTH live frames.
  gc2(); const base = mem();
  const inflight = new Array(N);
  const t0 = performance.now();
  for (let i = 0; i < N; i++) inflight[i] = spawn(i, DEPTH); // runs to first suspend, returns pending promise
  const spawn_ms = performance.now() - t0;
  await Promise.resolve(); // let any microtasks settle (none resolve; all are parked)
  if (parked.size !== N) { console.error(`expected ${N} parked, got ${parked.size}`); process.exit(3); }
  gc2(); const after = mem();

  let work_ms;
  if (MODE === "wake") {
    const w0 = performance.now();
    for (let i = 0; i < N; i++) deliver(i, -1); // sentinel -> each returns
    await Promise.all(inflight);
    work_ms = performance.now() - w0;
  }
  csv({ mode: MODE, N, depth: DEPTH, M, base, after, spawn_ms: spawn_ms.toFixed(1),
        work_ms: work_ms?.toFixed(1), cps: work_ms ? Math.round(N / (work_ms / 1000)) : "" });

} else if (MODE === "tput") {
  // P=N processes, each handles M messages then a sentinel. Measures steady-state
  // suspend/resume cycles/sec — the GenServer message hot path.
  gc2(); const base = mem();
  const inflight = new Array(N);
  for (let i = 0; i < N; i++) inflight[i] = spawn(i, DEPTH);
  await Promise.resolve();
  const after = mem();
  const t0 = performance.now();
  for (let round = 0; round < M; round++) for (let i = 0; i < N; i++) deliver(i, round);
  for (let i = 0; i < N; i++) deliver(i, -1);
  await Promise.all(inflight);
  const work_ms = performance.now() - t0;
  const cycles = N * M;
  csv({ mode: MODE, N, depth: DEPTH, M, base, after,
        work_ms: work_ms.toFixed(1), cps: Math.round(cycles / (work_ms / 1000)) });
}
