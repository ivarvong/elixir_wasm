defmodule Beam2Wasm.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ivarvong/elixir_wasm"

  def project do
    [
      app: :beam2wasm,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: false,
      deps: deps(),
      description:
        "An ahead-of-time BEAM-to-WasmGC compiler: pure Elixir/Erlang bytecode " <>
          "compiled to WebAssembly GC, verified bit-exact against the Elixir VM.",
      package: package(),
      docs: docs(),
      name: "Beam2Wasm"
    ]
  end

  def application, do: [extra_applications: []]

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "../LIMITATIONS.md", "../WRITEUP.md"],
      groups_for_modules: [
        Internals: [Beam2Wasm.Codegen.Common, Beam2Wasm.Codegen.Runtime, Beam2Wasm.Codegen.Emit]
      ]
    ]
  end
end
