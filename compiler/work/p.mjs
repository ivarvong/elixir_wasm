import { readFileSync } from 'fs';
const math = Object.fromEntries(["sin","cos","sqrt","atan2"].map(k=>[k,Math[k]]));
const { instance } = await WebAssembly.instantiate(readFileSync('hav.wasm'), { math });
console.log(instance.exports.dist(33.9416,-118.4085, 40.6413,-73.7781));
