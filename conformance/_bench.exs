# Shared steady-state scoreboard for the JSON workloads, reusing each script's already-built wasm +
# loaded Target module so Wasm and BEAM are measured the SAME way. Reports both TIME (median us/op)
# and ALLOCATION (bytes/op) — Wasm allocation via perf/alloc.mjs (--trace-gc), BEAM allocation via
# GC-reclaimed words (≈ allocated, steady state). Gated by BENCH=1.
defmodule Bench do
  @node System.get_env("NODE", "/Users/ivar/.nvm/versions/node/v24.16.0/bin/node")
  @perf Path.join(Path.dirname(__ENV__.file), "../perf")
  @iters 1000
  @trials 11

  def report(label, mod, entry, inputs, wasmf, casesf) do
    pass = fn -> Enum.reduce(inputs, 0, fn x, acc -> acc + rem(apply(mod, entry, [x]), 7) end) end
    Enum.each(1..200, fn _ -> pass.() end)                     # warmup
    beam_us =
      for(_ <- 1..@trials, do: (fn -> {us, _} = :timer.tc(fn -> Enum.each(1..@iters, fn _ -> pass.() end) end); us / (@iters * length(inputs)) end).())
      |> Enum.sort() |> Enum.at(div(@trials, 2))
    wasm = json(System.cmd(@node, [Path.join(@perf, "measure.mjs"), wasmf, casesf, "--iters", "#{@iters}", "--trials", "#{@trials}", "--json"]))
    wasm_us = num(wasm["us_per_call_median"])

    # allocation: BEAM = GC-reclaimed words delta over a heavy run (≈ bytes allocated in steady state)
    n = 4000
    :erlang.garbage_collect()
    {_, w0, _} = :erlang.statistics(:garbage_collection)
    Enum.each(1..n, fn _ -> Enum.each(inputs, fn x -> apply(mod, entry, [x]) end) end)
    {_, w1, _} = :erlang.statistics(:garbage_collection)
    beam_bytes = (w1 - w0) * 8 / (n * length(inputs))
    wa = json(System.cmd(@node, [Path.join(@perf, "alloc.mjs"), wasmf, casesf, "--json"]))
    wasm_bytes = num(wa["bytes_per_op"])

    tr = ratio(wasm_us, beam_us)
    ar = ratio(wasm_bytes, beam_bytes)
    IO.puts("\n  ⏱  #{String.pad_trailing(label, 18)} time: Wasm #{f(wasm_us)}us  BEAM #{f(beam_us)}us  #{tr}×" <>
            "    alloc: Wasm #{bytes(wasm_bytes)}  BEAM #{bytes(beam_bytes)}  #{ar}×  [#{length(inputs)} inputs]\n")
  end

  defp ratio(a, b), do: if(b > 0, do: Float.round(a / b, 1), else: 0.0)
  defp f(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
  defp bytes(x) when x >= 1_000_000, do: "#{Float.round(x / 1_048_576, 1)}MB"
  defp bytes(x) when x >= 1000, do: "#{Float.round(x / 1024, 1)}KB"
  defp bytes(x), do: "#{Float.round(x * 1.0, 0)}B"
  defp num(v) when is_number(v), do: v
  defp num(_), do: 0.0
  defp json({out, 0}) do
    case Regex.scan(~r/"([a-z_]+)":([0-9.eE+-]+)/, out) do
      [] -> %{}
      pairs -> Map.new(pairs, fn [_, k, v] -> {k, elem(Float.parse(v), 0)} end)
    end
  end
  defp json(_), do: %{}
end
