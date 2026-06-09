# .beam smoketest — load + decode + run real Erlang compiler output

End-to-end proof that we can ingest a **real `.beam`** (OTP compiler output), parse its
container, decode its bytecode from scratch, execute it, and get answers that match the
**real BEAM VM** — plus one function lifted onto the WasmGC/JSPI substrate from the spikes.

## Run
```
erlc +no_type_opt +no_line_info smoke.erl          # produce smoke.beam (OTP 25)
node runbeam.mjs smoke.beam                          # parse + decode + interpret + check vs VM
# WasmGC-lifted add/2 on the substrate:
/tmp/binaryen-version_130/bin/wasm-as add_lift.wat -o add_lift.wasm -all
node --experimental-wasm-jspi -e '...instantiate add_lift.wasm; add(2,3)===5'
```

## Result
```
module: smoke   atoms:11 imports:5 exports:6
imports: erlang:+/2, erlang:*/2, erlang:-/2, ...
exports: ... fib/1@L9, fact/1@L6, dbl/1@L4, add/2@L2
decoded 58 instructions from Code chunk (clean to end)

add(2,3)    = 5        oracle 5        PASS   (3 steps, 0 reductions)
dbl(21)     = 42       oracle 42       PASS   (3 steps, 0 reductions)
fact(10)    = 3628800  oracle 3628800  PASS   (124 steps, 10 reductions)
fib(20)     = 6765     oracle 6765     PASS   (218904 steps, 21890 reductions)

WasmGC-lifted smoke:add(2,3) = 5 PASS
```

## What `runbeam.mjs` actually does (no Erlang at runtime)
1. **Container parse** — IFF `FOR1/BEAM`, 4-byte-aligned chunks; pulls `AtU8` (atoms),
   `ImpT` (imports → resolves which BIF each `gc_bif` calls), `ExpT` (exports → each
   function's entry label), `Code`.
2. **Bytecode decode** — the BEAM *compact operand encoding* (4-bit / 11-bit / n-byte forms,
   signed ints, and the extended `list` operand for `select_val`). Opcode→arity comes from the
   live OTP build's `beam_opcodes:opname/1` (`opcodes.txt`), so it's version-correct.
3. **Interpret** — X registers, a CP register + Y-register frame stack (`allocate`/`deallocate`/
   `call`/`return`), the ~14 opcodes these functions use, and `erlang:+/-/*` BIFs. A reduction
   counter ticks per call (the scheduler-preemption hook).
4. **Validate** — answers compared against the real VM (`smoke:fact(10)` etc. via `erl`).

`add_lift.wat` lowers `add/2`'s bytecode (`gc_bif '+' {x,0} {x,1} -> {x,0}`) to a WasmGC
function over **i31ref** small-int terms, run on Node's WasmGC + JSPI — the same substrate
validated in the spikes. Same answer (5), now executing as compiled WasmGC.

## What this smoketest deliberately elides (and the production loader needs)
- **Typed registers.** Default OTP emits `{tr,Reg,Type}` operands (an extended `z`-subtype that
  also carries a Type-chunk index); we sidestep them with `+no_type_opt`. The real loader must
  decode them (bounded — it's in `beam_disasm`).
- **Opcode coverage.** 14 of ~180 opcodes. The long tail is the work: bit-syntax (`bs_*`),
  maps (`get_map_elements`/`put_map_*`), `try`/`catch`, `apply`, `make_fun`/`call_fun`,
  `select_tuple_arity`, message ops (`send`/`loop_rec`/`wait`), the GC-test ops (no-ops under WasmGC).
- **Term model.** Small ints only. Real terms (bignums, atoms, tuples, cons, maps, binaries,
  pids, funs) + total ordering/equality = Spike A.
- **Interpreter vs AOT.** The recursive functions run in a JS interpreter here (a fine bootstrap
  + reference oracle); the production path is bytecode/`beam_ssa` → WasmGC (Spike D), as shown
  for `add/2`.
- **BIF/stdlib surface & the loader for stdlib `.beam`** (`lists`, `gen_server`, …), which is the
  10 MB-gate question.
