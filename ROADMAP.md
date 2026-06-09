# Roadmap — from prototype to runtime

Legend: **[done]** proven in this repo · **[modeled]** mechanism shown, production version unbuilt ·
**[open]** not started · **[CF]** needs real Cloudflare, not local workerd.

The prototype settles *feasibility* end to end. The work below turns it into a runtime. It is ordered by
dependency and value; the two keystones are called out first.

## Keystones (build these first)

- **Per-process scheduler with a real run queue** *(Phase 2)*. **Built & preemptive** (`runtime/`):
  `spawn`/`send`/selective `receive`/`self` over real JSPI stacks, per-process mailboxes, captured
  closures, **reduction-counted preemption** (a CPU-bound `spin(1M)` is sliced into ~500 dispatches —
  budget reset per dispatch), real Wasm tail calls, and a module-based **GenServer** (call/cast/state via
  `apply` dispatch). plus **links + `trap_exit` +
  exit signals + a restarting supervisor** ("let it crash"), **monitors** + a named-process **registry**,
  and a **durable GenServer running in a Durable Object** (`durable-genserver/`, state durable across
  restart — the product thesis, closed). All verified bit-exact vs the VM (`conformance` `processes` +
  `genserver` + `supervisor` + `registry`). **Still to add:** `receive` timeouts, a reusable
  `Supervisor`/`Agent`/`Task` library on the primitives, a term codec (ETF) for richer durable state +
  cross-isolate messaging, and kill-via-unwind for non-trapping links (spike B).
- **Function-level dead-code elimination** *(Phase 1)*. The lever for the Workers ~10MB module cap.
  Spike A shows ~10–28× headroom for a small actor closure, but a realistic runtime base + app must be
  measured and DCE'd. Closed-world makes aggressive DCE sound.

---

## Phase 0 — Feasibility (DONE)

- `[done]` Substrate: JSPI process economics, kill/unwind, shared-heap GC (`spikes/01`).
- `[done]` Size + perf go/no-go gate, GREEN (`spikes/02`): actor closure ~0.36MB gz bytecode pruned vs
  10MB cap; WasmGC ≈ BEAM bytecode size; AOT ~1.7 ns/call (~2.6× a JS-backend port; far faster than a
  BEAM interpreter).
- `[done]` Frontend: real Elixir → WasmGC via `:beam_disasm` (`compiler/`).
- `[done]` Non-trivial programs validated vs the Elixir VM: merge sort, an expression interpreter, a
  map-based state machine (`compiler/examples`).
- `[done]` Running in a Durable Object on workerd, durable across process restart (`durable-object/`).
- `[done]` Three runtime guarantees measured (`measurements/`): cold start, preemption, exact integers.
- `[done]` Durable `gen_statem` fault-injection eval — OTP discipline yields exactly-once-under-failure
  where naive DO code double-charges/corrupts (`spikes/03`).

---

## Phase 1 — Compiler completeness

- `[done→extend]` **Binaries & bitstrings** — a `$binary` term (`(array (mut i8))` wrapped in a struct,
  distinct from tuple/map per the §5 rule) plus the `bs_*` opcode family. **Byte-aligned construction
  (`bs_create_bin`: string/binary/integer segments) and matching (modern `bs_match` with match-context
  threading) are done and bit-exact vs the VM** (`compiler/examples/strix.ex`, runs on workerd). Remaining:
  non-byte-aligned bitstrings, UTF/signed/little-endian/float segments, and the `:binary`/`String` BIFs.
  Load-bearing for real Elixir (and for ETF, §Phase 3).
- `[done]` **Closures** — `make_fun3`/`call_fun`/`call_fun2` lowered to a `$fun` term (table index + captured
  free vars) + funcref table + `call_indirect`. Lambdas get a `(self, args…)` signature with a free-var
  prologue; dual targets (named `&f/a` captures also called directly) get a wrapper. This is what lets the
  **real unmodified `Enum`** run over lists (`compiler/examples/enum_demo.ex`) — no protocols needed for the
  `is_list` fast paths.
