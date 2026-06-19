#!/bin/bash
# Rebuild jason_encode.wasm from json_demo.ex + the Jason hex package.
# Requires a mix project with {:jason, "~> 1.4"} compiled (MIX_ENV=prod).
# 1) consolidate Jason.Encoder, 2) stage all Jason + needed stdlib beams,
# 3) compile with DCE, 4) wasm-as. See README for the full recipe.
set -e
B2W=../beam2wasm.exs
STUB=1 EXPORTS="order_json:->bin;report_json:->bin;scalars_json:->bin" \
  elixir $B2W ./demo.beam ./jason.beam stage/*.beam > jason_encode.wat
wasm-as jason_encode.wat -o jason_encode.wasm -all
echo "built jason_encode.wasm"
