# Running real Elixir on the edge

The [BEAM](https://www.erlang.org/) has spent three decades getting **soft-realtime
concurrency** right: isolated processes, preemptive scheduling, supervision trees, and
*let-it-crash* fault tolerance. Edge platforms like Cloudflare Workers offer something the
BEAM never had — instant global placement with millisecond cold starts — but only speak
WebAssembly and JavaScript.

This post walks through compiling **unmodified** Elixir libraries to WasmGC and proving the
output correct against the real VM, byte for byte.

## Why WasmGC instead of linear memory

BEAM terms are a *graph* of heap cells: cons pairs, tuples, maps, binaries, closures.
Linear-memory Wasm forces you to ship your own garbage collector and lose host interop.
WasmGC gives first-class GC structs that V8 traces natively:

- cons cells become `(struct $cons (field eq) (field eq))`
- tuples become fixed-arity GC arrays
- maps become a persistent weight-balanced tree with `O(log n)` access
- integers are three-tier: `i31ref`, an unboxed `i64` box, then host bignum

> Closed-world ahead-of-time compilation is a feature, not a limitation: with whole-program
> knowledge, function-level dead-code elimination keeps the module under the platform's
> size caps, and protocol dispatch is resolved statically.

## The verification discipline

Every change must prove itself **bit-exact** against the Elixir VM before it lands. The
harnesses are differential: the same `.beam` files run on both sides, and the outputs are
compared byte for byte.

1. `conformance/` — 185 curated cases across every term type
2. `fuzz/` — a randomized ledger service diffed with a rolling hash
3. `gaps/` — 20 realistic programs that each exercised a known gap
4. `scoreboard/` — every public function of ten stdlib modules

```elixir
def render(seed) do
  doc = article(seed) |> Jason.decode!()
  body = Earmark.as_html!(Map.get(doc, "body"))
  template(Map.get(doc, "title"), body)
end
```

The compiler is structurally honest: anything unsupported becomes a *counted trap*, never a
silently wrong value. A build that reports `STUBS: 0` is a proof obligation discharged, and
the suite count is the measurement of "any pure Elixir runs here."

### What real dependencies exercise

Real packages hit corners synthetic tests never find. Getting `Earmark` to render
byte-identically required, among other things:

| Gap | Kind | Fix |
| --- | --- | --- |
| `get_map_elements` aliasing | codegen bug | stash the source map first |
| PCRE `(?'name'...)` groups | regex shim | translate to `(?<name>...)` |
| `Kernel.struct!/2` | missing BIF | implement `maps:update/3` |
| sub-byte bitstrings | term model | a distinct `$bitstr` type |

Each one was found by a *differential probe* — staged renders on both runtimes until the
first diverging byte pointed at the instruction.

## Effects stay at the host boundary

`File.read/1` and friends lower to host imports, exactly like NIFs. On Node the host wires
the real filesystem; on Workers it wires a **virtual filesystem** backed by memory, KV, or
a Durable Object. An effect the host chooses not to provide traps honestly instead of
returning a wrong value.

The same boundary carries `:re` (regex), `:crypto` (WebCrypto), `:math` (libm), and float
formatting — each shimmed once, verified differentially, and shared by every program the
compiler emits.

## What's next

Per-process reduction budgets, partial stacktraces, and a `mix wasm.build` task that takes
any Mix project to a deployable module. The interpreter tier — a BEAM interpreter compiled
by this same compiler — lifts the last true limit: runtime code loading.

*If it's pure Elixir, it runs here — and there's a number that says so.*
