// Preemptive process scheduler on JSPI, for compiled-Elixir processes.
// Each process runs on a `promising` stack until it (a) parks at recv_wait, or (b) is
// PREEMPTED — the compiler injects a reduction-budget check at every function entry, and
// when the budget hits 0 the process calls the suspending `sched.yield`, returning control
// to the scheduler. So a CPU-bound process can't monopolize the isolate. The scheduler
// resets the budget (set_reds) before each dispatch — BEAM's "fresh reductions per schedule".
//   node --experimental-wasm-jspi scheduler.mjs <wasm> <entry> [intargs...]
import fs from "node:fs";
const [wasmPath, entry, ...intArgs] = process.argv.slice(2);
const args = intArgs.map(Number);
const BUDGET = 2000;                 // reductions per dispatch (matches the compiler default)
const DEBUG = process.env.SCHED_DEBUG === "1";

const procs = new Map();   // pid -> {fn?, mailbox, cursor, status, resolve}
let nextPid = 2;            // main process is pid 1
let current = 0;
const toStart = [];        // child pids to start
const toResume = [];       // parked pids that got a message
const toReady = [];        // pids preempted mid-run (yielded), waiting for a turn
let mainDone = false, mainResult, dispatches = 0;

const P = () => procs.get(current);

const imports = {
  proc: {
    spawn: (fn) => { const pid = nextPid++; procs.set(pid, { fn, mailbox: [], cursor: 0, status: "new" }); toStart.push(pid); return pid; },
    send: (pid, msg) => { const p = procs.get(pid); if (p) { p.mailbox.push(msg); if (p.status === "waiting") { p.status = "runnable"; toResume.push(pid); } } return msg; },
    self: () => current,
    recv_has: () => (P().cursor < P().mailbox.length ? 1 : 0),
    recv_cur: () => P().mailbox[P().cursor],
    recv_remove: () => { const p = P(); p.mailbox.splice(p.cursor, 1); p.cursor = 0; },
    recv_advance: () => { P().cursor++; },
    recv_wait: new WebAssembly.Suspending(() => new Promise((res) => { const p = P(); p.status = "waiting"; p.cursor = 0; p.resolve = res; })),
  },
  // preemption: budget exhausted -> park as "ready" (still runnable), let others run
  sched: {
    yield: new WebAssembly.Suspending(() => new Promise((res) => { const p = P(); p.status = "ready"; p.resolve = res; toReady.push(current); })),
  },
};

const instance = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), imports);
const startProcess = WebAssembly.promising(instance.exports.start_process);
const runEntry = WebAssembly.promising(instance.exports[entry]);
const setReds = instance.exports.set_reds;
const tick = () => Promise.resolve();
const fresh = () => { if (setReds) setReds(BUDGET); dispatches++; };

function startChild(pid) {
  const p = procs.get(pid); current = pid; p.status = "running"; fresh();
  startProcess(p.fn).then(() => { p.status = "done"; }, (e) => { p.status = "done"; console.error("WORKER",pid,"ERR:",e.message||e); });
}
function resume(pid) {
  const p = procs.get(pid); current = pid; p.status = "running"; fresh();
  const r = p.resolve; p.resolve = null; if (r) r();
}

async function main() {
  procs.set(1, { mailbox: [], cursor: 0, status: "running" });
  current = 1; fresh();
  runEntry(...args).then((r) => { mainResult = r; mainDone = true; }, (e) => { mainDone = true; console.error("main error:", e); });
  // A resumed/started stack runs on microtasks and may take a few turns to park or yield
  // again. So only declare deadlock when every queue is empty AND nothing is mid-flight.
  const anyRunning = () => { for (const p of procs.values()) if (p.status === "running") return true; return false; };
  let guard = 0;
  while (!mainDone && guard++ < 200_000_000) {
    if (toStart.length) startChild(toStart.shift());
    else if (toResume.length) resume(toResume.shift());
    else if (toReady.length) resume(toReady.shift());
    else if (!anyRunning()) break;          // truly nothing left to do
    await tick();
  }
  if (!mainDone) { console.error("DEADLOCK (no runnable processes, main not done)"); process.exit(2); }
  if (DEBUG) console.error(`[sched] ${dispatches} dispatches`);
  console.log(mainResult);
}
main();
