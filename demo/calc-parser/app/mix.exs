defmodule Calc.MixProject do
  use Mix.Project
  def project, do: [app: :calc, version: "0.1.0", elixir: "~> 1.14", deps: deps()]
  defp deps, do: [{:nimble_parsec, "~> 1.4"}, {:jason, "~> 1.4"}, {:beam2wasm, path: "../../..", runtime: false}]
end
