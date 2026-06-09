// Spike B: process lifecycle across a JSPI suspension.
//   B1  reject a parked process's promise -> Wasm unwinds, cleanup runs (kill)
//   B2  a self-`raise` (tagged Wasm throw) is caught distinctly from a kill
//   B3  abandoning a parked process (drop its refs) lets V8 reclaim the stack
// Run: node --experimental-wasm-jspi --expose-gc spikeB.mjs
import fs from "node:fs";
import wabtInit from "wabt";

const wat = fs.readFileSync(new URL("./spikeB.wat", import.meta.url), "utf8");
const wabt = await wabtInit();
const feats = { exceptions: true, gc: true, tail_call: true, function_references: true,
                reference_types: true, bulk_memory: true, multi_value: true };
const wasm = new Uint8Array(wabt.parseWat("spikeB.wat", wat, feats).toBinary({}).buffer);

const parked = new Map();   // pid -> {resolve, reject}
const mailbox = new Map();  // pid -> msg[]  (messages delivered while not parked)
const killed = [];
const raised = [];
function recvImpl(pid) {
  const q = mailbox.get(pid);
  if (q && q.length) return q.shift();
  return new Promise((resolve, reject) => parked.set(pid, { resolve, reject }));
}
function deliver(pid, msg) {
  const p = parked.get(pid);
  if (p) { parked.delete(pid); p.resolve(msg); }
  else { let q = mailbox.get(pid); if (!q) { q = []; mailbox.set(pid, q); } q.push(msg); }
}
function kill(pid, reason) { const p = parked.get(pid); if (p) { parked.delete(pid); p.reject(reason); } }

const imports = { env: {
  recv: new WebAssembly.Suspending(recvImpl),
  note_kill:  (pid) => killed.push(pid),
  note_raise: (pid) => raised.push(pid),
}};
const { instance } = await WebAssembly.instantiate(wasm, imports);
const spawn = WebAssembly.promising(instance.exports.process_main);

const gc2 = () => { global.gc(); global.gc(); };
const rssMB = () => (process.memoryUsage().rss / 1048576);
const ok = (b) => (b ? "PASS" : "FAIL");

// ---- B1: kill a process parked in receive ----
{
  const done = spawn(1, 0);                       // runs to recv(), suspends
  const wasParked = parked.has(1);
  kill(1, new Error("killed by supervisor"));     // reject the awaited promise
  const ret = await done;                         // Wasm caught it, ran cleanup, returned -1
  console.log(`B1 kill+cleanup: parkedBeforeKill=${wasParked} ret=${ret} cleanupRan=${killed.includes(1)} -> ${ok(wasParked && ret === -1 && killed.includes(1))}`);
}

// ---- B2: self-raise is caught by the process's own tag, distinct from a kill ----
{
  const done = spawn(2, 1);                       // mode 1: raise after first message
  deliver(2, 100);                                // trigger one loop iteration -> throw $elixir_raise
  const ret = await done;
  console.log(`B2 raise (own tag): ret=${ret} raiseHandled=${raised.includes(2)} notMisclassedAsKill=${!killed.includes(2)} -> ${ok(ret === -2 && raised.includes(2) && !killed.includes(2))}`);
}

// ---- B2b: normal completion still works ----
{
  const done = spawn(3, 0);
  deliver(3, 7); deliver(3, 8); deliver(3, -1);   // two messages, then sentinel
  const ret = await done;
  console.log(`B2b normal exit: ret=${ret} (expect 2) -> ${ok(ret === 2)}`);
}

// RSS rarely shrinks (V8 pools freed wasm stacks; the allocator retains pages), so a
// one-shot "reclaimed %" is meaningless. The real question for a request-per-spawn
// workload: across many generations of spawn->die, does memory PLATEAU (pooled+reused)
// or GROW (leak)? We compare the kill path (unwind to completion) vs abandonment.

async function generations(label, n, g, terminate) {
  gc2(); const base = rssMB();
  const series = [];
  for (let gen = 0; gen < g; gen++) {
    let inflight = new Array(n);
    const lo = 1_000_000 * (gen + 1);
    for (let i = 0; i < n; i++) inflight[i] = spawn(lo + i, 0);
    await Promise.resolve();
    await terminate(inflight, lo, n);   // either kill-and-await, or abandon
    inflight = null;
    gc2(); await new Promise(r => setTimeout(r, 20)); gc2();
    series.push(+(rssMB() - base).toFixed(1));
  }
  return { base, series };
}

// B3-kill: each generation spawns N, kills all (reject->unwind->complete), awaits.
{
  const N = 10000, G = 5;
  const { series } = await generations("kill", N, G, async (inflight, lo, n) => {
    for (let i = 0; i < n; i++) kill(lo + i, new Error("killed"));
    await Promise.all(inflight);       // all unwind w/ cleanup and return -1
  });
  const perGen = series.map((v, i) => i ? +(series[i] - series[i - 1]).toFixed(1) : v);
  const growthAfterFirst = series[series.length - 1] - series[0];
  console.log(`B3-kill   (unwind) RSS delta by gen MB: [${series.join(", ")}]  (each gen = ${N} procs)`);
  console.log(`   growth after gen 1: ${growthAfterFirst.toFixed(1)}MB -> ${ok(growthAfterFirst < series[0] * 0.5)} (plateaus => stacks pooled & reused)`);
}

// B3-abandon: each generation spawns N and drops refs (never settles). Expect linear growth.
{
  const N = 10000, G = 5;
  const { series } = await generations("abandon", N, G, async (inflight, lo, n) => {
    parked.clear(); mailbox.clear();   // drop resolver closures; inflight nulled by caller
  });
  const totalGrowth = series[series.length - 1] - series[0];
  console.log(`B3-abandon        RSS delta by gen MB: [${series.join(", ")}]  (each gen = ${N} procs)`);
  console.log(`   grows ~${(totalGrowth / (G - 1)).toFixed(1)}MB/gen => abandoned stacks accumulate (engine-rooted). Termination MUST unwind.`);
}
