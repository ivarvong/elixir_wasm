#!/usr/bin/env elixir
# Thin CLI shim. The compiler is a library under compiler/lib/ (Codegen.Common, Codegen.Runtime,
# Beam2Wasm); this just loads it and runs the entry point so the existing invocation keeps working:
#   elixir beam2wasm.exs Elixir.Sort.beam [more.beam ...] > sort.wat
# (Env vars EXPORTS / STUB / BIGNUM / REDS are read by Beam2Wasm.run.) See compiler/REFACTOR_PLAN.md.
dir = __DIR__
Code.require_file("lib/codegen_common.ex", dir)
Code.require_file("lib/codegen_runtime.ex", dir)
Code.require_file("lib/beam2wasm.ex", dir)

IO.puts(Beam2Wasm.run(System.argv()))
