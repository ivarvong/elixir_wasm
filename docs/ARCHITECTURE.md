# Architecture & design decisions

This is the *why*. It captures the design of this experiment — the compiler and its runtime — and every
standing decision made during design, with rationale, so contributors inherit intent rather than
reconstructing it from code. Each decision is tagged `[D]`. Where the prototype validated or revised a
decision, that is noted.

---

## 1. Vision and product framing

Run Elixir/BEAM programs on Cloudflare Workers. Workers forbids runtime Wasm compilation and has no
long-lived OS threads or processes, so a faithful port of the BEAM *emulator* is a poor fit. Instead:

`[D]` **Target a specific, defensible product first: durable, single-owner, strongly-consistent state
machines at the edge** — order lifecycles, idempotent payments, per-account ledgers. Pitch: "Durable
Objects with OTP discipline." This survives the strongest critique (see §14) because the workloads it
wins at — one logical owner per entity, modest compute, event-coordinated, durable, auditable, small
state — are exactly where Workers + an OTP programming model beat both raw TypeScript Durable Objects and
a full BEAM node. It deliberately does **not** target BEAM's massive-soft-realtime-connection strength
(LiveView, millions of cheap processes), where the runtime tradeoffs below are weakest.

Name it precisely in external materials: an **"Elixir-flavored durable edge runtime,"** not "the BEAM on
Workers." The deltas (below and in `attic/spikes/`) are stated honestly.

---

## 2. Why WasmGC (and why not Rust/Zig/linear-memory)

`[D]` **Compile to WasmGC, not linear-memory Wasm.** BEAM terms are a graph of heap cells (cons cells,
tuples, maps, closures, bignums). WasmGC gives first-class GC structs/arrays/i31 that **share V8's heap
and collector** — verified in spike C: WasmGC objects are collected by V8 with sub-millisecond,
non-stop-the-world pauses. A linear-memory VM would have to ship and tune its own GC inside a 128MB cap.

`[D]` **Do not write the runtime in Rust/C/Zig.** Those target *linear-memory* Wasm; using them fights
the WasmGC-native term model (you'd reintroduce a manual heap + GC). The runtime ships as **WasmGC
emitted by our own compiler** plus a small amount of hand-written WAT for the term library and helpers.
Rust/Zig would only make sense if we abandoned WasmGC for a linear-memory interpreter — rejected. (An
early `workers-zig` exploration confirmed the mismatch and was dropped.)

`[D]` **The build-time compiler is written in Elixir.** It is a Mix-style pass over OTP's own tooling
(`:beam_disasm`, and ultimately `beam_ssa`). This reuses OTP's compiler frontend, integrates with the
normal Elixir build, and dogfoods the language. The host shim (the JS/TS glue around an instantiated
module) is TypeScript.

---

## 3. The frontend seam: take over at `.beam`, don't reimplement Elixir

`[D]` **Run the real Elixir/Erlang compiler at build time and take over at the low IR.** We do *not*
re-implement Elixir's parser, macro expander, or typechecker. We let `elixirc` produce `.beam`, then
consume the symbolic BEAM instructions via **`:beam_disasm`** and lower them to WasmGC.

This was the single biggest simplification, validated in the prototype:
- `:beam_disasm` returns clean symbolic instructions (`{:test, :is_ge, ...}`, `{:put_map_assoc, ...}`,
  calls as `{M,F,A}`), and **normalizes typed registers** — so we ingest *default* Elixir output with no
  special compile flags. (An earlier hand-rolled `.beam` byte-decoder needed `+no_type_opt`; deleting it
  removed that constraint. See `attic/spikes/04-beam-loader-smoketest` for the from-scratch loader that proved
  the format, now superseded by `:beam_disasm`.)
- `:beam_disasm` also **decodes literals to real terms** and **exposes BEAM's type analysis** (typed
  registers like `{:tr, {:x,0}, {t_integer,...}}`) — both of which we exploit (literal materialization;
  and the path to type-driven specialization for bignums, §5).

---

## 4. Closed-world / precompilation is mandatory — and embraced

Workers forbids runtime Wasm compilation, so all code must be compiled ahead of time into one module.

