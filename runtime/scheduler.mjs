// Preemptive process scheduler on JSPI, for compiled-Elixir processes.
// Each process runs on a `promising` stack until it (a) parks at recv_wait, or (b) is
// PREEMPTED — the compiler injects a reduction-budget check at every function entry, and
// when the budget hits 0 the process calls the suspending `sched.yield`, returning control
// to the scheduler. So a CPU-bound process can't monopolize the isolate. The scheduler
// resets the budget (set_reds) before each dispatch — BEAM's "fresh reductions per schedule".
//   node --experimental-wasm-jspi scheduler.mjs <wasm> <entry> [intargs...]
import fs from "node:fs";
import { makeBig, makeMath, makeStr } from "./imports.mjs";
const [wasmPath, entry, ...intArgs] = process.argv.slice(2);
const args = intArgs.map(Number);
const BUDGET = 2000;                 // reductions per dispatch (matches the compiler default)
const DEBUG = process.env.SCHED_DEBUG === "1";

const procs = new Map();   // pid -> {fn?, mailbox, cursor, status, resolve}
const registry = new Map();// name-atom-index -> pid (named processes)
const monitors = [];       // {by, target, ref} — `by` gets {:DOWN, ref, :process, target, reason}
let nextPid = 2;           // main process is pid 1
let nextRef = 1;
let current = 0;
const toStart = [];        // child pids to start
const toResume = [];       // parked pids that got a message
const toReady = [];        // pids preempted mid-run (yielded), waiting for a turn
let mainDone = false, mainResult, dispatches = 0;

const P = () => procs.get(current);

class ProcExit extends Error {}                 // thrown by exit/1 to unwind a process
const newProc = (extra) => ({ mailbox: [], cursor: 0, status: "new", links: new Set(), trapExit: false, exitReason: null, abnormal: false, dict: new Map(), ...extra });

const imports = {
  proc: {
    spawn: (fn) => { const pid = nextPid++; procs.set(pid, newProc({ fn })); toStart.push(pid); return pid; },
    spawn_link: (fn) => { const pid = nextPid++; procs.set(pid, newProc({ fn })); procs.get(pid).links.add(current); P().links.add(pid); toStart.push(pid); return pid; },
    // spawn a process running apply(M,F,Args); optionally bidirectionally link to the spawner.
    spawn_opt: (m, f, a, link) => {
      const pid = nextPid++; procs.set(pid, newProc({ mfa: [m, f, a] }));
      if (link) { procs.get(pid).links.add(current); P().links.add(pid); }
      toStart.push(pid); return pid;
    },
    send: (pid, msg) => { const p = procs.get(pid); if (p) { p.mailbox.push(msg); if (p.status === "waiting") { p.status = "runnable"; toResume.push(pid); } } return msg; },
    self: () => current,
    set_trap_exit: (v) => { P().trapExit = v !== 0; },
    exit: (reason) => { const p = P(); p.exitReason = reason; p.abnormal = true; throw new ProcExit(); },
    register: (nameIdx, pid) => { registry.set(nameIdx, pid); },
    whereis: (nameIdx) => registry.get(nameIdx) ?? 0,            // 0 -> no process (send no-ops)
    monitor: (pid) => { const ref = nextRef++; monitors.push({ by: current, target: pid, ref }); return ref; },
    demonitor: (ref) => { for (let i = monitors.length - 1; i >= 0; i--) if (monitors[i].ref === ref) monitors.splice(i, 1); },
    // a monitor ref doubles as a reply alias (gen:call): sending to it delivers to the monitor owner.
    alias_pid: (ref) => { const m = monitors.find(m => m.ref === ref); return m ? m.by : 0; },
    recv_has: () => (P().cursor < P().mailbox.length ? 1 : 0),
    recv_cur: () => P().mailbox[P().cursor],
    recv_remove: () => { const p = P(); p.mailbox.splice(p.cursor, 1); p.cursor = 0; },
    recv_advance: () => { P().cursor++; },
    recv_wait: new WebAssembly.Suspending(() => new Promise((res) => { const p = P(); p.status = "waiting"; p.cursor = 0; p.resolve = res; })),
    // process dictionary (per-process). Keys are interned atom refs (stable identity). null = absent.
    pdict_get: (key) => P().dict.get(key) ?? null,
    pdict_put: (key, val) => { const p = P(); const old = p.dict.get(key) ?? null; p.dict.set(key, val); return old; },
  },
  // preemption: budget exhausted -> park as "ready" (still runnable), let others run
  sched: {
    yield: new WebAssembly.Suspending(() => new Promise((res) => { const p = P(); p.status = "ready"; p.resolve = res; toReady.push(current); })),
  },
  // bignum (host BigInt), floats (libm), and string/regex shims come from the shared import
  // library — one source of truth across all runners. str resolves the exports lazily (the
  // instance is created just below; the str closures only run during Wasm execution).
  big: makeBig(),
  math: makeMath(),
  str: makeStr(() => instance.exports),
};

