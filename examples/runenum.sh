#!/usr/bin/env bash
# Build + run the EnumDemo: real unmodified Elixir Enum compiled to WasmGC.
# Locates Enum.beam portably via :code.which/1 (works on any Elixir install).
set -euo pipefail
cd "$(dirname "$0")"

elixirc enum_demo.ex
ENUM=$(elixir -e 'IO.write(:code.which(Elixir.Enum))')
echo "using Enum.beam: $ENUM"

# STUB=1: functions using constructs we don't lower yet (try/apply/float — only on
# non-list Enum paths) become traps so the whole module still builds. EXPORTS names the
# user entry points; the closures/namespacing/BIF-shims do the rest.
STUB=1 EXPORTS="sumsq_evens:list->int;cnt:list->int;rev:list->list;anybig:list->atom;allpos:list->atom;mapsum:list->int" \
  elixir ../beam2wasm.exs Elixir.EnumDemo.beam "$ENUM" > enum_demo.wat

wasm-as enum_demo.wat -o enum_demo.wasm -all
node runenum.mjs enum_demo.wasm enum_demo.wat
