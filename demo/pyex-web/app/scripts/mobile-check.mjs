// Closed-loop mobile UX check for the pyex playground.
//
//   1. `npm run dev` (or let this script assume it's already up on :5199)
//   2. `npm run check:mobile`
//
// Drives headless Chrome at iPhone geometry against the local dev server,
// exercises boot → run → every mobile tab, saves a screenshot per state to
// scripts/shots/, and exits nonzero if any assertion fails — so UX changes
// can be iterated without deploying: edit, re-run, diff the shots.
//
// Requires the wasm at app/public/pyex.wasm (grab the production one):
//   curl --compressed -o public/pyex.wasm https://pyex.dev/pyex.wasm

import { chromium } from "playwright-core";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const BASE = process.env.PYEX_URL || "http://localhost:5199/";
const SHOTS = join(dirname(fileURLToPath(import.meta.url)), "shots");
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

// iPhone 15-ish. DPR 3 keeps the shots crisp enough to eyeball type sizes.
const PHONE = {
  viewport: { width: 393, height: 852 },
  deviceScaleFactor: 3,
  isMobile: true,
  hasTouch: true,
  userAgent:
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
};

const failures = [];
const warnings = [];
const fail = (msg) => { failures.push(msg); console.error(`  ✗ ${msg}`); };
const ok = (msg) => console.log(`  ✓ ${msg}`);
const warn = (msg) => { warnings.push(msg); console.log(`  ~ ${msg}`); };

mkdirSync(SHOTS, { recursive: true });

const browser = await chromium.launch({ executablePath: CHROME, headless: true });
const page = await browser.newContext(PHONE).then((c) => c.newPage());

const consoleErrors = [];
page.on("console", (m) => { if (m.type() === "error") consoleErrors.push(m.text()); });
page.on("pageerror", (e) => consoleErrors.push(`pageerror: ${e.message}`));

const shot = async (name) => {
  await page.screenshot({ path: join(SHOTS, `${name}.png`) });
  console.log(`  📸 ${name}.png`);
};

const noOverflow = async (where) => {
  const o = await page.evaluate(() => ({
    doc: document.documentElement.scrollWidth,
    win: window.innerWidth,
  }));
  if (o.doc > o.win) fail(`${where}: horizontal overflow (${o.doc}px doc in ${o.win}px viewport)`);
  else ok(`${where}: no horizontal overflow`);
};

const clickTab = async (name) => {
  await page.locator("nav button", { hasText: name }).last().click();
  await page.waitForTimeout(150);
};

console.log(`\npyex mobile check — ${BASE} @ ${PHONE.viewport.width}x${PHONE.viewport.height}\n`);

// ── boot ────────────────────────────────────────────────────────────────
console.log("boot:");
await page.goto(BASE, { waitUntil: "domcontentloaded" });
const runBtn = page.locator("button", { hasText: "Run" });
try {
  await page.waitForFunction(
    () => {
      const b = [...document.querySelectorAll("button")].find((x) => x.textContent.includes("Run"));
      return b && !b.disabled;
    },
    { timeout: 20000 },
  );
  ok("wasm booted, Run enabled");
} catch {
  fail("wasm did not boot within 20s (Run still disabled)");
  await shot("boot-failed");
  await browser.close();
  report();
}
await shot("01-code");
await noOverflow("code tab");

// ── run the default example ─────────────────────────────────────────────
console.log("run:");
await runBtn.click();
try {
  await page.waitForFunction(
    () => /orders|→|Error|Traceback/.test(document.body.innerText),
    { timeout: 15000 },
  );
  ok("run produced output");
} catch {
  fail("no output appeared within 15s of Run");
}
await shot("02-output");
await noOverflow("output tab");

// ── every mobile tab renders ────────────────────────────────────────────
console.log("tabs:");
for (const tab of ["files", "code", "output", "trace"]) {
  await clickTab(tab);
  const text = await page.evaluate(() => document.body.innerText);
  if (text.trim().length < 20) fail(`${tab} tab renders nearly empty`);
  else ok(`${tab} tab renders`);
}
await shot("03-trace");
await noOverflow("trace tab");

// trace rows should match the span count badge in the tab bar
const spans = await page.evaluate(() => {
  const badge = [...document.querySelectorAll("nav button")]
    .find((b) => b.textContent.includes("trace"))
    ?.textContent.replace(/\D/g, "");
  return badge ? Number(badge) : null;
});
if (spans != null && spans > 0) ok(`trace reports ${spans} spans`);
else fail("trace tab has no span count after a successful run");

await clickTab("files");
await shot("04-files");

// ── hygiene ─────────────────────────────────────────────────────────────
console.log("hygiene:");
const reactIssues = consoleErrors.filter((e) => /same key|Warning:/.test(e));
const hardErrors = consoleErrors.filter((e) => !/same key|Warning:/.test(e));
if (hardErrors.length) fail(`console errors: ${hardErrors.slice(0, 3).join(" | ").slice(0, 300)}`);
else ok("no console errors");
if (reactIssues.length) fail(`React warnings: ${reactIssues[0].slice(0, 160)}`);
else ok("no React warnings");

// tap targets: interactive controls should be ≥ 40px tall on touch (44 per HIG)
const smallTargets = await page.evaluate(() =>
  [...document.querySelectorAll("button, a")]
    .filter((e) => e.offsetParent !== null)
    .map((e) => ({ t: e.textContent.trim().slice(0, 20) || e.tagName, h: e.getBoundingClientRect().height }))
    .filter((x) => x.h > 0 && x.h < 40),
);
if (smallTargets.length)
  fail(`tap targets under 40px: ${smallTargets.map((x) => `${x.t} (${Math.round(x.h)}px)`).join(", ").slice(0, 200)}`);
else ok("all tap targets ≥ 40px");

await browser.close();
report();

function report() {
  console.log(`\n${"─".repeat(50)}`);
  if (warnings.length) console.log(`${warnings.length} warning(s) — see above`);
  if (failures.length) {
    console.error(`FAIL — ${failures.length} problem(s). Shots in ${SHOTS}`);
    process.exit(1);
  }
  console.log(`PASS — shots in ${SHOTS}`);
  process.exit(0);
}
