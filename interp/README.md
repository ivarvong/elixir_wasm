# The tiered VM — a BEAM interpreter that makes this a full Elixir VM

This is the clean idea the whole project was converging on. We spent the project building a
**whole-program AOT compiler** — and fighting an endless tail: every new program surfaces new
opcodes/BIFs, and `STUB` papers over the gaps. "Run *any* Elixir" via AOT means implementing all
~180 opcodes and all of stdlib, forever.

But by now we already have the three things a VM needs:

- a **term model** (i31 / cons / tuple / map / binary / atom / fun) — `compiler/`
- a **runtime** (preemptive scheduler, processes, links, monitors, registry, OTP) — `runtime/`
- per-opcode **semantics** — the compiler's `emit` *is* a spec for what each opcode means

The missing piece was never "more opcodes." It was **universal dispatch**. So:

> **Write a BEAM interpreter in Elixir, AOT-compile it *once* with our own compiler, and let it
> execute any `.beam` as data — on the same term model and the same runtime.**

```bash
./build.sh
#   interpreter: 9429 bytes, 0 stubs
#   --- interpreting target.beam (never AOT-compiled) on the compiled interpreter ---
#     fib(20) = 6765   oracle 6765   PASS
#     fib(25) = 75025  oracle 75025  PASS
#     sum([1..5]) = 15 oracle 15     PASS
#     upto(4) = [4,3,2,1] oracle [4,3,2,1] PASS
```

`interp.ex` is ~120 lines of self-contained Elixir (only lists/tuples/recursion/pattern-matching —
**no Map/stdlib deps**, so our compiler handles it natively, 0 stubs). It is AOT-compiled to WasmGC
by `beam2wasm`. `target.ex` (fib/sum/upto) is **never compiled** — `gen_code.exs` decodes its
`.beam` into a list-based code table (`Prog.code/0`, a constant term the interpreter walks). The
answers are bit-exact with the real Elixir VM.

## Why this is the whole thing

```
                 ┌──────────── AOT front-end (beam2wasm) ───────── fast, for hot code
   .beam ───────►│                                                 (incl. the interpreter itself)
                 └──────────── interpreter front-end ───────────── complete, runs ANY .beam as data
                          │
                          ▼
              one term model  +  one runtime (scheduler/processes/OTP)
```

- The **AOT compiler stops being the thing that must handle every program.** It becomes a
  JIT/optimizer for hot code — and the thing that compiles the interpreter.
- The **interpreter is the completeness guarantee.** To run more Elixir, you add opcode clauses in
  **one place** (`exec/5`), not an endless per-program tail. The bounded set is ~180 opcodes + a
  bounded set of native BIFs (the rest of Elixir is itself Elixir, and is interpretable).
- This is exactly the **tiered runtime of ARCHITECTURE §12** ("an interpreter resident inside the
  deployed Wasm, sharing the term ABI"), now real — and the seed of hot-code reload (load new
  `.beam` as data, interpret it; the next deploy folds it to AOT).

## Scope today
`exec/5` covers `move`, `gc_bif (+ - *)`, `select_val`, the `is_*` tests, `get_list`/`put_list`,
`call`/`call_only`/`call_last`/`jump`/`return`, X/Y registers (allocate/deallocate are no-ops). That
runs arithmetic, recursion, and list code. Extending to the full opcode set + native BIFs is the
clearly-bounded remaining work — each opcode is one `case` clause with the same semantics the AOT
compiler's `emit` already specifies. The interpreter currently uses the host (Wasm) call stack for
BEAM calls; a production version would thread reductions through it for the preemptive scheduler.
