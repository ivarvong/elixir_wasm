#!/usr/bin/env elixir
# REAL Req: compile the program with the full Req dependency graph (3609 fns) and override only the
# adapter (Req.Finch.run/1 → the host). The genuine Req pipeline — option merging, request steps, the
# whole response decode — runs on WasmGC. Diff vs the VM (also real Req, adapter stubbed to the same body).
Mix.install([{:req, "~> 0.5"}])

Code.require_file("../tooling.exs", __DIR__)

defmodule RunReal do
  @here Path.dirname(__ENV__.file)
  @root Path.expand("..", @here)
  @url "https://resy.com"
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()

  def main do
    File.mkdir_p!(Path.join(@here, "_work"))
    lib = :code.which(Req) |> to_string() |> String.replace(~r"/req/ebin/.*$", "")
    dep_beams = Path.wildcard(Path.join(lib, "*/ebin/*.beam"))

    IO.puts("→ fetching #{@url} once via real Req …")
    body = Req.get!(@url).body
    fixture = Path.join(@here, "_work/resy_body.html"); File.write!(fixture, body)
    IO.puts("  captured #{byte_size(body)} bytes\n")

    # Engine A — VM: real Req, adapter stubbed to the captured body (the genuine pipeline, no socket).
    stub = struct(Req.Response, status: 200, headers: %{"content-type" => ["text/html; charset=utf-8"]}, body: File.read!(fixture))
    Req.default_options(adapter: fn req -> {req, stub} end)
    [{Resy, beam} | _] = Code.compile_file(Path.join(@here, "resy.exs")) |> Enum.filter(&(elem(&1, 0) == Resy))
    vm_out = Resy.run()

    # Engine B — WasmGC: compile the FULL real Req graph; only Req.Finch.run/1 (the adapter) is overridden.
    wasm = build(beam, dep_beams)
    {wasm_out, 0} = System.cmd(@node, [Path.join(@here, "runner.mjs"), wasm, fixture])

    IO.puts("\n── Elixir VM (real Req) ──\n#{vm_out}")
    IO.puts("\n── WasmGC (real Req, adapter→host) ──\n#{wasm_out}")
    IO.puts("\n" <> String.duplicate("═", 60))
    IO.puts(if vm_out == wasm_out,
      do: "✅ IDENTICAL — the genuine 3609-fn Req pipeline ran on WasmGC, bit-for-bit == the VM.",
      else: "❌ DIFFER (input was identical → compiler bug):\n  vm=#{inspect(vm_out)}\n  wasm=#{inspect(wasm_out)}")
  end

  defp build(beam, dep_beams) do
    bf = Path.join(@here, "_work/Elixir.Resy.beam"); File.write!(bf, beam)
    extra = [Enum, String, String.Break, String.Chars, Map, MapSet, Keyword, List, Range, Integer, Float,
             Tuple, Stream, Stream.Reducers, Enumerable, Enumerable.List, Enumerable.Map, Enumerable.Range,
             Collectable, Collectable.Map, Collectable.List, Access, Bitwise, URI, Kernel.Utils, Base, Path,
             :lists, :maps, :proplists, :sets, :ordsets, :string, :binary, :unicode, :uri_string, :filename]
            |> Enum.map(&to_string(:code.which(&1))) |> Enum.filter(&String.ends_with?(&1, ".beam"))
    wat = Path.join(@here, "_work/real.wat"); wasm = Path.join(@here, "_work/real.wasm")
    stub = Path.join(@here, "_work/real.stub")
    cmd = "elixir #{inspect(Path.join(@root, "compiler/beam2wasm.exs"))} " <>
          Enum.map_join([bf] ++ dep_beams ++ extra, " ", &inspect/1) <>
          " > #{inspect(wat)} 2> #{inspect(stub)}"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "run:->bin"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    log = File.read!(stub)
    IO.puts("→ compiled real Req → WasmGC  (#{Regex.run(~r/DCE: kept \d+ of \d+ functions/, log) |> List.first()}; " <>
            "#{Regex.run(~r/STUBS: \d+/, log) |> List.first()})")
    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(wat, wasm, ["-g"]), stderr_to_stdout: true)
    wasm
  end
end

RunReal.main()
