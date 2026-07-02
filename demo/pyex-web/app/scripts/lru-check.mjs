// One-off: prove the "lru cache" example (idiomatic chained assignment,
// `def __init__(self, k=None, v=None)`) runs on the wasm currently served.
import { chromium } from "playwright-core";

// The playground lives at /play/ (the root is the marketing landing page).
const ORIGIN = (process.env.PYEX_URL || "http://localhost:5199/").replace(/\/$/, "");
const BASE = `${ORIGIN}/play/`;
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const EXPECTED = ["get(1) -> 1", "get(2) -> -1", "get(1) -> -1", "get(3) -> 3", "get(4) -> 4"];

const browser = await chromium.launch({ executablePath: CHROME, headless: true });
const page = await browser.newContext({ viewport: { width: 393, height: 852 }, isMobile: true, hasTouch: true }).then((c) => c.newPage());
await page.goto(BASE, { waitUntil: "domcontentloaded" });

await page.waitForFunction(() => {
  const b = [...document.querySelectorAll("button")].find((x) => x.textContent.includes("Run"));
  return b && !b.disabled;
}, { timeout: 20000 });

await page.locator("button", { hasText: "lru cache" }).click();
await page.waitForTimeout(300);
await page.locator("button", { hasText: "Run" }).click();
await page.waitForFunction(() => /get\(4\)|Error|Traceback/.test(document.body.innerText), { timeout: 15000 });

const text = await page.evaluate(() => document.body.innerText);
await browser.close();

const missing = EXPECTED.filter((e) => !text.includes(e));
if (missing.length || /Traceback|SyntaxError/.test(text)) {
  console.error("LRU FAIL — missing:", missing, "\n", text.slice(0, 500));
  process.exit(1);
}
console.log("LRU OK — idiomatic chained-assignment example runs on the served wasm");
