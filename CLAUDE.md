# elixir_wasm — working agreement

## Mission
**All pure-Elixir code must run on WasmGC.** That is the point of this project. Every real program
(Jason, Req, Earmark, …) that runs bit-exact vs the Elixir VM proves another slice of "any pure Elixir
runs here."

## The rule: when real code hits a gap, BUILD the support
When a real pure-Elixir program traps on an unsupported function or compiler gap:
- **Solve it at the root.** Implement the missing piece — a builtin in `compiler/lib/codegen_runtime.ex`,
  a host shim in `runtime/imports.mjs`, a compiler lowering in `compiler/lib/codegen_emit.ex`, or feeding
  the right `.beam` files.
- **Do NOT work around it** — no hand-rolling a replacement, no avoiding the function, no shrinking the
  input to dodge it.
- **Do NOT stop to ask** "should I solve this or ship?" — building it *is* the job.
- "All pure Elixir should run unless there's a *reason* it can't." **`LIMITATIONS.md` is the canonical
  line**: §1 lists the only legitimate limits (NIF shim fidelity, host-effect availability, runtime
  codegen → interp tier, scale); §2 the documented deltas; **everything in §3 is a bug** with an
  enumerated inventory. **"It's a lot of work" is not a reason** — that work is the point.
- **IO (file, network) is handed back to the host** at the import boundary, like NIFs. The host decides
  the backing: real fs/sockets on Node, a **virtual filesystem** (in-memory or KV/R2/DO-backed) + fetch
  on Workers. `File.read/1` works wherever the host wires it; an unwired effect traps honestly. Building
  the effects ABI is inventory work, not a limit.
- NIFs / Erlang built-ins (`:re`, `:crypto`, `:erlang`, `:binary`, `:unicode`, `:math`) are **shimmed at
  the host boundary**, not skipped. A pure-Elixir lib on top of them (e.g. `Regex` over `:re`) runs by
  completing the shim.

## Always verify
Every change is proven bit-exact vs the VM and kept suite-safe. Run after any change:
```
cd conformance && elixir run.exs     # expect 161/161 (or higher)
cd fuzz        && elixir run.exs     # expect 33/33
cd gaps        && elixir run.exs     # expect 19/20 provably correct, 0 lies
```
Pin the toolchain Node for faithful diffs: `export NODE=/Users/ivar/.nvm/versions/node/v24.16.0/bin/node`
(or rely on `tooling.exs` auto-discovery of the 24.x line).

## Compiler layout
`compiler/beam2wasm.exs` is a thin CLI shim over the library in `compiler/lib/`:
`Codegen.Common` (leaf helpers), `Codegen.Runtime` (the hand-written WAT runtime library + BIF/NIF
builtins), `Codegen.Emit` (the per-function BEAM→WAT emit path), `Beam2Wasm` (run/1 orchestration:
disasm, DCE, atom interning, closures, exports). Modules were split with byte-identical-WAT verification.
