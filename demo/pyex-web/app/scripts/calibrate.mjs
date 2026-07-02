// Calibrate /api/run's step + CPU budgets against the WasmGC memory death line.
//
//   node scripts/calibrate.mjs deaths     # LOCAL: find the isolate-death step count per
//                                         # allocation shape (spawns its own wrangler dev,
//                                         # restarts it after every kill)
//   node scripts/calibrate.mjs timing     # PROD (or PYEX_URL): wall-time vs steps at safe
//                                         # budgets -> ms/step on real metal, from outside
//                                         # (Workers freeze time internally; reported ms is 0)
//
// Why two halves: memory-per-step is deterministic, so death lines found locally transfer
// to production (same 128 MB isolate cap). CPU-per-step does NOT transfer across hardware,
// so it's measured against production differentially: slope of wall time over step budget,
// with the RTT baseline as intercept.
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";

const MODE = process.argv[2] || "timing";
const PORT = 8901;
const LOCAL = `http://localhost:${PORT}`;
const PROD = (process.env.PYEX_URL || "https://pyex.dev").replace(/\/$/, "");

// Allocation shapes: memory cost per step differs wildly, so the safe cap is the
// MINIMUM death line across shapes, not the int-loop's flattering number.
const SHAPES = {
  int_loop:    "i = 0\nwhile True:\n    i += 1",
  bignum_fib:  "a = b = 1\nwhile True:\n    a, b = b, a + b",
  str_concat:  's = ""\nwhile True:\n    s += "xxxxxxxxxxxxxxxx"',
  list_append: "xs = []\nwhile True:\n    xs.append(len(xs))",
  dict_grow:   "d = {}\nn = 0\nwhile True:\n    d[n] = n\n    n += 1",
  nested_data: 'xs = []\nwhile True:\n    xs.append({"k": [1, 2, 3], "s": "abc"})',
  gen_drain:   "def f():\n    n = 0\n    while True:\n        yield n\n        n += 1\ng = f()\nprint(next(g))",
  fstr_churn:  's = ""\nn = 0\nwhile True:\n    s = f"value {n}"\n    n += 1',
};

async function run(base, code, steps, timeoutMs = 60_000) {
  const t0 = performance.now();
  try {
    const res = await fetch(`${base}/api/run`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code, max_steps: steps }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const wall = performance.now() - t0;
    const text = await res.text();
    try {
      const j = JSON.parse(text);
      return { outcome: j.ok ? "ok" : /LimitError/.test(j.error) ? "limit" : "pyerr", wall, detail: j.error };
    } catch {
      return { outcome: "DEAD", wall, detail: `${res.status} ${text.slice(0, 60)}` };
    }
  } catch (e) {
    return { outcome: "DEAD", wall: performance.now() - t0, detail: String(e).slice(0, 80) };
  }
}

// ── deaths (local) ───────────────────────────────────────────────────────
let dev = null;
async function startDev() {
  dev?.kill("SIGKILL");
  dev = spawn("npx", ["wrangler", "dev", "--port", String(PORT), "--var", "MAX_STEPS_OVERRIDE:50000000"], {
    cwd: new URL("../../worker", import.meta.url).pathname,
    stdio: "ignore",
    env: { ...process.env, ASDF_NODEJS_VERSION: "22.15.0" },
  });
  for (let i = 0; i < 60; i++) {
    await sleep(1000);
    try {
      const r = await fetch(`${LOCAL}/api/health`, { signal: AbortSignal.timeout(2000) });
      if (r.ok) return;
    } catch { /* not up yet */ }
  }
  throw new Error("wrangler dev did not become healthy");
}

async function deaths() {
  await startDev();
  const LADDER = [100_000, 200_000, 300_000, 400_000, 600_000, 900_000, 1_400_000, 2_000_000, 3_000_000];
  const results = {};
  for (const [name, code] of Object.entries(SHAPES)) {
    let lastSafe = 0, died = null;
    for (const steps of LADDER) {
      const r = await run(LOCAL, code, steps);
      process.stdout.write(`${name} @ ${steps / 1000}k: ${r.outcome} (${Math.round(r.wall)}ms)\n`);
      if (r.outcome === "DEAD") { died = steps; await startDev(); break; }
      lastSafe = steps;
    }
    results[name] = { lastSafe, died };
  }
  dev?.kill("SIGKILL");
  console.log("\nshape          last-safe   died-at");
  for (const [n, r] of Object.entries(results)) {
    console.log(`${n.padEnd(14)} ${String(r.lastSafe / 1000 + "k").padStart(8)}   ${r.died ? r.died / 1000 + "k" : "survived ladder"}`);
  }
  const floor = Math.min(...Object.values(results).map((r) => r.died ?? Infinity));
  console.log(`\nlowest death line: ${floor === Infinity ? "none hit" : floor / 1000 + "k"} — recommended cap ≈ half of that`);
}

// ── timing (prod) ────────────────────────────────────────────────────────
async function timing() {
  // RTT baseline: trivial program, minimum of several runs
  const rtts = [];
  for (let i = 0; i < 6; i++) rtts.push((await run(PROD, "pass", 1000)).wall);
  const rtt = Math.min(...rtts);
  console.log(`baseline RTT+dispatch (min of 6): ${Math.round(rtt)}ms\n`);

  const BUDGETS = [50_000, 100_000, 150_000, 200_000, 250_000, 300_000];
  console.log("shape          " + BUDGETS.map((b) => String(b / 1000 + "k").padStart(8)).join("") + "   ms/step (fit)");
  let worst = 0;
  for (const [name, code] of Object.entries(SHAPES)) {
    const walls = [];
    for (const b of BUDGETS) {
      const r = await run(PROD, code, b);
      walls.push(r.outcome === "DEAD" ? NaN : r.wall);
    }
    // least-squares slope of wall over steps
    const pts = BUDGETS.map((b, i) => [b, walls[i]]).filter(([, w]) => !Number.isNaN(w));
    const n = pts.length, sx = pts.reduce((a, [x]) => a + x, 0), sy = pts.reduce((a, [, y]) => a + y, 0);
    const sxx = pts.reduce((a, [x]) => a + x * x, 0), sxy = pts.reduce((a, [x, y]) => a + x * y, 0);
    const slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    worst = Math.max(worst, slope);
    console.log(name.padEnd(15) + walls.map((w) => (Number.isNaN(w) ? "DEAD".padStart(8) : String(Math.round(w)).padStart(8))).join("") + `   ${(slope * 1000).toFixed(2)} µs`);
  }
  console.log(`\nworst slope: ${(worst * 1000).toFixed(2)} µs/step`);
  console.log(`=> at a 300k cap, worst-case run ≈ ${Math.round(worst * 300_000)}ms CPU`);
  console.log(`=> cpu_ms budget ≈ worst-case × 2 + ~500ms boot headroom`);
}

if (MODE === "deaths") await deaths();
else await timing();
