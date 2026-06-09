#!/usr/bin/env elixir
# MEASURE what "running the real Req" costs: compile the program with the FULL real Req dependency graph
# (req + finch + mint + hpax + jason + mime + nimble_options + nimble_pool + telemetry), no Req-level shim.
# DCE keeps only what Req.get!/1 actually reaches. Report: functions kept, stub count, and the stub list
# (the irreducible effect surface — the transport NIFs — plus whatever stdlib/features we don't yet support).
Mix.install([{:req, "~> 0.5"}])

defmodule Measure do
  @here Path.dirname(__ENV__.file)
  @root Path.expand("..", @here)

  def main do
    File.mkdir_p!(Path.join(@here, "_work"))
    lib = :code.which(Req) |> to_string() |> String.replace(~r"/req/ebin/.*$", "")
    dep_beams = Path.wildcard(Path.join(lib, "*/ebin/*.beam"))
    IO.puts("Req graph: #{length(dep_beams)} dependency beams from #{Path.relative_to(lib, System.user_home!())}")

    # the program: Req.get! then pull JS URLs (same as demo/resy.exs)
    [{Resy, beam} | _] = Code.compile_file(Path.join(@here, "resy.exs")) |> Enum.filter(&(elem(&1, 0) == Resy))
    bf = Path.join(@here, "_work/Elixir.Resy.beam"); File.write!(bf, beam)
    # stdlib Req leans on (DCE prunes the rest)
    extra = [Enum, String, Map, Keyword, List, Range, Integer, Float, Tuple, Stream, Access, Bitwise,
             :lists, :maps, :proplists, :string, :binary, :unicode]
            |> Enum.map(&to_string(:code.which(&1))) |> Enum.filter(&String.ends_with?(&1, ".beam"))

    wat = Path.join(@here, "_work/req_full.wat"); stub = Path.join(@here, "_work/req_full.stub")
    cmd = "elixir #{inspect(Path.join(@root, "compiler/beam2wasm.exs"))} " <>
          Enum.map_join([bf] ++ dep_beams ++ extra, " ", &inspect/1) <>
          " > #{inspect(wat)} 2> #{inspect(stub)}"
    {_, code} = System.shell(cmd, env: [{"EXPORTS", "run:->bin"}, {"STUB", "1"}, {"BIGNUM", "1"}])

    log = File.read!(stub)
    IO.puts("\n── compiler report ──")
    for line <- String.split(log, "\n"), line =~ ~r/DCE:|STUBS:/, do: IO.puts("  " <> line)
    IO.puts("  exit #{code}")

    if File.exists?(wat) do
      w = File.read!(wat)
      ext = Regex.scan(~r/;; stub: external (\S+)/, w) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()
      ops = Regex.scan(~r/;; STUB ([a-z_]\S*)/, w) |> Enum.map(&Enum.at(&1, 1)) |> Enum.frequencies()
      IO.puts("\n── irreducible / unsupported surface (#{length(ext)} external stubs) ──")
      ext |> Enum.sort() |> Enum.each(&IO.puts("   • #{&1}"))
      if ops != %{} do
        IO.puts("\n── unsupported OPCODES in reachable fns (#{map_size(ops)}) ──")
        ops |> Enum.sort_by(fn {_, c} -> -c end) |> Enum.each(fn {o, c} -> IO.puts("   • #{o} [#{c}]") end)
      end
    end
  end
end

Measure.main()
