// Preemptive process scheduler on JSPI, for compiled-Elixir processes.
// Each process runs on a `promising` stack until it (a) parks at recv_wait, or (b) is
// PREEMPTED — the compiler injects a reduction-budget check at every function entry, and
// when the budget hits 0 the process calls the suspending `sched.yield`, returning control
// to the scheduler. So a CPU-bound process can't monopolize the isolate. The scheduler
// resets the budget (set_reds) before each dispatch — BEAM's "fresh reductions per schedule".
//   node --experimental-wasm-jspi scheduler.mjs <wasm> <entry> [intargs...]
import fs from "node:fs";
import { makeBig, makeMath, makeStr, makeFs, makeIo, memFsBacking } from "./imports.mjs";
const [wasmPath, entry, ...intArgs] = process.argv.slice(2);
const args = intArgs.map(Number);
const BUDGET = 2000;                 // reductions per dispatch (matches the compiler default)
const DEBUG = process.env.SCHED_DEBUG === "1";

const procs = new Map();   // pid -> {fn?, mailbox, cursor, status, resolve, reject}
const registry = new Map();// name-atom-index -> pid (named processes)
const monitors = [];       // {by, target, ref} — `by` gets {:DOWN, ref, :process, target, reason}
let nextPid = 2;           // main process is pid 1
let nextRef = 1;
let current = 0;
// One fair FIFO run queue (FCFS) so no class of work starves another — previously toStart was
// drained fully before resumes/readies, so a spawn-heavy process could starve everyone else.
// Entries: {pid, kind:"start"|"resume"}.
const runq = [];
const enqStart = (pid) => runq.push({ pid, kind: "start" });
const enqResume = (pid) => runq.push({ pid, kind: "resume" });
let mainDone = false, mainResult, dispatches = 0;
let pendingTimers = 0;     // processes parked on a finite `receive ... after N` timer (keeps the loop alive)

const P = () => procs.get(current);

class ProcExit extends Error {}   // thrown by exit/1 to unwind a process from its own running stack
class ProcKill extends Error {}   // rejects a PARKED stack to unwind a killed process. Surfaces as a
                                  // non-$exc exception, so compiled try/rescue (which catches the $exc
                                  // tag only) can't trap it — like BEAM's untrappable exit(pid, :kill).
// Safety net: a ProcKill rejection is always consumed by the run.then(...) handler below, so it
// should never surface here; anything else that does is a real bug worth shouting about.
process.on("unhandledRejection", (e) => { if (!(e instanceof ProcKill)) console.error("BUG: unhandledRejection in process lifecycle:", e); });

const newProc = (extra) => ({ mailbox: [], cursor: 0, status: "new", links: new Set(), trapExit: false, exitReason: null, abnormal: false, dict: new Map(), resolve: null, reject: null, ...extra });

