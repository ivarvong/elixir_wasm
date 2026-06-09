# Cold-start cost of the compiled-Elixir WasmGC module

Two distinct costs, often conflated:
- **compile** — V8 compiles the module's bytecode. Paid **once per isolate**, at startup.
- **instantiate** — `new WebAssembly.Instance(module)`: fresh globals/GC roots/function table.
  Paid **per Durable Object construction** (every cold DO in a warm isolate).

## Engine-level (Node, precise ns timers; V8 = the engine workerd runs)
Measured over the real pipeline (Elixir → :beam_disasm → beam2wasm → Binaryen); big* modules are
generated Elixir compiled through the same path to get a size→time curve.

| module    |   size | compile p50 | compile p99 | instantiate p50 | instantiate p99 |
|-----------|-------:|------------:|------------:|----------------:|----------------:|
| Smoke     |  1.0KB |     17.6 µs |    144 µs   |        7.5 µs   |       47 µs     |
| Expr      |  1.7KB |     24.2 µs |    259 µs   |        6.4 µs   |       30 µs     |
| account   |  2.2KB |     26.2 µs |     85 µs   |        9.5 µs   |       63 µs     |
| big250    |   32KB |    192 µs   |   1292 µs   |       45 µs     |       88 µs     |
| big1000   |  128KB |    715 µs   |   1127 µs   |      162 µs     |      253 µs     |
| big3000   |  384KB |   1849 µs   |   2790 µs   |      439 µs     |     3630 µs     |

**Slopes:** compile ≈ **5 µs/KB**, instantiate ≈ **1 µs/KB** (plus a ~6–10 µs fixed floor).

**Extrapolation to a realistic deployed module.** Spike A put a gen_server actor closure near ~1 MB raw
Wasm. At these slopes: cold **compile ≈ 5 ms** (once per isolate), **instantiate ≈ ~1 ms** (per DO).

## workerd-native (in-isolate, the actual target runtime)
- Instantiation: **9.67 µs** per `new WebAssembly.Instance` (n=3000) — matches the V8/Node number
  exactly. (Timers confirmed usable in workerd, i.e. not frozen within a request.)
- End-to-end HTTP latency:
  - cold DO (new instance): **~10 ms** (after the one-time ~62 ms first-ever isolate spin-up)
  - warm DO (repeat hits): **~3 ms**

## Verdict
The compiled-Elixir module is **not** the cold-start bottleneck. Per-DO instantiation is ~10 µs
(workerd-confirmed); the ~7 ms cold-vs-warm DO gap is storage/disk setup that any DO app pays
regardless of language; isolate spin-up (~tens of ms, one-time) dominates a true cold start. Even a
realistic ~1 MB module adds ~5 ms compile (amortized across the isolate's whole lifetime) and ~1 ms
instantiate. The language choice costs microseconds-to-low-milliseconds, in the noise of the platform.
