defmodule Mix.Tasks.Wasm.Doctor do
  use Mix.Task

  @shortdoc "Check the toolchain beam2wasm output needs"

  @moduledoc """
  Reports on every external tool the compiled output touches, with install hints:
  `wasm-as` (required to assemble), Node 24+ (run/verify locally), `workerd` and
  `wrangler` (optional: local Workers serve / deploy).
  """

  @impl Mix.Task
  def run(_args) do
    rows = [
      check("elixir", fn -> {:ok, System.version()} end, "required", nil),
      check("otp", fn -> {:ok, System.otp_release()} end, "required", nil),
      check(
        "wasm-as",
        fn -> {:ok, Beam2Wasm.Toolchain.wasm_as!()} end,
        "required",
        "brew install binaryen   (or set WASM_AS=)"
      ),
      check(
        "node 24+",
        fn -> {:ok, Beam2Wasm.Toolchain.node!()} end,
        "run/verify locally",
        "install via nvm/asdf    (or set NODE=)"
      ),
      check("workerd", fn -> find("workerd") end, "optional: local Workers serve", "npm i -D workerd"),
      check("wrangler", fn -> find("wrangler") end, "optional: deploy", "npm i -g wrangler")
    ]

    Mix.shell().info("")

    Enum.each(rows, fn
      {name, {:ok, detail}, purpose, _hint} ->
        Mix.shell().info("  ✅ #{String.pad_trailing(name, 10)} #{String.pad_trailing(purpose, 30)} #{detail}")

      {name, :missing, purpose, hint} ->
        Mix.shell().error("  ❌ #{String.pad_trailing(name, 10)} #{String.pad_trailing(purpose, 30)} #{hint}")
    end)

    Mix.shell().info("")
  end

  defp check(name, f, purpose, hint) do
    {name,
     try do
       f.()
     rescue
       _ -> :missing
     end, purpose, hint}
  end

  defp find(bin) do
    case System.find_executable(bin) do
      nil -> :missing
      path -> {:ok, path}
    end
  end
end
