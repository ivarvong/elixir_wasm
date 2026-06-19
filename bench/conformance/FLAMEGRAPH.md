# Flamegraphing Generated Wasm

Use V8 CPU profiles to flamegraph compiled Elixir/WasmGC workloads locally.

## Generate a profile

First build the workload you want to inspect:

```sh
cd bench/conformance
elixir complex_pipeline.exs
```

Then run Node with CPU profiling enabled:

```sh
node --cpu-prof --cpu-prof-name complex.cpuprofile \
  profile_wasm.mjs \
  _work_complex_pipeline/ComplexPipelineTarget.wasm \
  _work_complex_pipeline/cases.json \
  10000
```

Other useful targets:

```sh
node --cpu-prof --cpu-prof-name realistic.cpuprofile \
  profile_wasm.mjs \
  _work_realistic_order/RealisticOrderTarget.wasm \
  _work_realistic_order/cases.json \
  10000

node --cpu-prof --cpu-prof-name jason-decode.cpuprofile \
  profile_wasm.mjs \
  _work_jason_decode/JasonDecodeTarget.wasm \
  _work_jason_decode/cases.json \
  5000
```

## View it

Open the `.cpuprofile` in either:

- Chrome DevTools → Performance → Load profile
- https://www.speedscope.app/

## What to look for

Expected hot spots today:

- `term_compare` and structural equality paths.
- Map helpers such as `map_find_idx`, `map_put`, and stdlib `Map`/`:maps` iterator paths.
- Binary matching helpers such as `bits_read` and UTF-8 helpers.
- Closure/apply paths around `Enum.reduce` and `Enum.map`.
- Host BigInt imports for exact integer arithmetic.

This profiling path measures local V8 execution. It does not include Cloudflare network latency or Durable Object activation/storage time.
