#!/usr/bin/env elixir
# demo/markdown — a real-world content pipeline on WasmGC: real unmodified Jason decodes a JSON article,
# a markdown->HTML renderer + template produce an HTML page. Renders on Wasm AND the VM and asserts the
# HTML is BYTE-IDENTICAL, then benches per-render throughput on Wasm.
#   cd demo/markdown && elixir run.exs            (the app/ mix project must be compiled: cd app && mix compile)
Code.require_file("../../tooling.exs", __DIR__)

defmodule MdDemo do
  @here Path.dirname(__ENV__.file)
  @app Path.join(@here, "app")
  @beam2wasm Path.join(@here, "../../compiler/beam2wasm.exs")
  @driver Path.join(@here, "../../conformance/driver.mjs")
  @tmp Path.join(@here, "_work")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()
  @seeds [0, 1, 2]

  def main do
    File.mkdir_p!(@tmp)
    ensure_compiled!()
    {wasmf, watf} = build_wasm()
    IO.puts("\n══════════ MARKDOWN PIPELINE: real Jason + renderer, WasmGC vs the VM ══════════\n")

    results =
      Enum.map(@seeds, fn s ->
        vm = vm_render(s)
        wasm = wasm_render(wasmf, watf, s)
        ok = vm == wasm
        title = vm |> String.split("<h1>") |> Enum.at(1, "") |> String.split("</h1>") |> Enum.at(0)
        IO.puts("  #{if ok, do: "✅", else: "❌"} seed #{s}  #{byte_size(vm)} bytes  \"#{title}\"")
        unless ok, do: show_diff(vm, wasm)
        ok
      end)

    pass = Enum.count(results, & &1)
    IO.puts("\n  #{pass}/#{length(@seeds)} pages BYTE-IDENTICAL (real Jason.decode! + markdown render -> HTML)")
    bench(wasmf, watf)
    if pass == length(@seeds), do: :ok, else: System.halt(1)
  end

  # the app/ mix project holds blog.ex + the real Jason dep; build it once.
  defp ensure_compiled!() do
    {_, 0} = System.cmd("mix", ["compile"], cd: @app, stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])
  end

  defp blog_beam, do: Path.join(@app, "_build/dev/lib/blog/ebin/Elixir.Blog.beam")
  defp dep_beams(dep), do: Path.wildcard(Path.join(@app, "_build/dev/lib/#{dep}/ebin/*.beam"))
  defp stdlib_beams do
    # NB: omit modules the compiler already shims (Regex/:re/:binary/:unicode/:math/:string) — including
    # their beams double-defines the host-shimmed functions ("repeated function name").
    # Include protocol IMPL modules (Enumerable.List etc.) so the dynamic apply dispatch in the consolidated
    # protocols has real targets to call.
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

  # mix consolidates protocols (Enumerable/Collectable/Inspect/String.Chars/Jason.Encoder) into
  # _build/.../consolidated/ — impl_for/1 resolved statically (no runtime Module.concat dispatch).
  # Prefer those over the system/unconsolidated copies of the same module.
  defp consolidated_beams, do: Path.wildcard(Path.join(@app, "_build/dev/lib/blog/consolidated/*.beam"))
  # Drop unconsolidated copies of modules that have a consolidated build, but PRESERVE ORDER — the first
  # beam (Blog) must stay first, because the compiler takes the primary module from hd(beams).
  defp dedup_prefer_consolidated(beams) do
    cons_names = MapSet.new(consolidated_beams(), &Path.basename/1)
    cons_paths = MapSet.new(consolidated_beams())
    {kept, _} =
      Enum.reduce(beams, {[], MapSet.new()}, fn b, {acc, seen} ->
        name = Path.basename(b)
        drop_unconsolidated = MapSet.member?(cons_names, name) and not MapSet.member?(cons_paths, b)
        if MapSet.member?(seen, name) or drop_unconsolidated,
          do: {acc, seen},
          else: {[b | acc], MapSet.put(seen, name)}
      end)
    Enum.reverse(kept)
  end

  defp build_wasm() do
    watf = Path.join(@tmp, "blog.wat")
    wasmf = Path.join(@tmp, "blog.wasm")
    beams =
      ([blog_beam() | dep_beams("jason")] ++ dep_beams("earmark") ++ stdlib_beams() ++ consolidated_beams())
      |> dedup_prefer_consolidated()
    cmd = "elixir #{inspect(@beam2wasm)} #{Enum.map_join(beams, " ", &inspect/1)} > #{inspect(watf)} 2>#{inspect(watf <> ".stub")}"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "render:int->bin"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf, ["-g"]), stderr_to_stdout: true)
    IO.puts("  built #{Float.round(File.stat!(wasmf).size / 1024, 0)} KB wasm from #{length(beams)} beams (Blog + real Jason + real Earmark + stdlib)")
    {wasmf, watf}
  end

  defp vm_render(seed) do
    {out, 0} = System.cmd("mix", ["run", "-e", "IO.write(Blog.render(#{seed}))"], cd: @app, env: [{"MIX_ENV", "dev"}])
    out
  end

  @runner Path.join(@here, "runner.mjs")
  defp wasm_render(wasmf, _watf, seed) do
    case Tooling.cmd(@node, [@runner, wasmf, to_string(seed)]) do
      {out, 0} -> strip_binprefix(out)             # runner emits exactly "b:<html>" (or "TRAP@fn")
      {out, s} -> "WASMERR:#{s}:#{String.slice(out, 0, 80)}"
    end
  end

  # the driver canonicalizes a bin result as "b:<bytes>"; strip the prefix to get raw HTML.
  defp strip_binprefix("b:" <> rest), do: rest
  defp strip_binprefix(other), do: other

  defp show_diff(vm, wasm) do
    i = Enum.find(0..(min(byte_size(vm), byte_size(wasm)) - 1), fn i -> :binary.at(vm, i) != :binary.at(wasm, i) end)
    IO.puts("     first diff at byte #{i}:")
    IO.puts("       vm:   ...#{String.slice(vm, max(0, (i || 0) - 20), 60) |> inspect()}")
    IO.puts("       wasm: ...#{String.slice(wasm, max(0, (i || 0) - 20), 60) |> inspect()}")
  end

  defp bench(wasmf, _watf) do
    benchf = Path.join(@tmp, "bench.mjs")
    File.write!(benchf, bench_js())
    {out, 0} = System.cmd(@node, [benchf, wasmf], stderr_to_stdout: true)
    IO.puts("\n  Bench (Wasm, network-free):\n#{out}")
  end

  defp bench_js do
    """
    import fs from "node:fs";
    import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, memFsBacking } from "#{Path.join(@here, "../../runtime/imports.mjs")}";
    const big = makeBig(), math = makeMath(); let e; const str = makeStr(() => e);
    const { proc, sched } = makeProcStubs();
    const bytes = fs.readFileSync(process.argv[2]);
    let t = performance.now(); const mod = new WebAssembly.Module(bytes); const tc = performance.now()-t;
    t = performance.now(); e = new WebAssembly.Instance(mod, { big, math, str, proc, sched, fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e) }).exports; const ti = performance.now()-t;
    for (let i=0;i<200;i++) e.render(i);              // warm
    const N = 20000; t = performance.now(); for (let i=0;i<N;i++) e.render(i); const dt = performance.now()-t;
    console.log("    module_compile=" + tc.toFixed(1) + "ms  instantiate=" + ti.toFixed(2) + "ms");
    console.log("    " + (dt/N*1000).toFixed(1) + " µs/render   " + Math.round(N/(dt/1000)).toLocaleString() + " renders/sec");
    """
  end
end

MdDemo.main()
