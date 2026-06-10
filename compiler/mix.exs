defmodule Beam2Wasm.MixProject do
  use Mix.Project

  # The BEAM->WasmGC compiler as a Mix package. Add it as a path dependency and any
  # pure-Elixir Mix project gains `mix wasm.build`:
  #
  #     {:beam2wasm, path: "../elixir_wasm/compiler", runtime: false}
  #
  #     mix wasm.build --module MyApp --export "run:int->int" --worker
  #
  # The CLI shim (`elixir beam2wasm.exs ...`) and the differential harnesses keep working
  # unchanged — they load compiler/lib via Code.require_file, not through Mix.
  def project do
    [
      app: :beam2wasm,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: false,
      deps: []
    ]
  end

  def application, do: [extra_applications: []]
end