- `[done]` **Multi-module namespacing** — every function is `$Mod.fun_arity`, so `Enum` + `:lists` + user
  modules merge without `fun/arity` collisions. (Was the last `[open]` Phase-1 keystone below.)
- `[open]` **Remaining opcode tail** — `gc_bif`/`bif` arithmetic & guards on floats, the few `is_*` not yet
  covered, float terms (`f64` boxed). **Exceptions DONE** (`[done]`): `try`/`try_end`/`try_case`/`throw`/
  `error`/`raise` lowered onto a Wasm `try_table`+`(tag $exc …)` wrapping the function's dispatch loop;
  the catch handler stages (class,reason,trace)→(x0,x1,x2) and re-dispatches to the armed handler block.
  **Nesting is correct** — the parent handler is saved/restored through BEAM's per-try Y register (its
  catch stack), so a throw inside a catch unwinds to the enclosing `try`. Bit-exact vs the VM across
  value-class throw, class-dispatch (`:throw`/`:error`), and nested `try` (`conformance` `exceptions`,
  11/11). Limitation: Wasm *traps* (e.g. `div`-by-zero) aren't catchable yet, and `exit/1` stays a
  process exit rather than a catchable throw. Done so far: `div`/`rem`/`band`/`bor`/
  `bxor`/`bsl`/`bsr`, `abs`/`min`/`max`, boolean-valued comparison bifs, `length`/`hd`/`tl`,
  `is_integer`/`is_atom`/`is_list`/`is_binary`/`is_function`, **real Wasm tail calls** (`return_call` — was
  `(return (call …))`, which overflowed on deep recursion), and **`apply`/`apply_last`** (closed-world
  `apply_N` dispatch → enables `mod.fun(args)` and the module-based GenServer). A `STUB=1` mode traps
  unsupported functions so large modules still build.
- `[open→started]` **BIF shims** — hand-written WAT (`builtins/0`) for native NIFs (started:
  `:lists.reverse/{1,2}`). Grown as real programs need them — see Phase 2.
- `[done]` **Tiered comparisons for bignums** — `<`/`>`/`>=`/`=<`/`==`/`=:=` are now correct on boxed
  bignums: a `$int_cmp` helper (i31 fast path → i64 compare; else host `BigInt` `cmp`), `$term_rank`
  ranks `$big` as a number, `$term_compare`'s number case routes through `$int_cmp`, and equality uses
  `ref.eq OR (both-int AND $int_cmp==0)` so two *distinct* boxed-equal bignums compare equal. Verified
  bit-exact vs the VM (`conformance` `bignum`, 11/11): `fact(50)` (65 digits) and `>`/`>=`/`==` on huge
  values. This unblocks BIGNUM-as-default — which still waits on type-specialization (next bullet) to
  avoid the always-on tax, plus wiring the `big` import into every runner (driver done; scheduler/DO next).
- `[open]` **Type-driven arithmetic specialization** — use `:beam_disasm`'s typed registers to emit
  inline i32 where an operand is provably a bounded integer, tiered helper otherwise. Removes the
  arbitrary-precision fast-path tax (measured +50% when always-on).
- `[done]` **Function-level DCE** (keystone) — reachability from the exported entry points (static calls
  + `make_fun3` targets + conservative apply-arity); compiles **only reachable functions**. Default-on
  (`NODCE=1` to disable). On the Enum demo: **585 → 58 functions, 6.4KB** (the 10MB lever). And it turns
  `STUB` from a crutch into a **completeness meter**: *reachable-stubs = 0 ⇒ the program is provably
  supported* (no silent traps). The harness-driven loop: DCE surfaces a real gap (e.g. it pulled in the
  `element/2` BIF → implemented it → reachable-stubs back to 0). Next: drop unused atom globals too;
  exact apply-target tracking (vs all-arity).
- `[open]` **Productionize as a Mix compiler task** — `mix wasm.compile`, consuming `beam_ssa` where it
  beats `:beam_disasm`, with incremental builds.

