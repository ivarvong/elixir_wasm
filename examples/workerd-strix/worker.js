// Compiled Elixir (Strix: string processing) running on workerd.
// strix.wasm was produced by: real Elixir -> :beam_disasm -> beam2wasm.exs -> Binaryen.
// No runtime Wasm compilation: the module is instantiated once with `new WebAssembly.Instance`.
import strixModule from "strix.wasm";

// One instance per isolate. The WasmGC exports include the compiled Elixir functions
// (upcase/1, count/3, len/2) plus the binary JS-bridge helpers the compiler emits.
const e = new WebAssembly.Instance(strixModule, {}).exports;

const enc = new TextEncoder();
const dec = new TextDecoder();

// Build a WasmGC $binary term from a JS string (the bridge: bin_alloc + bin_put).
function toBin(s) {
  const bytes = enc.encode(s);
  const b = e.bin_alloc(bytes.length);
  for (let i = 0; i < bytes.length; i++) e.bin_put(b, i, bytes[i]);
  return b;
}
// Read a WasmGC $binary term back into a JS string (bin_len + bin_get).
function fromBin(b) {
  const n = e.bin_len(b);
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) out[i] = e.bin_get(b, i);
  return dec.decode(out);
}

export default {
  async fetch(req) {
    const url = new URL(req.url);
    const op = url.searchParams.get("op") || "upcase";
    const s = url.searchParams.get("s") ?? "";
    let result;
    switch (op) {
      case "upcase":               // Strix.upcase(s)  -> binary
        result = fromBin(e.upcase(toBin(s)));
        break;
      case "len":                  // Strix.len(s, 0)  -> integer (byte length)
        result = e.len(toBin(s), 0);
        break;
      case "count": {              // Strix.count(s, byte, 0) -> integer
        const ch = (url.searchParams.get("c") || "a").charCodeAt(0);
        result = e.count(toBin(s), ch, 0);
        break;
      }
      default:
        return new Response(JSON.stringify({ error: `unknown op ${op}` }), { status: 400 });
    }
    return new Response(JSON.stringify({ op, input: s, result }) + "\n", {
      headers: { "content-type": "application/json" },
    });
  },
};
