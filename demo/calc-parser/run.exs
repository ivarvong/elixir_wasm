#!/usr/bin/env elixir
# demo/calc-parser — a recursive-descent arithmetic parser on WasmGC, built on the REAL unmodified
# nimble_parsec combinator library (+ Jason for the AST->JSON response). Parses a batch of expressions
# (precedence, parens, left-assoc, error cases) on Wasm AND the VM and asserts the JSON is BYTE-IDENTICAL.
#   cd demo/calc-parser && elixir run.exs        (the app/ mix project must compile: cd app && mix compile)
Code.require_file("../../tooling.exs", __DIR__)

defmodule CalcDemo do
  @here Path.dirname(__ENV__.file)
  @app Path.join(@here, "app")
  @beam2wasm Path.join(@here, "../../beam2wasm.exs")
  @tmp Path.join(@here, "_work")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()
  @runner Path.join(@here, "runner.mjs")

  # precedence, parentheses, left-associativity, deep nesting, and error paths
  @exprs ["1+2*3", "(1+2)*3", "2*3+4*5", "1+2+3+4", "((1))", "10*20+30", "100/5/2",
          "(1+(2*(3+4)))", "1+2*3-4/2", "1+", "()", "1++2", "9*"]

  def main do
    File.mkdir_p!(@tmp)
    ensure_compiled!()
    {wasmf, watf} = build_wasm()
    IO.puts("\n══════════ CALC PARSER: real nimble_parsec recursive grammar, WasmGC vs the VM ══════════\n")

    results =
      Enum.map(@exprs, fn s ->
        vm = vm_parse(s)
        wasm = wasm_parse(wasmf, s)
        ok = vm == wasm
        IO.puts("  #{if ok, do: "✅", else: "❌"} #{String.pad_trailing(inspect(s), 18)} #{vm}")
        unless ok, do: IO.puts("       wasm: #{wasm}")
        ok
      end)

    pass = Enum.count(results, & &1)
    IO.puts("\n  #{pass}/#{length(@exprs)} expressions BYTE-IDENTICAL (real nimble_parsec recursive parse -> JSON AST)")
    _ = watf
    if pass == length(@exprs), do: :ok, else: System.halt(1)
  end

  defp ensure_compiled!() do
    env = [{"MIX_ENV", "dev"}]
    {_, 0} = System.cmd("mix", ["deps.get"], cd: @app, stderr_to_stdout: true, env: env)
    {_, 0} = System.cmd("mix", ["compile"], cd: @app, stderr_to_stdout: true, env: env)
  end

  defp calc_beam, do: Path.join(@app, "_build/dev/lib/calc/ebin/Elixir.Calc.beam")
  defp dep_beams(dep), do: Path.wildcard(Path.join(@app, "_build/dev/lib/#{dep}/ebin/*.beam"))

  # Stdlib the parser + Jason reach. Omit modules the compiler already shims (Regex/:re/:binary/
  # :unicode/:math/:string) — feeding them double-defines host-shimmed functions.
  defp stdlib_beams do
    [Kernel, Exception, Enum, String, String.Break, String.Chars, List, Map, MapSet, Keyword, Integer,
     Float, Tuple, Range, Enumerable, Collectable, Inspect, Inspect.Algebra, Access,
     ArgumentError, RuntimeError, KeyError, :lists, :maps, :sets, :ordsets,
     Enumerable.List, Enumerable.Map, Enumerable.Range, Enumerable.MapSet,
     Collectable.List, Collectable.Map, Collectable.MapSet,
     String.Chars.Integer, String.Chars.Float, String.Chars.List, String.Chars.BitString, String.Chars.Atom]
    |> Enum.map(fn m -> Code.ensure_loaded(m); to_string(:code.which(m)) end)
    |> Enum.filter(&String.ends_with?(&1, ".beam"))
  end

  defp consolidated_beams, do: Path.wildcard(Path.join(@app, "_build/dev/lib/calc/consolidated/*.beam"))

  # Prefer consolidated protocol impls over system copies, preserving order (Calc must stay first —
  # the compiler takes the primary module from hd(beams)).
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
    watf = Path.join(@tmp, "calc.wat")
    wasmf = Path.join(@tmp, "calc.wasm")

    beams =
      ([calc_beam() | dep_beams("nimble_parsec")] ++ dep_beams("jason") ++ stdlib_beams() ++ consolidated_beams())
      |> dedup_prefer_consolidated()

    cmd = "elixir #{inspect(@beam2wasm)} #{Enum.map_join(beams, " ", &inspect/1)} > #{inspect(watf)} 2>#{inspect(watf <> ".stub")}"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "parse:bin->bin"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf, ["-g"]), stderr_to_stdout: true)
    IO.puts("  built #{Float.round(File.stat!(wasmf).size / 1024, 0)} KB wasm from #{length(beams)} beams (Calc + real nimble_parsec + Jason + stdlib)")
    {wasmf, watf}
  end

  defp vm_parse(expr) do
    # --no-compile: ensure_compiled!/0 already built the app; without it, a cold `mix run` prints a
    # "==> <dep>" compile banner to stdout (the app depends on :beam2wasm) that pollutes the captured
    # parse output and makes every case mismatch.
    {out, 0} =
      System.cmd("mix", ["run", "--no-compile", "-e", "IO.write(Calc.parse(hd(System.argv())))", expr],
        cd: @app, env: [{"MIX_ENV", "dev"}])

    out
  end

  defp wasm_parse(wasmf, expr) do
    case Tooling.cmd(@node, [@runner, wasmf, expr]) do
      {"b:" <> json, 0} -> json
      {out, s} -> "WASMERR:#{s}:#{String.slice(out, 0, 80)}"
    end
  end
end

CalcDemo.main()
