#!/usr/bin/env elixir
# verify.exs — THE verification manifest: every differential suite, one command, pinned floors.
#
#   elixir verify.exs          # run everything, print the manifest table, exit 1 on ANY drop
#   elixir verify.exs fast     # skip the slow suites (scoreboard, head-to-head)
#
# Each suite proves a different axis bit-exact vs the real Elixir VM:
#   conformance — curated per-feature cases across every term type & runtime mode
#   fuzz        — randomized ledger service, rolling-hash diff
#   gaps        — 20 realistic programs, 0 stubs = provably supported
#   genfuzz     — GENERATIVE random programs over the full term algebra
#   regexdiff   — the :re shim corpus; every divergence classified, zero lies
#   scoreboard  — every public function of ten stdlib modules
#   markdown    — real unmodified Jason + Earmark, byte-identical HTML
#   effects     — File/IO through the host-effects ABI vs the real fs
#
# Floors are EXPECTED counts: raising them when suites grow is part of landing the change.
Code.require_file("tooling.exs", __DIR__)

defmodule Verify do
  @here Path.dirname(__ENV__.file)

  # {name, dir, args, floor-regex (must match stdout), slow?}
  @suites [
    {"conformance", "conformance", [], ~r/TOTAL: 219\/219 cases bit-exact/, false},
    {"fuzz", "fuzz", [], ~r/TOTAL: 33\/33 cases bit-exact/, false},
    {"gaps", "gaps", [], ~r/20\/20 programs PROVABLY CORRECT/, false},
    {"genfuzz", "genfuzz", [], ~r/12\/12 programs bit-exact/, false},
    {"regexdiff", "regexdiff", [], ~r/0 LIES/, false},
    {"scoreboard", "scoreboard", [], ~r/389\/389 bit-exact \(100\.0%\)/, true},
    {"markdown", "demo/markdown", [], ~r/3\/3 pages BYTE-IDENTICAL/, true},
    {"effects", "demo/effects", [], ~r/byte-identical to the VM/, false}
  ]

  def main(args) do
    fast = "fast" in args
    suites = if fast, do: Enum.reject(@suites, fn {_, _, _, _, slow} -> slow end), else: @suites
    IO.puts("\n══════════ VERIFY: the full differential manifest vs the real Elixir VM ══════════\n")
    t0 = System.monotonic_time(:millisecond)

    results =
      Enum.map(suites, fn {name, dir, sargs, floor, _} ->
        t = System.monotonic_time(:millisecond)
        {out, code} = System.cmd("elixir", ["run.exs" | sargs],
          cd: Path.join(@here, dir), stderr_to_stdout: true, env: [])
        dt = System.monotonic_time(:millisecond) - t
        ok = code == 0 and Regex.match?(floor, out)
        line = out |> String.split("\n") |> Enum.find(fn l -> Regex.match?(floor, l) end)
        IO.puts("  #{if ok, do: "✅", else: "❌"} #{String.pad_trailing(name, 13)} #{String.pad_leading("#{div(dt, 1000)}s", 5)}  #{String.trim(line || "FLOOR NOT MET (exit #{code})")}")
        unless ok do
          IO.puts(String.duplicate("─", 80))
          IO.puts(out |> String.split("\n") |> Enum.take(-25) |> Enum.join("\n"))
          IO.puts(String.duplicate("─", 80))
        end
        ok
      end)

    total = System.monotonic_time(:millisecond) - t0
    pass = Enum.count(results, & &1)
    IO.puts("\n  " <> String.duplicate("─", 76))
    IO.puts("  #{pass}/#{length(results)} suites at or above their pinned floors  (#{div(total, 1000)}s total)")
    if pass == length(results) do
      IO.puts("  ALL GREEN — any pure Elixir runs here, and this is the measurement.\n")
    else
      System.halt(1)
    end
  end
end

Verify.main(System.argv())