`[D]` **Treat closed-world as a feature, not a constraint.** It unlocks:
- a **fixed atom table** (atoms → integer indices, interned as constants);
- **static dispatch / devirtualization** of most calls;
- **dead-code elimination** — the *intended* lever for staying under the Workers ~10MB cap. Honest
  status (measured the hard way): the DCE is **sound but imprecise**. It prunes self-contained code
  cleanly (mergesort + 12 unrelated modules → byte-identical output), but a single protocol call
  (`to_string`) reaches the consolidated dispatch, which statically links *every* impl — so for real
  protocol/dispatch-heavy programs it keeps ~everything (`N of N`). **Today, small builds come from
  curating the fed beams** (consolidated protocols + a trimmed stdlib), not from DCE precision. A
  robust whole-program devirtualizing DCE (RTA/0-CFA — the bridge is diagnosed, the gate ~built) is
  the real unbuilt work here, tracked in `LIMITATIONS.md` §3;
- **deletion of hot-code-loading machinery** from the base runtime.

Costs, stated plainly:
- no native hot reload (recovered via the tiered runtime, §12);
- `apply/3` only to compiled-in code; no `Code.eval_string`, no runtime-loaded modules/plugins (without
  the interpreter tier);
- heavier builds; loss of live BEAM introspection.

`[D]` **Draw the dynamic-dispatch boundary explicitly** and ship "compiled-closure-only `apply`" as a
documented language delta.

---

## 5. Term representation (WasmGC types)

The prototype uses this exact representation (see `beam2wasm.exs`):

