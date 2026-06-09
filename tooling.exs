# Shared toolchain discovery for the differential harnesses (conformance/, fuzz/,
# gaps/, perf/, demo/). One source of truth so a fresh clone fails fast with an
# actionable message instead of a confusing missing-binary or wasm link error,
# and so the wasm-as feature flags can never drift between harnesses again.
#
# Require it once at the top of a harness, before the harness module:
#
#     Code.require_file("../tooling.exs", __DIR__)   # adjust depth as needed
#     defmodule Foo do
#       @node   Tooling.node!()
#       @wasmas Tooling.wasmas!()
#       ...
#       System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf), stderr_to_stdout: true)
#
# Override the binaries with env vars: NODE=/path/to/node, WASM_AS=/path/to/wasm-as.
defmodule Tooling do
  @moduledoc false

  # Minimum Node major version. JSPI + WasmGC are only stable/correct here on 24+;
  # older majors silently differ in suspender semantics and reject some heap types.
  @min_node_major 24

  # The major line the project is actually built and tested against (see BUILD.md,
  # pinned 24.16.0). Auto-discovery prefers this line over newer-but-unvalidated
  # majors, so a machine with both 24.x and 25.x picks the known-good one.
  @preferred_node_major 24

  @doc """
  Resolve a Node binary new enough for stable JSPI + WasmGC.

  Resolution order:
    1. `$NODE` if set (an explicit choice — honored, but still version-checked).
    2. `node` on `$PATH`, if it is v#{@min_node_major}+.
    3. Auto-discovery of a v#{@min_node_major}+ install under the standard version
       managers (nvm, asdf) — portable, not a single hardcoded path.

  Raises with an actionable message if none qualifies.
  """
  def node! do
    case System.get_env("NODE") do
      nil -> discover_node!()
      path -> validate_node!(path, explicit: true)
    end
  end

  defp discover_node!() do
    path = System.find_executable("node")

    cond do
      path && node_major(path) >= @min_node_major ->
        path

      found = discover_versioned_node() ->
        found

      true ->
        current = if path, do: " (`node` on PATH is #{version_string(path)})", else: ""

        fail("""
        No Node #{@min_node_major}+ found#{current}. Stable JSPI + WasmGC need v#{@min_node_major}+.
        Install it (nvm/asdf) or set NODE=/path/to/node#{@min_node_major}.
        """)
    end
  end

  # Honor an explicit $NODE, but still refuse a too-old one rather than producing
  # confusing downstream link/suspender errors.
  defp validate_node!(path, _opts) do
    unless File.exists?(path) do
      fail("NODE=#{path} does not exist. Point NODE at a Node #{@min_node_major}+ binary.")
    end

    if node_major(path) < @min_node_major do
      fail("""
      NODE=#{path} is #{version_string(path)}, but this project needs v#{@min_node_major}+
      for stable JSPI + WasmGC.
      """)
    end

    path
  end

  # Glob the standard version-manager layouts for the newest qualifying node.
  defp discover_versioned_node() do
    home = System.user_home() || ""

    [
      Path.join([home, ".nvm/versions/node/v*/bin/node"]),
      Path.join([home, ".asdf/installs/nodejs/*/bin/node"])
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(&(node_major(&1) >= @min_node_major))
    # Prefer the validated @preferred_node_major line, then newest version.
    |> Enum.sort_by(&discovery_rank/1, :desc)
    |> List.first()
  end

  # Sort key (descending): the preferred major line ranks above all others, then
  # newest {major, minor, patch} wins within each group.
  defp discovery_rank(path) do
    {major, _, _} = ver = parse_path_version(path)
    {major == @preferred_node_major, ver}
  end

  defp parse_path_version(path) do
    case Regex.run(~r/v?(\d+)\.(\d+)\.(\d+)/, path) do
      [_, a, b, c] -> {String.to_integer(a), String.to_integer(b), String.to_integer(c)}
      _ -> {0, 0, 0}
    end
  end

  # Major version of a node binary, or 0 if it can't be determined.
  defp node_major(path) do
    case Regex.run(~r/^v(\d+)\./, version_string(path)) do
      [_, major] -> String.to_integer(major)
      _ -> 0
    end
  end

  defp version_string(path) do
    case System.cmd(path, ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  @doc """
  Resolve the Binaryen `wasm-as` assembler. Order: $WASM_AS, then PATH, then the
  common Homebrew location. Raises with an actionable message on failure.
  """
  def wasmas! do
    System.get_env("WASM_AS") || System.find_executable("wasm-as") ||
      homebrew_wasmas() ||
      fail("""
      wasm-as (Binaryen) not found. Install Binaryen version_130+ (e.g.
      `brew install binaryen`) and/or set WASM_AS=/path/to/wasm-as.
      """)
  end

  defp homebrew_wasmas do
    path = "/opt/homebrew/bin/wasm-as"
    if File.exists?(path), do: path, else: nil
  end

  @doc """
  Canonical `wasm-as` argument list. `-all` enables the GC/i31/EH/tail-call feature
  set the compiler emits; `--disable-custom-descriptors` suppresses the "exact" heap
  types that newer Binaryen emits under `-all` but stock Node #{@min_node_major} rejects
  at instantiation. `extra` appends harness-specific flags (e.g. `-g` for debug names).
  """
  def wasm_as_args(wat, out, extra \\ []) do
    [wat, "-o", out, "-all", "--disable-custom-descriptors"] ++ extra
  end

  defp fail(msg), do: raise("[tooling] " <> String.trim(msg))
end