const imports = {
  proc: {
    spawn: (fn) => { const pid = nextPid++; procs.set(pid, newProc({ fn })); enqStart(pid); return pid; },
    spawn_link: (fn) => { const pid = nextPid++; procs.set(pid, newProc({ fn })); procs.get(pid).links.add(current); P().links.add(pid); enqStart(pid); return pid; },
    // spawn a process running apply(M,F,Args); optionally bidirectionally link to the spawner.
    spawn_opt: (m, f, a, link) => {
      const pid = nextPid++; procs.set(pid, newProc({ mfa: [m, f, a] }));
      if (link) { procs.get(pid).links.add(current); P().links.add(pid); }
      enqStart(pid); return pid;
    },
    send: (pid, msg) => { const p = procs.get(pid); if (p && !p.dead) { p.mailbox.push(msg); wake(pid); } return msg; },
    self: () => current,
    set_trap_exit: (v) => { P().trapExit = v !== 0; },
    exit: (reason) => { const p = P(); p.exitReason = reason; p.abnormal = true; throw new ProcExit(); },
    // exit(pid, reason): signal another process. A parked target is unwound (kill-by-unwind); a
    // trapping target instead receives {:EXIT, from, reason}. :normal to another process is a no-op.
    exit2: (pid, reason) => { signal_exit(pid, reason); return 1; },
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
    // park until a message arrives. Stash BOTH resolve (wake) and reject (kill-by-unwind): rejecting
    // the parked promise throws ProcKill into the suspended stack and unwinds it, so a killed/abnormally-
    // linked waiter frees its engine-rooted JSPI stack instead of leaking it (spike B: abandoning leaks).
    recv_wait: new WebAssembly.Suspending(() => new Promise((res, rej) => { const p = P(); p.status = "waiting"; p.cursor = 0; p.resolve = res; p.reject = rej; })),
    // receive ... after N (finite, non-zero): park up to `ms`. Returns 1 if a message arrived (resume the
    // receive scan), 0 if the timer fired first (fall through to the `after` body). A fired timer wakes the
    // process through the scheduler (sets `current`), never resolving the promise off-scheduler. (after 0
    // and after :infinity don't reach here — the compiler lowers them to fall-through and plain wait.)
    recv_wait_timeout: new WebAssembly.Suspending((ms) => new Promise((res, rej) => {
      const pid = current, p = P();
      p.status = "waiting"; p.cursor = 0; p.timedOut = false;
      p.resolve = () => res(p.timedOut ? 0 : 1);   // resume() calls this with current==pid set
      p.reject = rej;
      pendingTimers++;
      p.timer = setTimeout(() => {
        if (!p.dead && p.status === "waiting") { p.status = "ready"; p.timedOut = true; clearTimer(p); enqResume(pid); }
      }, Number(ms));
    })),
    // process dictionary (per-process). Keys are interned atom refs (stable identity). null = absent.
    pdict_get: (key) => P().dict.get(key) ?? null,
    pdict_put: (key, val) => { const p = P(); const old = p.dict.get(key) ?? null; p.dict.set(key, val); return old; },
  },
  // preemption: budget exhausted -> park as "ready" (still runnable), let others run
  sched: {
    yield: new WebAssembly.Suspending(() => new Promise((res, rej) => { const p = P(); p.status = "ready"; p.resolve = res; p.reject = rej; enqResume(current); })),
  },
  // bignum (host BigInt), floats (libm), and string/regex shims come from the shared import
  // library — one source of truth across all runners. str resolves the exports lazily (the
  // instance is created just below; the str closures only run during Wasm execution).
  big: makeBig(),
  math: makeMath(),
  str: makeStr(() => instance.exports),
  // effects ABI defaults: in-memory virtual fs + real console (unused imports are ignored)
  fs: makeFs(() => instance.exports, memFsBacking()),
  io: makeIo(() => instance.exports),
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

// Cancel a process's pending `receive ... after N` timer (idempotent; keeps pendingTimers balanced).
function clearTimer(p) { if (p.timer) { clearTimeout(p.timer); p.timer = null; pendingTimers--; } }

// Make a waiting process runnable on a message/signal: cancel any timer, enqueue for resume. The
// single place every "a message arrived for a parked waiter" path goes through, so timers can't leak.
function wake(pid) {
  const p = procs.get(pid);
  if (!p || p.dead || p.status !== "waiting") return;
  p.status = "runnable"; clearTimer(p); enqResume(pid);
}

// Unwind a parked process's engine-rooted JSPI stack by rejecting the promise it suspended on.
// Throws ProcKill at the suspend point; not caught by compiled try/rescue (which catches $exc only),
// so it propagates out -> the process's run promise rejects -> finish(pid,false) (a no-op by then,
// since finish already marked it dead). No-op if the process isn't currently parked.
function unwindParked(p) {
  clearTimer(p);
  const rej = p.reject;
  if (rej) { p.resolve = null; p.reject = null; rej(new ProcKill()); }
}

// Deliver an exit signal from `current` to `pid` (erlang:exit/2 semantics).
function signal_exit(pid, reason) {
  const p = procs.get(pid); if (!p || p.dead) return;
  if (p.trapExit) {                                 // trapping: becomes a message, process survives
    p.mailbox.push(makeExit(current, reason));
    wake(pid);
  } else if (reason !== getNormal()) {              // exit(pid, :normal) to a non-trapping proc is a no-op
    p.exitReason = reason; p.abnormal = true; finish(pid, false);
  }
}

// A process died (normal return or exit/crash). Unwind its parked stack if any, then deliver exit
// signals along its links: a trapping linked process gets {:EXIT, pid, reason} in its mailbox; a
// non-trapping one is killed too if the exit was abnormal (propagation).
function finish(pid, normal) {
  const p = procs.get(pid); if (!p || p.dead) return; p.dead = true; p.status = "done";
  unwindParked(p);                                  // free an engine-rooted suspended stack, don't abandon it
  for (const [name, registeredPid] of registry) if (registeredPid === pid) registry.delete(name);
  const reasonRef = (p.exitReason != null) ? p.exitReason : getNormal();
  const abnormal = p.abnormal || !normal;
  for (const linked of p.links) {
    const L = procs.get(linked); if (!L || L.dead) continue;
    L.links.delete(pid);
    if (L.trapExit) {
      L.mailbox.push(makeExit(pid, reasonRef));
      wake(linked);
    } else if (abnormal) {
      L.abnormal = true; L.exitReason = reasonRef;
      finish(linked, false);  // propagate; finish() unwinds the linker if it's parked (no leak)
    }
  }
  // monitors: deliver {:DOWN, ref, :process, pid, reason}, then prune spent entries so a long-lived
  // scheduler doesn't accumulate them. A monitor of `pid` fires; a monitor HELD BY `pid` is dropped
  // (it can never fire to a now-dead owner) — both match BEAM's monitor cleanup on process death.
  for (let i = monitors.length - 1; i >= 0; i--) {
    const m = monitors[i];
    if (m.target === pid) {
      monitors.splice(i, 1);
      const L = procs.get(m.by); if (!L || L.dead) continue;
      L.mailbox.push(makeDown(m.ref, pid, reasonRef));
      wake(m.by);
    } else if (m.by === pid) {
      monitors.splice(i, 1);
    }
  }
  // Free the dead process's bookkeeping record. Its JSPI stack was already unwound above; dropping the
  // record too keeps a long-lived scheduler (a supervisor churning workers) from accumulating dead
  // {mailbox, links, dict} objects. send/whereis to a missing pid already no-op, so this is safe.
  procs.delete(pid);
}

function startChild(pid) {
  const p = procs.get(pid); if (!p || p.dead) return; current = pid; p.status = "running"; fresh();
  const run = p.mfa ? startMfa(p.mfa[0], p.mfa[1], p.mfa[2]) : startProcess(p.fn);
  run.then(() => finish(pid, true), () => finish(pid, false));
}
function resume(pid) {
  const p = procs.get(pid); if (!p || p.dead) return;   // killed while queued -> skip the dispatch
  current = pid; p.status = "running"; fresh();
  const r = p.resolve; p.resolve = null; p.reject = null; if (r) r();
}

async function main() {
  procs.set(1, newProc({ status: "running" }));
  current = 1; fresh();
  runEntry(...args).then((r) => { mainResult = r; mainDone = true; }, (e) => { mainDone = true; console.error("main error:", e); });
  // A resumed/started stack runs on microtasks and may take a few turns to park or yield
  // again. So only declare deadlock when the run queue is empty AND nothing is mid-flight.
  const anyRunning = () => { for (const p of procs.values()) if (p.status === "running") return true; return false; };
  let guard = 0;
  while (!mainDone && guard++ < 200_000_000) {
    if (runq.length) { const job = runq.shift(); if (job.kind === "start") startChild(job.pid); else resume(job.pid); await tick(); }
    else if (anyRunning()) await tick();    // a dispatched stack is still settling on microtasks
    else if (pendingTimers > 0) await new Promise((r) => setTimeout(r, 0));  // idle: let a receive-after timer fire
    else break;                             // truly nothing left to do
  }
  if (!mainDone) { console.error("DEADLOCK (no runnable processes, main not done)"); process.exit(2); }
  if (DEBUG) console.error(`[sched] ${dispatches} dispatches`);
  // Optional leak check (run with `node --expose-gc` and SCHED_MEM=1): after the run, GC and report
  // live heap + lingering process records. With kill-by-unwind + record cleanup this stays flat as the
  // number of spawned-then-killed processes grows; a stack/record leak would make it grow with N.
  if (process.env.SCHED_MEM === "1" && global.gc) { global.gc(); global.gc(); console.error(`HEAP_USED ${process.memoryUsage().heapUsed} LIVE_PROCS ${procs.size}`); }
  console.log(typeof mainResult === "bigint" ? mainResult.toString() : mainResult);
}
main();
