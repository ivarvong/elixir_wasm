// pyex-run.mjs <wasm> <source|-> — run a Python program through the compiled pyex interpreter and
// print what print() emitted, like `python`. Thin CLI over PyexSandbox; a runtime error goes to
// stderr with exit 1. Reads the program from argv[3], or from stdin when it is "-".
import fs from "node:fs";
import { PyexSandbox } from "./sandbox.mjs";

const [wasmPath, srcArg] = process.argv.slice(2);
const source = srcArg === "-" || srcArg === undefined ? fs.readFileSync(0, "utf8") : srcArg;

// 0 = pyex's default step budget (a CLI run isn't a hostile agent snippet).
const box = new PyexSandbox({ wasmPath, maxSteps: 0 });
const { ok, stdout, error } = box.run(source);

if (ok) process.stdout.write(stdout);
else {
  process.stderr.write("Traceback (pyex):\n" + error + "\n");
  process.exit(1);
}
