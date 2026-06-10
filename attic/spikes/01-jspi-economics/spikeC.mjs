// Spike C: shared-heap (WasmGC) behavior — the cost of losing per-process heaps.
//   C1  GC pause distribution + throughput under allocation churn across many processes
//   C2  garbage throughput as the live set grows toward a 128 MB-style cap
//   C3  deferred reclamation: a dead process's memory persists until the next GC
// Run: node --experimental-wasm-jspi --expose-gc --max-old-space-size=128 spikeC.mjs
import fs from "node:fs";
import { PerformanceObserver, performance } from "node:perf_hooks";

// spikeC.wat is assembled by Binaryen (wabt 1.0.39 can't emit WasmGC instructions):
//   /tmp/binaryen-version_130/bin/wasm-as spikeC.wat -o spikeC.wasm -all
const wasm = new Uint8Array(fs.readFileSync(new URL("./spikeC.wasm", import.meta.url)));

const parked = new Map(), mailbox = new Map();
function recvImpl(pid) { const q = mailbox.get(pid); if (q && q.length) return q.shift(); return new Promise(r => parked.set(pid, r)); }
function deliver(pid, msg) { const r = parked.get(pid); if (r) { parked.delete(pid); r(msg); } else { let q = mailbox.get(pid); if (!q) { q = []; mailbox.set(pid, q); } q.push(msg); } }

const { instance } = await WebAssembly.instantiate(wasm, { env: { recv: new WebAssembly.Suspending(recvImpl) } });
const X = instance.exports;
const spawn = WebAssembly.promising(X.process_main);
const gc2 = () => { global.gc(); global.gc(); };
const heapMB = () => process.memoryUsage().heapUsed / 1048576;
const rssMB = () => process.memoryUsage().rss / 1048576;
const pct = (xs, p) => { const s = [...xs].sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.floor(p * s.length))] : 0; };

// ---- C1: GC pauses + throughput under multi-process churn ----
{
  const P = 2000, M = 200, LEN = 200;          // P*M*LEN = 80M cons-cell allocations
  const pauses = [], kinds = { minor: 0, major: 0, other: 0 };
  const obs = new PerformanceObserver((list) => {
    for (const e of list.getEntries()) {
      pauses.push(e.duration);
      const k = e.detail?.kind;
      if (k === 1 || k === 2) kinds.minor++; else if (k === 4 || k === 8) kinds.major++; else kinds.other++;
    }
  });
  obs.observe({ entryTypes: ["gc"] });
  gc2();
  const inflight = new Array(P);
  for (let i = 0; i < P; i++) inflight[i] = spawn(i, LEN);
  await Promise.resolve();
  const t0 = performance.now();
  for (let r = 0; r < M; r++) for (let i = 0; i < P; i++) deliver(i, r);
  for (let i = 0; i < P; i++) deliver(i, -1);
  await Promise.all(inflight);
  const ms = performance.now() - t0;
  await new Promise(r => setTimeout(r, 30)); obs.disconnect();

  const totalPause = pauses.reduce((a, b) => a + b, 0);
  const allocs = P * M * LEN;
  console.log(`C1 churn: ${P} procs x ${M} msgs x ${LEN} terms = ${(allocs/1e6).toFixed(0)}M allocations in ${ms.toFixed(0)}ms`);
  console.log(`   throughput: ${(allocs/1e6/(ms/1000)).toFixed(1)}M terms/s, ${Math.round(P*M/(ms/1000))} msgs/s`);
  console.log(`   GC: ${pauses.length} pauses (minor ${kinds.minor}, major ${kinds.major}), total ${totalPause.toFixed(1)}ms = ${(100*totalPause/ms).toFixed(1)}% of wall`);
  console.log(`   pause ms: mean ${(totalPause/Math.max(1,pauses.length)).toFixed(2)}, p50 ${pct(pauses,.5).toFixed(2)}, p95 ${pct(pauses,.95).toFixed(2)}, max ${Math.max(0,...pauses).toFixed(2)}`);
}

// ---- C2: garbage throughput as live set grows toward the cap ----
{
  X.init(4000);                                  // up to 4000 rooted lists
  gc2();
  const CHURN = 50000, CLEN = 200;               // fixed garbage workload to time at each level
  const once = () => { const t = performance.now(); for (let i = 0; i < CHURN; i++) X.garbage(CLEN); return CHURN*CLEN/1e6/((performance.now()-t)/1000); };
  const measure = () => { const r = [once(), once(), once()].sort((a,b)=>a-b); return r[1]; };  // median of 3
  console.log(`C2 throughput vs live set (cap = --max-old-space-size):`);
  let slot = 0;
  for (const targetMB of [0, 30, 60, 90]) {
    try {
      while (heapMB() < targetMB && slot < 4000) { X.retain(slot++, 40000); }  // ~grow live set
      gc2();
      const tput = measure();
      console.log(`   live ~${heapMB().toFixed(0)}MB (rss ${rssMB().toFixed(0)}MB): ${tput.toFixed(1)}M terms/s`);
    } catch (e) { console.log(`   pushing past ~${heapMB().toFixed(0)}MB -> ${e.message.slice(0,40)} (hit cap)`); break; }
  }
  for (let i = 0; i < slot; i++) X.release(i);
  gc2();
}

// ---- C3: a dead process's memory persists until GC (no per-process free) ----
{
  X.init(1);
  gc2(); const before = heapMB();
  X.retain(0, 2_000_000);                         // a process's "heap": ~2M terms
  const live = heapMB();
  X.release(0);                                   // process dies: its root vanishes...
  const afterDeathNoGC = heapMB();                // ...but memory is NOT freed yet
  gc2();
  const afterGC = heapMB();
  console.log(`C3 deferred reclaim: before ${before.toFixed(0)}MB -> retained ${live.toFixed(0)}MB -> after process death (no GC) ${afterDeathNoGC.toFixed(0)}MB -> after GC ${afterGC.toFixed(0)}MB`);
  console.log(`   ${(afterDeathNoGC - before).toFixed(0)}MB stayed live after the process died; freed only at GC (vs BEAM's immediate per-process free)`);
}
