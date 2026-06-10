import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, "..");
const repo = resolve(project, "..", "..");
const conformance = resolve(repo, "conformance");
const source = resolve(conformance, "_work_realistic_order", "RealisticOrderTarget.wasm");
const destination = resolve(project, "src", "RealisticOrderTarget.wasm");

execFileSync("elixir", ["realistic_order.exs"], {
  cwd: conformance,
  stdio: "inherit"
});

mkdirSync(dirname(destination), { recursive: true });
copyFileSync(source, destination);
console.log(`Wrote ${destination}`);
