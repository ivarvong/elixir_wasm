# beam2wasm module-split plan (TODO 5.3 / 5.5)

## Status: the compiler is now a library (DONE), the Emit split + 5.5 remain

`compiler/beam2wasm.exs` was one ~3740-line `Beam2Wasm` script. It is now a small library:

```
compiler/beam2wasm.exs        11 lines   — thin CLI shim (Code.require_file the lib/, call run/1)
compiler/lib/codegen_common.ex   55      — Codegen.Common: shared leaf helpers (term_eq, sanitize, bin_literal)
compiler/lib/codegen_runtime.ex 1481      — Codegen.Runtime: the hand-written WAT runtime library
compiler/lib/beam2wasm.ex      2219      — Beam2Wasm: run/1 orchestration + the emit path
```

The split used `import` so call sites are unchanged; verified **byte-identical generated WAT** across
all 109 harness programs (behavior preserved by construction) plus conformance 161/161, fuzz 33/33,
gaps 19/20. The runtime cluster's only external deps were exactly {term_eq, sanitize, bin_literal}
(AST-confirmed), which is why Codegen.Common is tiny.

**Remaining (deferred, lower priority):**
- **Split `Codegen.Emit` out of `lib/beam2wasm.ex`** — `compile_fun/2` + the opcode `case` + its emit
  helpers, leaving `run/1` orchestration in `Beam2Wasm`. Same recipe: move funcs, `import Codegen.Common`
  (the emit cluster also shares only term_eq/bin_literal with runtime), verify byte-identical WAT. This
  drops `lib/beam2wasm.ex` to a focused ~1000-line orchestration module.
- **5.5 call-variant dedup** — a `ret_value(ce, e)` helper for the recurring `call_ext`→`(local.set $x0 e)`
  / tail-form→`(return e)` idiom (whereis, spawn_opt, apply, exit/2, …). This *changes* the WAT, so verify
  with the harnesses (not byte-diff). ~30–40 lines.
- **Full Mix packaging** (`mix.exs` + `mix wasm.compile`) — compiled modules in `_build` (faster than
  re-`require_file` per invocation) + ExUnit. Tracked in ROADMAP as the productionization step; it would
  change how the 13 harnesses invoke the compiler, so it's a deliberate, separate piece of work.

## Original analysis (kept for the Emit split)

## Why deferred (the engineering call)

The compiler is correct and exhaustively tested (161 conformance + 33 fuzz + 19/20 gaps, all
bit-exact vs the VM). The split is **pure maintainability — zero functional value** — and a subtle
codegen change would undermine the conformance foundation everything else rests on. The risk/reward
only justifies it with dedicated focus and the byte-identical-WAT gate below, not as a tail-end task.

## The entanglement (measured, not guessed)

The `builtins/0` function (lines ~920–2021, ~1100 lines, the obvious first extraction) is **not**
self-contained. It reaches into:

- **4 sibling helpers** (interpolated into its WAT strings): `term_eq/2`, `fq/3`, `bin_literal/1`,
  `sanitize/1`.
- **8 process-dictionary keys**: `:proc`, `:float`, `:exc`, `:bignum`, `:req_override`, `:mapsfold`,
  `:closures`, `:stubs`.

So extracting it cleanly means either (a) a circular module dependency (Beam2Wasm ↔ Builtins), or
(b) first lifting the shared helpers into a `Codegen.Common` module both can call. (b) is the right
shape but is itself a non-trivial move.

## Recommended staging (each step: byte-identical WAT, then harnesses, then commit)

The safety gate is **byte-identical generated WAT**, not just green harnesses — if the `.wat` for a
representative set is unchanged, behavior is preserved *by construction*. Capture a baseline first:

```
# baseline WAT for a pure, a proc, and a binaries-heavy program
for p in p03_expr_evaluator p09_ecommerce p07_rle_huffman; do
  elixirc gaps/$p.exs ...; EXPORTS=run:int->int STUB=1 BIGNUM=1 elixir compiler/beam2wasm.exs ... > /tmp/$p.before.wat
done
# after each extraction step, regenerate and `diff` — must be empty.
```

1. **`Codegen.Common`** — move the pure string helpers with no pdict/IR deps: `sanitize/1`,
   `fq/3`, `bin_literal/1`, `int_literal/1`, `materialize/1`, `float_lit/1`, the `@i31_*` attrs.
   `term_eq/2` reads `:proc`/`:bignum` from pdict — moves too (pdict is process-global, still works).
   *No WAT change.*
2. **`Codegen.Builtins`** — move `builtins/0` (now able to call `Codegen.Common`). *No WAT change.*
3. **`Codegen.Emit`** — move `compile_fun/2` + the opcode `case`. This is the big one; split the
   `case` into per-family helper functions (calls/control-flow, tests/guards, list-tuple-map,
   binaries `bs_*`, arith/specialization, processes/BIF intercepts, exceptions). *No WAT change* if
   purely mechanical.
4. **`beam2wasm.exs`** becomes a thin entry: `Code.require_file` the lib files, then `run/1`
   orchestration (disasm, DCE worklist, mode detection, atom interning, closure scan, exports).
   Keep the **same path** — the harnesses invoke `elixir ../compiler/beam2wasm.exs <beams>`
   (see conformance/run.exs, fuzz/run.exs, gaps/run.exs).
5. **Optional, separate, NOT byte-identical:** the call-variant dedup (5.5) and the pdict→context-
   struct conversion. These *change* code shape, so verify with the harnesses (not byte-diff) and
   commit independently. 5.5: a `ret_value(ce, e)` helper for the recurring
   `call_ext`→`(local.set $x0 e)` / tail-form→`(return e)` idiom (whereis, spawn_opt, apply, exit/2,
   …). Savings are real but modest (~30–40 lines), so do it only alongside the emit split.

## The 17 pdict keys (document or thread)

If converting pdict → an explicit context struct (highest-risk, lowest-value part), these are the
keys threaded through compilation today: `:primary_mod :proc :exc :stub :bignum :float :closures
:atom_idx :stubs :consts :const_n :const_defs :reds :tramp_base :atom_names :req_override :mapsfold`.
At minimum, document them in one block atop `run/1`; the struct conversion is optional.