const instance = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), imports);
const startProcess = WebAssembly.promising(instance.exports.start_process);
const startMfa = instance.exports.start_mfa && WebAssembly.promising(instance.exports.start_mfa);
const runEntry = WebAssembly.promising(instance.exports[entry]);
const setReds = instance.exports.set_reds;
const makeExit = instance.exports.make_exit;     // build {:EXIT, pid, reason} (atoms live in Wasm)
const makeDown = instance.exports.make_down;     // build {:DOWN, ref, :process, pid, reason}
const getNormal = instance.exports.get_normal;   // the :normal atom
const tick = () => Promise.resolve();
const fresh = () => { if (setReds) setReds(BUDGET); dispatches++; };

// A process died (normal return or exit/crash). Deliver exit signals along its links:
// a trapping linked process gets {:EXIT, pid, reason} in its mailbox; a non-trapping one
// is killed too if the exit was abnormal (propagation).
function finish(pid, normal) {
  const p = procs.get(pid); if (!p || p.dead) return; p.dead = true; p.status = "done";
  for (const [name, registeredPid] of registry) if (registeredPid === pid) registry.delete(name);
  const reasonRef = (p.exitReason != null) ? p.exitReason : getNormal();
  const abnormal = p.abnormal || !normal;
  for (const linked of p.links) {
    const L = procs.get(linked); if (!L || L.dead) continue;
    L.links.delete(pid);
    if (L.trapExit) {
      L.mailbox.push(makeExit(pid, reasonRef));
      if (L.status === "waiting") { L.status = "runnable"; toResume.push(linked); }
    } else if (abnormal) {
      L.abnormal = true; L.exitReason = reasonRef;
      if (L.status === "waiting" || L.status === "ready") finish(linked, false);  // propagate to a parked linker
    }
  }
  // monitors: deliver {:DOWN, ref, :process, pid, reason} to each monitoring process
  for (const m of monitors) {
    if (m.target !== pid) continue;
    const L = procs.get(m.by); if (!L || L.dead) continue;
    L.mailbox.push(makeDown(m.ref, pid, reasonRef));
    if (L.status === "waiting") { L.status = "runnable"; toResume.push(m.by); }
  }
}

function startChild(pid) {
  const p = procs.get(pid); current = pid; p.status = "running"; fresh();
  const run = p.mfa ? startMfa(p.mfa[0], p.mfa[1], p.mfa[2]) : startProcess(p.fn);
  run.then(() => finish(pid, true), () => finish(pid, false));
}
function resume(pid) {
  const p = procs.get(pid); current = pid; p.status = "running"; fresh();
  const r = p.resolve; p.resolve = null; if (r) r();
}

async function main() {
  procs.set(1, newProc({ status: "running" }));
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
  console.log(typeof mainResult === "bigint" ? mainResult.toString() : mainResult);
}
main();
