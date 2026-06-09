import { readFileSync } from 'fs';
const math = { sin: Math.sin, cos: Math.cos, sqrt: Math.sqrt, atan2: Math.atan2,
  tan: Math.tan, asin: Math.asin, acos: Math.acos, atan: Math.atan, exp: Math.exp,
  log: Math.log, log2: Math.log2, log10: Math.log10, pow: Math.pow,
  sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh, ceil: Math.ceil, floor: Math.floor };
const { instance } = await WebAssembly.instantiate(readFileSync('hav.wasm'), { math });
const dist = instance.exports.dist;
const routes = [
  ["LAX","JFK", 33.9416,-118.4085, 40.6413,-73.7781],
  ["LAX","SFO", 33.9416,-118.4085, 37.6213,-122.3790],
  ["JFK","LHR", 40.6413,-73.7781, 51.4700,-0.4543],
  ["SYD","SFO", -33.9399,151.1753, 37.6213,-122.3790],
];
for (const [a,b,la1,lo1,la2,lo2] of routes)
  console.log(`${a}->${b}: ${dist(la1,lo1,la2,lo2).toFixed(4)} nm`);
