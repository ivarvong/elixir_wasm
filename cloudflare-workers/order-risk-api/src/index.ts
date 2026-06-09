import wasmModule from "./RealisticOrderTarget.wasm";

const MAX_JSON_BYTES = 64 * 1024;

type WasmExports = {
  handle(input: unknown): bigint;
  bin_alloc(length: number): unknown;
  bin_put(binary: unknown, index: number, value: number): void;
  bin_len(binary: unknown): number;
  bin_get(binary: unknown, index: number): number;
};

let instance: WebAssembly.Instance | undefined;
let exportsRef: WasmExports | undefined;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function readWasmBinary(binary: unknown): string {
  const exports = getExports();
  const length = exports.bin_len(binary);
  const bytes = new Uint8Array(length);

  for (let index = 0; index < length; index++) {
    bytes[index] = exports.bin_get(binary, index);
  }

  return decoder.decode(bytes);
}

function writeWasmBinary(input: string): unknown {
  const exports = getExports();
  const bytes = encoder.encode(input);
  const binary = exports.bin_alloc(bytes.length);

  for (let index = 0; index < bytes.length; index++) {
    exports.bin_put(binary, index, bytes[index]);
  }

  return binary;
}

function getExports(): WasmExports {
  if (exportsRef) return exportsRef;

  const imports = {
    big: {
      from_i64: (value: bigint) => value,
      from_str: (value: unknown) => BigInt(String(value)),
      add: (left: bigint, right: bigint) => left + right,
      sub: (left: bigint, right: bigint) => left - right,
      mul: (left: bigint, right: bigint) => left * right,
      div: (left: bigint, right: bigint) => left / right,
      rem: (left: bigint, right: bigint) => left % right,
      fits_i31: (value: bigint) => (value >= -1073741824n && value < 1073741824n ? 1 : 0),
      to_i32: (value: bigint) => Number(value),
      cmp: (left: bigint, right: bigint) => (left < right ? -1 : left > right ? 1 : 0),
      bit_length: (value: bigint) => (value === 0n ? 0 : value.toString(2).length)
    },
    math: Object.fromEntries(
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
      ].map((name) => [name, Math[name as keyof Math] as (...args: number[]) => number])
    ),
    str: {
      upcase: (binary: unknown) => writeWasmBinary(readWasmBinary(binary).toUpperCase()),
      downcase: (binary: unknown) => writeWasmBinary(readWasmBinary(binary).toLowerCase())
    }
  } satisfies WebAssembly.Imports;

  instance = new WebAssembly.Instance(wasmModule, imports);
  exportsRef = instance.exports as unknown as WasmExports;
  return exportsRef;
}

function scoreOrder(json: string): string {
  const input = writeWasmBinary(json);
  return getExports().handle(input).toString();
}

function jsonResponse(body: unknown, init?: ResponseInit): Response {
  return Response.json(body, {
    ...init,
    headers: {
      "Cache-Control": "no-store",
      ...init?.headers
    }
  });
}

async function readBoundedJson(request: Request): Promise<string> {
  const contentLength = request.headers.get("content-length");

  if (contentLength && Number(contentLength) > MAX_JSON_BYTES) {
    throw new Response("Request body too large", { status: 413 });
  }

  const body = await request.text();
  const size = encoder.encode(body).length;

  if (size > MAX_JSON_BYTES) {
    throw new Response("Request body too large", { status: 413 });
  }

  return body;
}

const sampleOrder = {
  order_id: "ord_1001",
  customer: {
    email: "ada@example.com",
    tier: "gold",
    account_age_days: 900
  },
  address: {
    region: "US-CA"
  },
  context: {
    ip_region: "US-CA",
    attempts_24h: 1
  },
  cart: {
    promo_codes: ["WELCOME10"],
    items: [
      { sku: "SKU-BOOK", qty: 2 },
      { sku: "SKU-USB-C", qty: 3 },
      { sku: "SKU-HOODIE", qty: 1 }
    ]
  }
};

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    try {
      if (request.method === "GET" && url.pathname === "/") {
        return jsonResponse({
          service: "order-risk-api",
          routes: {
            "GET /sample": "example checkout event",
            "POST /score": "score checkout event with compiled Elixir WasmGC"
          }
        });
      }

      if (request.method === "GET" && url.pathname === "/sample") {
        return jsonResponse(sampleOrder);
      }

      if (request.method === "POST" && url.pathname === "/score") {
        const started = Date.now();
        const body = await readBoundedJson(request);
        JSON.parse(body);

        const score = scoreOrder(body);
        const elapsedMs = Date.now() - started;

        console.log(JSON.stringify({ message: "order scored", elapsedMs }));

        return jsonResponse({
          score,
          elapsed_ms: elapsedMs,
          engine: "elixir-wasmgc"
        });
      }

      return jsonResponse({ error: "Not found" }, { status: 404 });
    } catch (error) {
      if (error instanceof Response) return error;

      console.error(
        JSON.stringify({
          message: "request failed",
          error: error instanceof Error ? error.message : String(error),
          path: url.pathname
        })
      );

      return jsonResponse({ error: "Invalid order payload" }, { status: 400 });
    }
  }
} satisfies ExportedHandler;
