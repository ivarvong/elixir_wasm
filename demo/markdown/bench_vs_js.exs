#!/usr/bin/env elixir
# demo/markdown/bench_vs_js.exs — the REAL Earmark engine on WasmGC vs JS markdown renderers
# (marked, markdown-it) on the IDENTICAL document, with a byte-identical correctness gate vs the VM.
#
#   cd demo/markdown && elixir bench_vs_js.exs
#   (needs: cd app && mix deps.get && mix compile;  cd vs_js && npm install)
Code.require_file("../../tooling.exs", __DIR__)

defmodule VsJs do
  @here Path.dirname(__ENV__.file)
  @app Path.join(@here, "app")
  @beam2wasm Path.join(@here, "../../compiler/beam2wasm.exs")
  @tmp Path.join(@here, "_work")
  @vsjs Path.join(@here, "vs_js")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()

  def main do
    File.mkdir_p!(@tmp)
    {_, 0} = System.cmd("mix", ["compile"], cd: @app, stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])
    wasmf = build_wasm()
    doc = Path.join(@vsjs, "doc.md")
    expected = vm_expected(doc)
    vm_us = vm_bench(doc)
    IO.puts("\n══════════ HEAD-TO-HEAD: real Earmark on WasmGC vs JS markdown renderers ══════════\n")
    {out, code} = System.cmd(@node, [Path.join(@vsjs, "bench.mjs"), wasmf, doc, expected],
      stderr_to_stdout: true, env: [{"EARMARK_VSN", earmark_vsn()}, {"EARMARK_VM_US", vm_us}])
    IO.puts(out)
    if code != 0, do: System.halt(code)
  end

  defp earmark_vsn do
    case Regex.run(~r/"earmark":.*?"(\d+\.\d+\.\d+)"/s, File.read!(Path.join(@app, "mix.lock"))) do
      [_, v] -> v
      _ -> ""
    end
  end

  # identical beam set to run.exs, plus the render_md:bin->bin export
  defp stdlib_beams do
    [Kernel, Exception, Enum, String, String.Break, String.Chars, List, Map, MapSet, Keyword, Integer, Float,
     Tuple, Range, Stream, Enumerable, Collectable, Inspect, Inspect.Algebra, Access,
     ArgumentError, RuntimeError, KeyError, :lists, :maps, :sets, :ordsets, :gb_sets, :erl_scan, :erl_anno, :proplists, :orddict, :string, :io_lib, :io_lib_format, :io_lib_pretty,
     Enumerable.List, Enumerable.Map, Enumerable.Range, Enumerable.MapSet, Enumerable.Function, Enumerable.Stream,
     Collectable.List, Collectable.Map, Collectable.MapSet, Collectable.BitString,
     String.Chars.Integer, String.Chars.Float, String.Chars.List, String.Chars.BitString, String.Chars.Atom,
     List.Chars.BitString, List.Chars.Integer, List.Chars.List, List.Chars.Atom]
    |> Enum.map(fn m -> Code.ensure_loaded(m); to_string(:code.which(m)) end)
    |> Enum.filter(&String.ends_with?(&1, ".beam"))
  end

  defp dep_beams(dep), do: Path.wildcard(Path.join(@app, "_build/dev/lib/#{dep}/ebin/*.beam"))
  defp consolidated_beams, do: Path.wildcard(Path.join(@app, "_build/dev/lib/blog/consolidated/*.beam"))

  defp dedup_prefer_consolidated(beams) do
    cons_names = MapSet.new(consolidated_beams(), &Path.basename/1)
    cons_paths = MapSet.new(consolidated_beams())
    {kept, _} =
      Enum.reduce(beams, {[], MapSet.new()}, fn b, {acc, seen} ->
        name = Path.basename(b)
        drop = MapSet.member?(cons_names, name) and not MapSet.member?(cons_paths, b)
        if MapSet.member?(seen, name) or drop, do: {acc, seen}, else: {[b | acc], MapSet.put(seen, name)}
      end)
    Enum.reverse(kept)
  end

  defp build_wasm() do
    watf = Path.join(@tmp, "blog_vsjs.wat")
    wasmf = Path.join(@tmp, "blog_vsjs.wasm")
    blog = Path.join(@app, "_build/dev/lib/blog/ebin/Elixir.Blog.beam")
    beams =
      ([blog | dep_beams("jason")] ++ dep_beams("earmark") ++ stdlib_beams() ++ consolidated_beams())
      |> dedup_prefer_consolidated()
    cmd = "elixir #{inspect(@beam2wasm)} #{Enum.map_join(beams, " ", &inspect/1)} > #{inspect(watf)} 2>#{inspect(watf <> ".stub")}"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "render:int->bin;render_md:bin->bin"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf, ["-g"]), stderr_to_stdout: true)
    IO.puts("  built #{Float.round(File.stat!(wasmf).size / 1024, 0)} KB wasm (Blog + real Jason + real Earmark + stdlib)")
    wasmf
  end

  # the same Earmark on the native BEAM — the column that separates library cost from Wasm cost
  defp vm_bench(doc) do
    code = """
    md = File.read!(#{inspect(doc)})
    for _ <- 1..200, do: Blog.render_md(md)
    n = 500
    {us, _} = :timer.tc(fn -> for _ <- 1..n, do: Blog.render_md(md) end)
    IO.write(:erlang.float_to_binary(us / n, decimals: 1))
    """
    {out, 0} = System.cmd("mix", ["run", "-e", code], cd: @app, env: [{"MIX_ENV", "dev"}])
    out
  end

  # the oracle: the same document through the same Earmark on the real VM
  defp vm_expected(doc) do
    out = Path.join(@tmp, "expected_vsjs.html")
    {html, 0} = System.cmd("mix", ["run", "-e", "IO.write(Blog.render_md(File.read!(#{inspect(doc)})))"],
      cd: @app, env: [{"MIX_ENV", "dev"}])
    File.write!(out, html)
    out
  end
end

VsJs.main()
