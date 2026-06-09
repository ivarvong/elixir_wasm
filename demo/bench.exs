#!/usr/bin/env elixir
# Benchmark the REAL Req program on both engines, NETWORK-FREE (the fetch was captured once; both replay
# the same in-memory bytes). Reuses demo/_work/real.wasm + the fixture from a prior `elixir demo/run_real.exs`.
Mix.install([{:req, "~> 0.5"}])

Code.require_file("../tooling.exs", __DIR__)

defmodule Bench do
  @here Path.dirname(__ENV__.file)
  @node Tooling.node!()

  def main do
    wasm = Path.join(@here, "_work/real.wasm")
    fixture = Path.join(@here, "_work/resy_body.html")
    unless File.exists?(wasm) and File.exists?(fixture),
      do: (IO.puts("run `elixir demo/run_real.exs` first (builds real.wasm + captures the fixture)."); System.halt(1))

    # ── WasmGC ──
    {json, 0} = System.cmd(@node, [Path.join(@here, "bench.mjs"), wasm, fixture])
    w = Jason.decode!(json)

    # ── Elixir VM (real Req, adapter stubbed to the same bytes; no socket) ──
    stub = struct(Req.Response, status: 200, headers: %{"content-type" => ["text/html; charset=utf-8"]}, body: File.read!(fixture))
    Req.default_options(adapter: fn req -> {req, stub} end)
    [{Resy, _} | _] = Code.compile_file(Path.join(@here, "resy.exs")) |> Enum.filter(&(elem(&1, 0) == Resy))
    for _ <- 1..200, do: Resy.run()                       # warm
    n = 5000
    {us, _} = :timer.tc(fn -> for _ <- 1..n, do: Resy.run() end)
    vm_per_run_us = Float.round(us / n, 2)

    IO.puts("\n══════ REAL Req — network-free compute (#{w["runs"]} runs each) ══════\n")
    IO.puts("  wasm module size      #{Float.round(w["wasm_bytes"] / 1024, 0) |> trunc()} KB (unoptimized, -g)")
    IO.puts("  WASM compile+instantiate (one-time)  #{w["module_compile_ms"]} + #{w["instantiate_ms"]} ms")
    IO.puts(String.duplicate("  ─", 28))
    IO.puts("  WasmGC  per run   #{pad(w["per_run_us"])} µs   (#{w["runs_per_sec"]} runs/s)")
    IO.puts("  BEAM    per run   #{pad(vm_per_run_us)} µs   (#{round(1_000_000 / vm_per_run_us)} runs/s)")
    ratio = Float.round(w["per_run_us"] / vm_per_run_us, 2)
    IO.puts("\n  WasmGC is #{ratio}× the BEAM's time#{if ratio < 1, do: "  (faster!)", else: ""}  — same real Req pipeline, no network.")
  end

  defp pad(x), do: String.pad_leading("#{x}", 8)
end

Bench.main()
