defmodule PyexWasm.MixProject do
  use Mix.Project
  def project, do: [app: :pyex_wasm, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
  defp deps do
    [{:pyex, path: "/tmp/pyex"},
     {:decimal, "~> 2.0"},
     {:postgrex, "~> 0.22"},
     {:explorer, "~> 0.11.1"},
     {:beam2wasm, path: "../../../compiler", runtime: false}]
  end
end
