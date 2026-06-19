defmodule Beam2Wasm.Toolchain do
  @moduledoc """
  Locates the external tools the compiled output needs: Binaryen's `wasm-as` (to assemble
  WAT) and Node.js 24+ (to run/verify modules locally). `mix wasm.doctor` reports on all
  of them with install hints.
  """

  @min_node_major 24

  @doc "Path to `wasm-as`, or raises with install instructions. Override with `WASM_AS`."
  def wasm_as! do
    System.get_env("WASM_AS") || System.find_executable("wasm-as") ||
      first_existing(["/opt/homebrew/bin/wasm-as", "/usr/local/bin/wasm-as"]) ||
      raise "wasm-as (Binaryen 130+) not found — `brew install binaryen` (or apt install binaryen), or set WASM_AS=/path/to/wasm-as"
  end

  @doc "Canonical wasm-as argument list (GC/EH/tail-call features on; debug names kept)."
  def wasm_as_args(wat, out, extra \\ ["-g"]),
    do: [wat, "-o", out, "-all", "--disable-custom-descriptors"] ++ extra

  @doc "Path to a Node #{@min_node_major}+ binary, or raises. Override with `NODE`."
  def node! do
    candidates =
      [System.get_env("NODE"), System.find_executable("node")] ++
        Path.wildcard(Path.expand("~/.nvm/versions/node/v#{@min_node_major}*/bin/node")) ++
        Path.wildcard(Path.expand("~/.asdf/installs/nodejs/#{@min_node_major}*/bin/node"))

    Enum.find(Enum.reject(candidates, &is_nil/1), &node_ok?/1) ||
      raise "Node #{@min_node_major}+ not found (WasmGC + JSPI need it) — install via nvm/asdf or set NODE=/path/to/node"
  end

  defp node_ok?(path) do
    case System.cmd(path, ["--version"], stderr_to_stdout: true) do
      {"v" <> v, 0} -> v |> String.split(".") |> hd() |> String.to_integer() >= @min_node_major
      _ -> false
    end
  rescue
    _ -> false
  end

  defp first_existing(paths), do: Enum.find(paths, &File.exists?/1)
end
