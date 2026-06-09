// demo/runner.mjs <wasm> <fixture-html> — run Resy.run() on WasmGC.
// The `http.get` host import returns the captured fixture (the single, controlled HTTP effect),
// so the Wasm sees byte-identical input to the VM. Reads the returned binary (the JS-URL list) out.
import fs from "node:fs";
import nodeCrypto from "node:crypto";
import { makeBig, makeMath, makeStr, makeCrypto, makeProcStubs, binCodec } from "../runtime/imports.mjs";
const [wasmPath, fixturePath] = process.argv.slice(2);
const fixture = fs.readFileSync(fixturePath);

const big = makeBig();
const math = makeMath();
let e;
const { wrBytes, rdBin } = binCodec(() => e);
const str = makeStr(() => e);
// the host owns the socket: Req.get!(url) -> this. Returns the captured response body, as a binary.
const http = { get: _url => wrBytes(fixture) };
// the host owns the NIF: :crypto.hash(algo, data) -> the real digest via node crypto (= OpenSSL).
const crypto = makeCrypto(() => e, nodeCrypto);
// Real Req reaches GenServer/process code (Finch's pool callbacks, kept by apply-dispatch DCE) but
// never EXECUTES it on the happy path — the adapter is overridden, so no transport/pool runs.
const { proc, sched } = makeProcStubs();

e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { big, math, str, http, crypto, proc, sched }).exports;
process.stdout.write(rdBin(e.run()));
