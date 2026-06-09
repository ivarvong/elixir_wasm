// Minimal cooperative process scheduler on JSPI, for compiled-Elixir processes.
// Each process runs on a `promising` stack until it parks at recv_wait (suspend); `send`
// wakes it. Single-threaded: a process runs synchronously until its next park/completion,
// so `current` is always correct. R1: FIFO+selective receive, no timeouts/links yet.
//   node --experimental-wasm-jspi runproc.mjs <wasm> <entry>   -> prints the entry's result
import fs from "node:fs";
const [wasmPath, entry, ...intArgs] = process.argv.slice(2);
const args = intArgs.map(Number);

const procs = new Map();   // pid -> {fn?, mailbox, cursor, status, resolve}
let nextPid = 2;            // main process is pid 1
let current = 0;
const toStart = [];        // child pids to start
const toResume = [];       // parked pids that have a new message
let mainDone = false, mainResult;

const P = () => procs.get(current);

const imports = { proc: {
  spawn: (fn) => { const pid = nextPid++; procs.set(pid, { fn, mailbox: [], cursor: 0, status: "new" }); toStart.push(pid); return pid; },
  send: (pid, msg) => { const p = procs.get(pid); if (p) { p.mailbox.push(msg); if (p.status === "waiting") { p.status = "runnable"; toResume.push(pid); } } return msg; },
  self: () => current,
  recv_has: () => (P().cursor < P().mailbox.length ? 1 : 0),
  recv_cur: () => P().mailbox[P().cursor],
  recv_remove: () => { const p = P(); p.mailbox.splice(p.cursor, 1); p.cursor = 0; },
  recv_advance: () => { P().cursor++; },
  recv_wait: new WebAssembly.Suspending(() => new Promise((res) => { const p = P(); p.status = "waiting"; p.cursor = 0; p.resolve = res; })),
} };

const instance = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), imports);
const startProcess = WebAssembly.promising(instance.exports.start_process);
const runEntry = WebAssembly.promising(instance.exports[entry]);
const tick = () => Promise.resolve();

function startChild(pid) {
  const p = procs.get(pid); current = pid; p.status = "running";
  startProcess(p.fn).then(() => { p.status = "done"; }, (e) => { p.status = "done"; console.error("WORKER",pid,"ERR:",e.message); });
}
function resume(pid) {
  const p = procs.get(pid); current = pid; p.status = "running";
  const r = p.resolve; p.resolve = null; if (r) r();
}

async function main() {
  procs.set(1, { mailbox: [], cursor: 0, status: "running" });
  current = 1;
  runEntry(...args).then((r) => { mainResult = r; mainDone = true; }, (e) => { mainDone = true; console.error("main error:", e); });
  // runEntry ran synchronously until main parked or completed.
  let guard = 0;
  while (!mainDone && guard++ < 5_000_000) {
    if (toStart.length) { startChild(toStart.shift()); await tick(); }
    else if (toResume.length) { resume(toResume.shift()); await tick(); await tick(); }
    else { await tick(); if (!toStart.length && !toResume.length) break; }
  }
  if (!mainDone) { console.error("DEADLOCK (no runnable processes, main not done)"); process.exit(2); }
  console.log(mainResult);
}
main();
