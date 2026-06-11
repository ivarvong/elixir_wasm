#!/usr/bin/env elixir
# Thin CLI shim over the Beam2Wasm library (compiler/lib/). Environment variables are the
# CLI's interface; they translate to the library's options here and nowhere else:
#   EXPORTS="f:int->bin;g:bin->bin" STUB=1 BIGNUM=1 elixir beam2wasm.exs a.beam b.beam > out.wat
# (REDS=<n> reduction budget; NODCE=1 disables DCE; NOFUSE=1 disables i64 chain fusion.)
dir = __DIR__
Code.require_file("lib/beam2wasm/codegen/common.ex", dir)
Code.require_file("lib/beam2wasm/codegen/runtime.ex", dir)
Code.require_file("lib/beam2wasm/codegen/emit.ex", dir)
Code.require_file("lib/beam2wasm.ex", dir)

opts = [
  exports: System.get_env("EXPORTS"),
  stub: System.get_env("STUB") != nil,
  bignum: System.get_env("BIGNUM") != "0",
  reds: (if r = System.get_env("REDS"), do: String.to_integer(r)),
  dce: System.get_env("NODCE") == nil,
  fuse: System.get_env("NOFUSE") == nil
]

IO.puts(Beam2Wasm.run(System.argv(), opts))
