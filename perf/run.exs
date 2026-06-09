#!/usr/bin/env elixir
# perf/run.exs — differential performance harness. For each workload it compiles the Elixir module
# to WasmGC (with -g so the profile carries real names), times the WasmGC build (median us/op over
# K trials) AND the real Elixir VM in-process, prints the ratio + a self-time/host-call attribution,
# and saves/diffs a baseline so any compiler change shows a SIGNED delta. Zero guessing.
#
#   elixir run.exs                 # run all workloads, print table + attribution
#   elixir run.exs --save          # also write perf/baseline.json
#   elixir run.exs --baseline      # diff current vs perf/baseline.json (regression gate)
Code.require_file("jason0.exs", __DIR__)

Code.require_file("../tooling.exs", __DIR__)

defmodule Perf do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../compiler/beam2wasm.exs")
  @measure Path.join(@here, "measure.mjs")
  @tmp Path.join(@here, "_work")
  @baseline Path.join(@here, "baseline.json")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()
  @iters 1500
  @trials 12

  # A workload: an Elixir module + the modules it needs + the entry signature + representative cases.
  # `run(seed, nops)` does `nops` random ledger ops, so one call is a meaty macro-op.
  def workloads do
    [
      %{name: "ledger/500", src: File.read!(Path.join(@here, "../fuzz/ledger.ex")),
        extra: [Map, Enum, Keyword, :lists, :maps],
        exports: "run:int,int->int",
        cases: [%{name: "run", args: [%{type: "int", val: 1}, %{type: "int", val: 500}]},
                %{name: "run", args: [%{type: "int", val: 1337}, %{type: "int", val: 500}]},
                %{name: "run", args: [%{type: "int", val: 271_828}, %{type: "int", val: 500}]}]}
    ]
  end

  def main(argv) do
    File.mkdir_p!(@tmp)
    save = "--save" in argv
    diff = "--baseline" in argv
    base = if diff and File.exists?(@baseline), do: Jason0.decode(File.read!(@baseline)), else: %{}

    IO.puts("\n══════════ PERF: compiled Elixir (WasmGC) vs the Elixir VM ══════════\n")
    IO.puts("  #{pad("workload", 16)}#{pad("Wasm us/op", 14)}#{pad("BEAM us/op", 14)}#{pad("ratio", 8)}delta")
    IO.puts("  " <> String.duplicate("─", 64))

    results =
      Enum.map(workloads(), fn w ->
        {wasmf, casesf, mod} = build(w)
        beam = time_beam(mod, w.cases)
        meas = measure(wasmf, casesf)
        wasm = meas["us_per_call_median"]
        ratio = Float.round(wasm / beam, 1)
        delta = case base[w.name] do
          %{"wasm" => old} when is_number(old) -> sign((wasm - old) / old * 100)
          _ -> ""
        end
        IO.puts("  #{pad(w.name, 16)}#{pad(fmt(wasm), 14)}#{pad(fmt(beam), 14)}#{pad("#{ratio}x", 8)}#{delta}")
        {w, meas, %{name: w.name, wasm: wasm, beam: beam}}
      end)

    IO.puts("")
    for {w, meas, _} <- results, do: attribution(w, meas)

    if save do
      snap = Enum.map(results, fn {_, _, s} -> {s.name, %{wasm: s.wasm, beam: s.beam}} end) |> Map.new()
      File.write!(@baseline, Jason0.encode(snap))
      IO.puts("  baseline saved -> #{Path.relative_to_cwd(@baseline)}\n")
    end
  end

  defp build(w) do
    compiled = Code.compile_string(w.src)
    [{mod, _} | _] = compiled
    beams = Enum.map(compiled, fn {m, b} -> p = Path.join(@tmp, "#{m}.beam"); File.write!(p, b); p end)
    extra = Enum.map(w.extra, fn m -> to_string(:code.which(m)) end)
    watf = Path.join(@tmp, "#{mod}.wat")
    wasmf = Path.join(@tmp, "#{mod}.wasm")
    stubf = Path.join(@tmp, "#{mod}.stubs.txt")
    cmd = "elixir #{inspect(@beam2wasm)} #{Enum.map_join(beams ++ extra, " ", &inspect/1)} > #{inspect(watf)} 2> #{inspect(stubf)}"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", w.exports}, {"STUB", "1"}, {"BIGNUM", "1"}])
    case Regex.run(~r/STUBS:\s+(\d+)/, File.read!(stubf)) do
      [_, "0"] -> :ok
      [_, n] -> IO.puts("  ⚠️  #{w.name}: #{n} reachable stubs — measuring partially-stubbed code!")
      _ -> :ok
    end
    # -g keeps the name section so the V8 profile shows int_mul/term_compare/Ledger.run, not wasm-function[N].
    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf, ["-g"]), stderr_to_stdout: true)
    casesf = Path.join(@tmp, "#{mod}.cases.json")
    File.write!(casesf, Jason0.encode(w.cases))
    {wasmf, casesf, mod}
  end

  # time the real VM in-process: K trials of N iters over the cases, median us/op.
  defp time_beam(mod, cases) do
    calls = Enum.map(cases, fn c -> {String.to_atom(c.name), Enum.map(c.args, & &1.val)} end)
    pass = fn -> Enum.reduce(calls, 0, fn {f, a}, acc -> acc + rem(apply(mod, f, a), 7) end) end
    Enum.each(1..300, fn _ -> pass.() end)                       # warmup
    trials =
      for _ <- 1..@trials do
        {us, _} = :timer.tc(fn -> Enum.each(1..@iters, fn _ -> pass.() end) end)
        us / (@iters * length(cases))
      end
      |> Enum.sort()
    Enum.at(trials, div(@trials, 2))
  end

  defp measure(wasmf, casesf) do
    {out, 0} = System.cmd(@node, [@measure, wasmf, casesf, "--iters", "#{@iters}",
      "--trials", "#{@trials}", "--profile", "--json"])
    Jason0.decode(out)
  end

  defp attribution(w, meas) do
    IO.puts("  ── #{w.name} ──")
    tot = meas["host_total_per_op"]
    if tot do
      IO.puts("     host-boundary (bignum-tier) calls/op: #{fmt(tot)}")
      meas["host_calls_per_op"] |> Enum.take(6)
      |> Enum.each(fn {k, v} -> IO.puts("        #{pad(fmt(v), 10)}big.#{k}") end)
    end
    if meas["profile"] do
      IO.puts("     self-time (top):")
      IO.puts("        self%   category   function")
      Enum.take(meas["profile"], 14)
      |> Enum.each(fn r -> IO.puts("        #{pad(fmt(r["self_pct"]), 8)}#{pad(r["cat"], 11)}#{r["name"]}") end)
    end
    IO.puts("")
  end

  defp pad(s, n), do: String.pad_trailing(to_string(s), n)
  defp fmt(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 3)
  defp fmt(x), do: to_string(x)
  defp sign(p) when p > 0, do: "+#{Float.round(p, 1)}%"
  defp sign(p), do: "#{Float.round(p, 1)}%"
end


Perf.main(System.argv())
