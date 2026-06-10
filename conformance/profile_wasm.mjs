// Profile a compiled Elixir->WasmGC artifact under V8.
//
// Use with Node's CPU profiler:
//
//   node --cpu-prof --cpu-prof-name complex.cpuprofile \
//     conformance/profile_wasm.mjs \
//     conformance/_work_complex_pipeline/ComplexPipelineTarget.wasm \
//     conformance/_work_complex_pipeline/cases.json \
//     10000
//
// Open the resulting .cpuprofile in Chrome DevTools Performance tab, or upload it to speedscope.app.

import fs from "node:fs";

const [wasmPath, casesPath, iterationsArg = "1000"] = process.argv.slice(2);

if (!wasmPath || !casesPath) {
  console.error("usage: node --cpu-prof conformance/profile_wasm.mjs <module.wasm> <cases.json> [iterations]");
  process.exit(2);
}

const iterations = Number(iterationsArg);
const encoder = new TextEncoder();
const decoder = new TextDecoder();

const big = {
  from_i64: (value) => value,
  from_float: (value) => BigInt(Math.trunc(value)),
  from_str: (value) => BigInt(String(value)),
  add: (left, right) => left + right,
  sub: (left, right) => left - right,
  mul: (left, right) => left * right,
  div: (left, right) => left / right,
  rem: (left, right) => left % right,
  fits_i31: (value) => (value >= -1073741824n && value < 1073741824n ? 1 : 0),
  to_i32: (value) => Number(value),
  fits_i64: (value) => (value >= -9223372036854775808n && value <= 9223372036854775807n ? 1 : 0),
  to_i64: (value) => BigInt.asIntN(64, value),
  cmp: (left, right) => (left < right ? -1 : left > right ? 1 : 0),
  bit_length: (value) => (value === 0n ? 0 : value.toString(2).length)
};

const math = Object.fromEntries(
  [
    "sin",
    "cos",
    "tan",
    "asin",
    "acos",
    "atan",
    "sqrt",
    "exp",
    "log",
    "log2",
    "log10",
    "sinh",
    "cosh",
    "tanh",
    "ceil",
    "floor",
    "atan2",
    "pow"
  ].map((name) => [name, Math[name]])
);

let wasmExports;

function readBinary(binary) {
  const length = wasmExports.bin_len(binary);
  const bytes = new Uint8Array(length);

  for (let index = 0; index < length; index++) {
    bytes[index] = wasmExports.bin_get(binary, index);
  }

  return decoder.decode(bytes);
}

function writeBinary(input) {
  const bytes = encoder.encode(input);
  const binary = wasmExports.bin_alloc(bytes.length);

  for (let index = 0; index < bytes.length; index++) {
    wasmExports.bin_put(binary, index, bytes[index]);
  }

  return binary;
}

const str = {
  upcase: (binary) => writeBinary(readBinary(binary).toUpperCase()),
  downcase: (binary) => writeBinary(readBinary(binary).toLowerCase())
};

const startedInstantiate = performance.now();
const instance = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), { big, math, str });
wasmExports = instance.exports;
const instantiateMs = performance.now() - startedInstantiate;

const cases = JSON.parse(fs.readFileSync(casesPath, "utf8"));
const prepared = cases.map((testCase) => [
  testCase.name,
  testCase.args.map((arg) => {
    if (arg.type === "bin") return writeBinary(arg.val);
    if (arg.type === "int") return arg.val;
    throw new Error(`unsupported arg type ${arg.type}`);
  })
]);

let sink = 0n;

// Warm up outside the interesting loop so the profile is less dominated by tier-up.
for (let iteration = 0; iteration < 200; iteration++) {
  for (const [name, args] of prepared) {
    sink += BigInt(wasmExports[name](...args));
  }
}

const started = performance.now();

for (let iteration = 0; iteration < iterations; iteration++) {
  for (const [name, args] of prepared) {
    sink += BigInt(wasmExports[name](...args));
  }
}

const elapsedMs = performance.now() - started;
const calls = iterations * prepared.length;

console.log(JSON.stringify({
  wasmPath,
  casesPath,
  cases: prepared.length,
  iterations,
  calls,
  instantiate_ms: Number(instantiateMs.toFixed(3)),
  total_ms: Number(elapsedMs.toFixed(3)),
  us_per_call: Number(((elapsedMs * 1000) / calls).toFixed(3)),
  calls_per_sec: Math.round(calls / (elapsedMs / 1000)),
  sink: sink.toString().slice(-12)
}));