| Erlang term | WasmGC representation |
|-------------|------------------------|
| small integer | `i31ref` (unboxed, ±2^30) |
| big integer | `(struct $big (field externref))` — a boxed **JS BigInt**; arbitrary precision |
| cons cell | `(struct $cons (ref null eq) (ref null eq))` |
| `[]` (nil) | `(ref.null none)` |
| tuple | `(array (ref null eq))` via `array.new_fixed` |
| atom | `(struct $atom (field i32))`, **interned once per distinct atom** as a global |
| map | a **persistent weight-balanced BST** (Adams' algorithm) of `$mnode` (key/val/left/right/size); O(log n) get/put |

Key design points:
- `[D]` **A map is a BST, not a bare array.** (The prototype started with a flat `[k0,v0,…]` array — O(n)
  per op, O(n²) bulk build; the perf harness caught it and it was replaced with a weight-balanced BST:
  ~168× faster at 10k keys, see `perf/README.md`.) The struct/node type also gives `is_map` and `is_tuple`
  distinct `ref.test` targets so they don't collide.
- `[D]` **Map iteration order is key-sorted** (in-order BST walk). This is a *deliberate, documented delta*
  from BEAM, which iterates ≤32-key maps in term order (agrees with us) but **>32-key maps in 16-ary HAMT
  hash order** (an internal-hash implementation detail, not stable across OTP versions). Elixir documents map
  order as *unspecified*; programs must not depend on it. This is the one boundary worth knowing — it was the
  root cause of the one apparent "compiler lie" in the gap corpus (a program ranked a >32-key frequency map by
  a non-total key); see `gaps/FINDINGS.md`.
- `[D]` **Equality is `ref.eq`** for the fast path (i31 value-eq; interned-atom identity-eq), with a
  `$term_compare` fallback for everything else. Bignum equality is **done**: rank-0 numbers route through a
  tiered `$int_cmp` that delegates boxed values to the host `big.cmp` import, so two distinct equal-valued
  `$big` structs compare equal.
- `[D]` **Integers are arbitrary-precision and exact** (fintech requirement), and this is now the **default**
  (set `BIGNUM=0` only for compiler experiments that want wrapping small-int arithmetic). Three tiers: `i31`
  fast path → a `$i64` struct for 64-bit-fitting values → a boxed host BigInt beyond that, demoting again when
  a result fits. `fact(50)` (65 digits) is bit-identical to the Elixir VM. Type-driven specialization is also
  in: where `:beam_disasm`'s typed-register info proves an operand is a bounded small integer, the compiler
  emits inline i32 and skips the tiered call — exact by default, fast by analysis.

---

## 6. The compiler

The compiler is a small Elixir **library** under `lib/`: `Codegen.Common` (shared leaf helpers),
`Codegen.Runtime` (the hand-written WAT runtime library), `Codegen.Emit` (the per-function BEAM→WAT emit
path — `compile_fun` + helpers), and `Beam2Wasm` (the `run/1` orchestration: disasm, DCE, atom interning,
closures, exports) — with `beam2wasm.exs` a thin CLI shim so `elixir beam2wasm.exs <beams>` still
works. (It began as one ~320-line script and grew to ~3,740; the modules were extracted via AST call-graph
analysis with `import`, keeping the output **byte-identical** — verified across all 109 harness programs.
The repo root is the published Hex package — `mix.exs`, `lib/`, `test/`, `priv/`.) It reads one or more `.beam` files via
`:beam_disasm`, merges their functions into one WasmGC module, and emits WAT.

Lowering strategy:
- **Each BEAM function → one Wasm function.**
- **Goto-style control flow → a `br_table` block-dispatch loop.** Labels become block indices; a `$blk`
  local holds the current target; jumps set `$blk` and `br $dispatch`.
- **Y-registers → Wasm locals.** `allocate`/`deallocate`/`test_heap`/`init_yregs` are no-ops (locals are
  persistent; the host owns GC). **`trim` is *not* a no-op** — it renumbers Y registers; we resolve it
  statically per block (drop the `trim`, shift subsequent `yK → y(K+N)`). This was a real bug found by
  running, not reading.
- **Calls → Wasm calls** using `:beam_disasm`'s `{M,F,A}`; cross-module calls arrive as `call_ext*` and
  resolve to the same flat `$fun_arity` names (so multiple modules merge cleanly). Tail calls
  (`call_only`/`call_last`/`call_ext_last`) → `return (call …)`.

Opcode coverage (what the prototype handles): `move`, `gc_bif (+,-,*)`, the `is_*` tests
(`is_eq_exact/is_eq/is_ne*/is_lt/is_ge/is_nonempty_list/is_nil/is_tuple/is_map/test_arity`),
`select_val`, `select_tuple_arity`, list ops (`get_list/get_hd/get_tl/put_list`), tuple ops
(`put_tuple2/get_tuple_element`), map ops (`get_map_elements/put_map_assoc/put_map_exact`), `swap`,
`call`/`call_only`/`call_last` + `call_ext*`, `jump`, `return`, literal materialization (ints/atoms/
lists/tuples/maps), and the error terminators (`func_info/badmatch/case_end/if_end` → `unreachable`).
Each new program surfaced a few more real opcodes; this is the actual surface of *optimized* Elixir
output, not a toy subset.

Env-var modes:
- `BIGNUM` — exact tiered integers are **on by default**; set `BIGNUM=0` for wrapping small-int arithmetic.
- `REDS=<budget>` — reduction-check budget at each function entry (preemption, §8).
- `STUB=1` — unsupported opcodes/operands compile to a counted `(unreachable)` trap instead of failing the
  build (the gap/conformance harnesses use this to *measure* coverage; an untranslated operand traps and is
  counted, never silently produces a wrong value).
- `EXPORTS="name:argtypes->ret; …"` — generate host-callable export wrappers (int/float/atom/bin/list/term).

Much of the original "not yet" list is **done**: binaries/bitstrings (byte-aligned), the realistic opcode
tail, tiered bignum comparisons, function-level DCE (the 10MB-cap lever), multi-module namespacing,
closures/`apply`, exceptions (Wasm EH), floats + `:math`. Remaining gaps (see `gaps/FINDINGS.md`): protocols,
`Stream`, in-Wasm `Regex`, `:sets`/`MapSet`, non-byte-aligned bitstrings, and a runtime-variable
`receive … after` timeout.

---

## 7. Concurrency — two tiers

`[D]` **In-isolate processes = JSPI stacks.** Each Elixir process is its own JavaScript Promise
Integration (JSPI) stack: `spawn` ≈ `WebAssembly.promising(table.get(idx))(args)`; `receive` suspends on
a JS promise. Spike 1 measured ~5.2KB RSS per shallow suspended process, flat from 1k→100k, with
suspend/resume at ~1.4–2.2M/s. The 128MB isolate cap bounds ~15–25k shallow concurrent processes per
isolate. **No CPS transform is needed** — every process can be a real suspendable stack.

`[D]` **Cross-isolate processes = Durable Objects.** A DO is effectively a durable, single-threaded
GenServer: its storage is the actor's state, its alarms are `send_after`. PIDs that must outlive an
isolate or be addressed globally map to DOs.

`[D]` **Tail calls are load-bearing** (the ~5KB stack floor depends on tail-call optimization keeping
process stacks shallow). The compiler emits real Wasm tail calls for BEAM tail calls.

---

## 8. Scheduler & preemption

`[D]` **Preemption via reduction counting + JSPI suspend.** BEAM gives each process a reduction budget
(≈ one per call) and preempts when it's spent — the soft-real-time guarantee that no process starves the
scheduler. We reproduce it: the compiler injects, at each function entry, a decrement + check that calls
a **suspending `yield` import** when the budget hits zero, then resets it. Measured (`attic/measurements/
02-preemption.md`): +14% worst-case overhead on tiny `fib`; a co-runner advanced 143× during a yielding
`fib(32)` vs 0× during a blocking one. Tail-recursive loops are covered because each iteration re-enters
the function.

**State of the scheduler (`runtime/scheduler.mjs`):** a real **run queue** now exists — a single fair FIFO
(`{pid, kind}`) so no class of work (new spawns / resumed-on-message / preempted) starves another. On top of
the JSPI suspend/resume substrate it implements `spawn`/`spawn_link`/`spawn_opt`, `send`, selective `receive`
(with finite `after N` timers), `self`, links + `trap_exit` + exit-signal propagation, monitors + `:DOWN`,
a named registry, the process dictionary, and `Process.exit/2`. All of this is verified bit-exact vs the VM
in the `processes`/`genserver`/`supervisor`/`registry`/`pid-ref`/`kill`/`recv-after` conformance categories.
**Still modeled/open:** the reduction budget is a shared global rather than per-process; cross-isolate
dispatch (DOs) and an isolate-pool deployment are not built; runtime-variable `after` timeouts still block.

---

## 9. Termination semantics

`[D]` **Terminate processes by *unwinding*, never by dropping references.** A suspended JSPI stack is
engine-rooted; simply abandoning it leaks (spike B measured ~41MB/gen growth on the abandon path). To
kill a process, deliver a kill that **rejects the parked promise**, unwinding the stack.

This is now **implemented in the real scheduler**, not just the spike: park points stash the promise's
`reject`; `finish()` unwinds a dying process's parked stack with a `ProcKill` rejection (which surfaces as
a non-`$exc` exception, so compiled `try/rescue` — catching only the `$exc` tag — can't trap it, exactly
like BEAM's untrappable `exit(pid, :kill)`), and abnormal link-cascade routes through the same path so a
linked parked waiter is unwound rather than abandoned. Dead process records and spent monitors are also
reclaimed. Verified end-to-end: the `kill` conformance category (incl. killing a process that has actually
parked), and `runtime/kill_memory_test.exs` — 9,900 spawned-then-killed parked processes add **0.03 MB**
(vs tens of MB if their stacks/records leaked).

---

## 10. Cross-isolate serialization

`[D]` **Messages between isolates are serialized with Erlang ETF** (`term_to_binary`) carried over
workerd cap'n-proto RPC. We do **not** adopt cap'n-proto as the message *format* — ETF preserves Erlang
term semantics; capnp is just the transport between DOs/isolates.

---

## 11. Durability — where we are *ahead* of BEAM

`[D]` **DO storage = durable `{state, timers}`.** A Durable Object gives per-actor persisted state plus
alarms. This is *persistence per actor*, which the BEAM does not have natively (a BEAM process is
in-memory; durability is bolted on with ETS/Mnesia/external stores). On the durability axis the edge
substrate is **ahead** of BEAM. `code_change/3`-style state migration maps onto DO storage (SQLite-backed
→ real schema migration). The prototype DO (`attic/durable-object/`) demonstrates state surviving a full
process restart.

---

## 12. Hot code reload — recoverable despite closed-world

Closed-world removes native hot reload. It is recovered with:

`[D]` **A tiered runtime: one frontend IR + one WasmGC term representation + one BIF library + one
scheduler, with two backends — AOT (build-time, fast) and an interpreter resident *inside* the deployed
Wasm.** Hot-load = fetch new `.beam` as **data** (KV/R2/DO), decode to the same IR, and route the target
`M:F/A` through a swappable export-table slot to the interpreter; purge = drop the override.

`[D]` **The crux is ABI compatibility:** the interpreter uses the *same* WasmGC term structs and the same
calling/reduction convention as compiled code, so the swap boundary is a plain indirect call — no
marshalling. The tiering tax is confined to fully-qualified calls only (exactly BEAM's local-vs-external
rule).

`[D]` **Cross-module inlining is the sharp tradeoff.** Inlining a function freezes a copy and defeats the
swap. BEAM's own answer is "module boundary = optimization barrier." Offer per-module **`frozen`**
(inlined, never swappable) vs **`swappable`** (barrier, reloadable). Lifecycle: hot-load runs interpreted
(immediate, slow) → the next deploy folds it to AOT ("eventually fast," vs BEAM's "permanently fast").
State survives via DO storage.

(The prototype already compiled a real interpreter to WasmGC — `examples/expr.ex` — which is the
seed of the resident interpreter tier.)

---

## 13. The language subset

`[D]` **Keep** (target for v1): pattern matching & guards, full binaries/bitstrings, maps, structs,
protocols, closures, `try/rescue`, comprehensions, full macros (they run at build time), and
`GenServer`/`Agent`/`Task`/`Registry`; in-isolate `:ets`.

`[D]` **Cut or redefine:** distribution / `:global` / `pg` → Durable Objects + queues; hot code loading →
the tiered runtime (§12); filesystem / `:os` → not available; NIFs → JS imports (`:crypto` → WebCrypto).

`[D]` **Decide (explicit work items):**
- **bignums** — done in prototype (i31 + boxed BigInt); make exact-by-default with type specialization.
- **dynamic atoms** — fixed table + an overflow path for rare runtime-created atoms.
- **`:re` / Unicode** — host shims.

---

## 14. Why not the obvious alternatives

**Real BEAM on Fly.io + FLAME.** This is the honest competitor and must be addressed head-on. It gives
true BEAM (preemptive scheduler, per-process GC isolation, millions of processes, cheap intra-node
messaging, the whole OTP/ecosystem) with none of our deltas. Our answer is *not* "we're a better BEAM" —
we're a **different product**: edge-local, scale-to-zero, durable-per-actor, with OTP ergonomics for the
*specific* class of single-owner durable entities. We win on edge latency, scale-to-zero economics, and
per-actor durability; we lose on massive concurrency, the NIF ecosystem, and live introspection. Target
accordingly.

**Cloudflare Workflows.** Cloudflare's own docs draw the line: Workflows "run to completion" (durable
orchestration; external events via `waitForEvent`), while Durable Objects/Agents "run indefinitely" with
app-defined failure handling. So: unbounded reactive entities → DO side (our differentiator is safe);
linear orchestration → Workflows wins (don't target it); bounded-lifecycle entities like an order are the
**contested middle** and the real competitive test. `attic/spikes/workflows-comparison-spec.md` specifies the
four-way eval (ours / raw-DO / Workflow / Fly-BEAM) to settle it. Note: `step.do` memoization beats raw
DO on retry, but replay-safety of side effects is still the developer's responsibility — i.e. it needs
the *same* idempotency-key discipline our state machine enforces by construction.

---

## 15. Principal risks / open questions

- **Scheduler fairness & the run queue** (§8) — the biggest unbuilt runtime piece.
- **The 10MB module cap** — needs function-level DCE; Spike A shows ~10–28× headroom for a small actor
  closure, but a realistic runtime base + app must be measured and DCE'd.
- **The NIF / ecosystem wall** — many hex packages assume NIFs or distribution; the addressable library
  set is smaller than "all of hex." Scope expectations.
- **Numbers that only real Cloudflare can give** — throughput, tail latency, cost-per-actor at scale,
  cold-start under real isolate scheduling. Local workerd validates mechanism, not scale.
