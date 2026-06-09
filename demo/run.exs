#!/usr/bin/env elixir
# The experiment: run the SAME real Req program on the Elixir VM and on WasmGC, fed the SAME captured
# response, and diff the output. Equal ⇒ the compiler ran a real Req program correctly. Unequal (with
# identical input) ⇒ a compiler bug. The HTTP effect is captured ONCE and held constant across engines.
Mix.install([{:req, "~> 0.5"}])

defmodule Demo do
  @here Path.dirname(__ENV__.file)
  @root Path.expand("..", @here)
  @url "https://resy.com"
  @node System.get_env("NODE", "/Users/ivar/.nvm/versions/node/v24.16.0/bin/node")
  @wasmas System.find_executable("wasm-as") || "/opt/homebrew/bin/wasm-as"
  # Resy reaches String/Enum/List; DCE keeps only what it touches.
  @extra [Enum, String, List, Integer, Map, Keyword, Range, :lists, :maps, :binary, :unicode]

  def main do
    File.mkdir_p!(Path.join(@here, "_work"))

    # ── 1. Capture the effect ONCE: real Req, real socket, real gzip-decode. This is the only fetch. ──
    IO.puts("→ fetching #{@url} once via real Req …")
    body = Req.get!(@url).body
    fixture = Path.join(@here, "_work/resy_body.html")
    File.write!(fixture, body)
    IO.puts("  captured #{byte_size(body)} bytes → #{Path.relative_to(fixture, @root)}\n")

    # ── 2. Engine A — the Elixir VM. Real Req, transport stubbed to the captured body (no socket). ──
    stub = struct(Req.Response, status: 200, body: File.read!(fixture), headers: %{})
    Req.default_options(adapter: fn req -> {req, stub} end)
    [{Resy, beam} | _] = Code.compile_file(Path.join(@here, "resy.exs")) |> Enum.filter(&(elem(&1, 0) == Resy))
    vm_out = Resy.run()

    # ── 3. Engine B — WasmGC. Compile Resy (Req.get!/1 shimmed to the host) and run it. ──
    wasm = build_wasm(beam)
    {wasm_out, 0} = System.cmd(@node, [Path.join(@here, "runner.mjs"), wasm, fixture])

    # ── 4. Compare. ──
    report(vm_out, wasm_out)
  end

  defp build_wasm(beam) do
    b2w = Path.join(@root, "compiler/beam2wasm.exs")
    bf = Path.join(@here, "_work/Elixir.Resy.beam"); File.write!(bf, beam)
    extra = @extra |> Enum.map(&to_string(:code.which(&1))) |> Enum.filter(&String.ends_with?(&1, ".beam"))
    wat = Path.join(@here, "_work/resy.wat"); wasm = Path.join(@here, "_work/resy.wasm")
    stub = Path.join(@here, "_work/resy.stub")
    cmd = "elixir #{inspect(b2w)} #{Enum.map_join([bf | extra], " ", &inspect/1)} > #{inspect(wat)} 2> #{inspect(stub)}"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "run:->bin"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    IO.puts("→ compiled Resy → WasmGC (#{Regex.run(~r/STUBS: \d+/, File.read!(stub)) |> List.first()})")
    {_, 0} = System.cmd(@wasmas, [wat, "-o", wasm, "-all", "--disable-custom-descriptors", "-g"], stderr_to_stdout: true)
    wasm
  end

  defp report(vm, wasm) do
    IO.puts("\n── Elixir VM ──\n#{vm}")
    IO.puts("\n── WasmGC ──\n#{wasm}")
    IO.puts("\n" <> String.duplicate("═", 60))
    if vm == wasm do
      n = vm |> String.split("\n", trim: true) |> length()
      IO.puts("✅ IDENTICAL — same real Req program, VM == WasmGC, #{n} JS URLs, bit-for-bit.")
    else
      IO.puts("❌ DIFFER — compiler bug (input was identical).")
    end
  end
end

Demo.main()
