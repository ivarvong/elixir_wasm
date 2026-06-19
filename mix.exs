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
        "An experiment in ahead-of-time compiling Elixir/BEAM bytecode to WebAssembly GC, " <>
          "checked against the real Elixir VM. A prototype / learning project.",
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      name: "Beam2Wasm"
    ]
  end

  # :mix is needed in the PLT because the Mix.Tasks.* modules call Mix.* / Mix.Task.run/*.
  defp dialyzer do
    [
      plt_add_apps: [:mix],
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end

  def application, do: [extra_applications: []]

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
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
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/ARCHITECTURE.md",
        "docs/USAGE.md",
        "docs/BUILD.md",
        "docs/LIMITATIONS.md",
        "docs/ROADMAP.md",
        "docs/WRITEUP.md"
      ],
      groups_for_modules: [
        Internals: [Beam2Wasm.Codegen.Common, Beam2Wasm.Codegen.Runtime, Beam2Wasm.Codegen.Emit]
      ]
    ]
  end
end
