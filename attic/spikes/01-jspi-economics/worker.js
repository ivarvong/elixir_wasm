import mod from "process.wasm";

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

const apiPresent = typeof WebAssembly.Suspending === "function" && typeof WebAssembly.promising === "function";
let spawn = null;
if (apiPresent) {
  const recv = new WebAssembly.Suspending(recvImpl);
  const instance = new WebAssembly.Instance(mod, { env: { recv } });
  spawn = WebAssembly.promising(instance.exports.process_main);
}

export default {
  async fetch(req) {
    if (!apiPresent) {
      return new Response(JSON.stringify({
        ok: false,
        reason: "WebAssembly.Suspending/promising not present in this workerd",
        Suspending: typeof WebAssembly.Suspending,
        promising: typeof WebAssembly.promising,
      }), { headers: { "content-type": "application/json" } });
    }
    const url = new URL(req.url);
    const N = parseInt(url.searchParams.get("n") || "1000", 10);
    const M = parseInt(url.searchParams.get("m") || "0", 10);

    const inflight = new Array(N);
    for (let i = 0; i < N; i++) inflight[i] = spawn(i, 0); // run to first suspend
    const parkedAfterSpawn = parked.size;                  // expect N => all suspended

    for (let r = 0; r < M; r++) for (let i = 0; i < N; i++) deliver(i, r);
    for (let i = 0; i < N; i++) deliver(i, -1);            // sentinel -> each returns
    const counts = await Promise.all(inflight);

    return new Response(JSON.stringify({
      ok: parkedAfterSpawn === N,
      N, M, parkedAfterSpawn,
      sampleReturn: counts[0],
      total: counts.reduce((a, b) => a + b, 0),
    }), { headers: { "content-type": "application/json" } });
  },
};
