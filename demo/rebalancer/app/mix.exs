defmodule Rebalancer.MixProject do
  use Mix.Project
  def project, do: [app: :rebalancer, version: "0.1.0", elixir: "~> 1.14", deps: deps()]
  defp deps, do: [{:jason, "~> 1.4"}, {:beam2wasm, path: "../../..", runtime: false}]
end
