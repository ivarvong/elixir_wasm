import fs from "node:fs";
let ticks = 0;
const imports = { sched: { yield: new WebAssembly.Suspending(async () => { ticks++; await Promise.resolve(); }) } };
const { instance } = await WebAssembly.instantiate(new Uint8Array(fs.readFileSync("sanity.wasm")), imports);
const go = WebAssembly.promising(instance.exports.go);
console.log("calling go(5) on a promising stack; each loop iter calls a Suspending import...");
const result = await go(5);
console.log(`returned ${result}; host saw ${ticks} suspensions -> JSPI suspend/resume`, result===5 && ticks===5 ? "WORKS" : "FAIL");