## Phase 2 — Runtime base

- `[done→harden]` **Scheduler + run queue** (keystone, see top). **R1 built** (`runtime/scheduler.mjs`):
  cooperative scheduler over JSPI stacks, spawn/send/selective-receive/self, mailboxes, verified vs the
  VM. Harden: per-process reduction budget + preemption integration + fair dispatch + `receive` timers.
- `[open]` **Term library hardening** — the hand-WAT helpers (`$cons`/`$map`/`$big`/atoms) generalized,
  plus deep equality, ordering (Erlang term order), hashing.
- `[open]` **BIF shims** — `:crypto` → WebCrypto, `:re` → a host regex shim, `:unicode`/string ops,
  `:maps`/`:lists` builtins, `:erlang` core. In-isolate `:ets` over a WasmGC map/table.
- `[open]` **Process plumbing** — links, monitors, `Process.flag(:trap_exit, …)`, a `Registry`, and
  supervision trees mapped onto spawn + kill-via-unwind (§9) + DO-backed restart.

## Phase 3 — Concurrency productization

- `[modeled]` **JSPI process pool** — spawn = promising-call on a function-table slot; mailbox + `receive`
  = suspend on a promise; measured economics in spike 1.
- `[done→harden]` **Kill via unwinding** — reject the parked promise; spike B proved it composes; harden
  into the supervisor path.
- `[open]` **Cross-isolate messaging** — PIDs → DOs; `send` across isolates = ETF (`term_to_binary`) over
  workerd cap'n-proto RPC; `send_after` = DO alarms. Needs binaries (Phase 1) for ETF.

## Phase 4 — The tiered VM (interpreter + AOT) — *the keystone for "run any Elixir"*

- `[done→extend]` **Resident interpreter tier** (`interp/`). A BEAM interpreter written in Elixir,
  AOT-compiled by `beam2wasm` itself (9.4KB, **0 stubs** — self-contained: lists/tuples/recursion only),
  running on our runtime, **interpreting a `.beam` we never AOT-compiled** (fib/sum/upto) bit-exact vs
  the VM. This flips the architecture: the **AOT compiler becomes a JIT for hot code** (and compiles the
  interpreter); the **interpreter is the completeness guarantee** — "run any Elixir" becomes a bounded,
  one-place job (opcode clauses in `exec/5`), not the endless per-program AOT tail. Extend: the full
  opcode set + native BIFs; thread reductions through interpreted calls for preemption.
- `[done]` **`.beam`-as-data loading** — `gen_code.exs` decodes any `.beam` into a list-based code table
  (a constant term). Next: load from KV/R2/DO at runtime (vs build-time), route `M:F/A` to the interp.
- `[open]` **Swappable export-table slots** + `frozen`/`swappable` per-module attribute (cross-module
  inlining as the optimization barrier); `code_change/3` via DO storage migration.

## Phase 5 — Validate at scale [CF]

- `[CF]` Throughput, tail latency, and **cost-per-actor** at scale; cold start under real isolate
  scheduling (local workerd gives mechanism + ~10µs instantiate, not scale).
- `[CF]` Run the **Workflows comparison** (`spikes/workflows-comparison-spec.md`) four ways
  (ours / raw-DO / Workflow / Fly-BEAM) to settle the contested middle (§14 of ARCHITECTURE).
- `[CF]` Max concurrent JSPI processes per isolate under the real 128MB cap (spike 1 estimates ~15–25k).

---

## Honest "not in scope / known walls"

- The **NIF / distribution ecosystem** — many hex packages won't port; the addressable set is smaller
  than all of hex. Communicate this in any product framing.
- **Massive soft-realtime concurrency** (LiveView-scale connections) is *not* the target; the runtime
  tradeoffs are weakest there (§1).
- **Live BEAM introspection / tracing** (`:observer`, `:dbg`) is lost under closed-world; a different
  observability story (structured logs, DO state inspection) is needed.
