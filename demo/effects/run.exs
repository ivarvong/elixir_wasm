#!/usr/bin/env elixir
# Differential harness for the effects ABI: the SAME compiled Elixir does File.read / File.write /
# IO.puts on the VM (real filesystem, captured stdout) and on WasmGC (VIRTUAL in-memory fs, captured
# console). Compares: the return value, the WRITTEN FILE's exact bytes, and the printed lines.
#   elixir run.exs
Code.require_file("../../tooling.exs", __DIR__)

defmodule EffectsDemo do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../../compiler/beam2wasm.exs")
  @runner Path.join(@here, "runner.mjs")
  @tmp Path.join(@here, "_work")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()
  @fixture "hello from the edge\nline two: file IO is a HOST effect\n"

  def main do
    File.mkdir_p!(@tmp)
    fixture_path = Path.join(@tmp, "input.txt")
    File.write!(fixture_path, @fixture)

    IO.puts("\n══════════ EFFECTS ABI: File/IO -> host (virtual fs), Wasm vs the VM ══════════\n")

    {vm_result, vm_output, vm_stdout} = vm_run(fixture_path)
    {wasm_result, wasm_output, wasm_stdout} = wasm_run(fixture_path)

    rows = [
      {"return value", vm_result, wasm_result},
      {"written file bytes", vm_output, wasm_output},
      {"printed lines", vm_stdout, wasm_stdout}
    ]
    ok =
      Enum.reduce(rows, true, fn {label, vm, wasm}, acc ->
        match = vm == wasm
        IO.puts("  #{if match, do: "✅", else: "❌"} #{label}: #{if match, do: "identical", else: "VM=#{inspect(vm)} WASM=#{inspect(wasm)}"}")
        acc and match
      end)

    IO.puts("")
    if ok do
      IO.puts("  ✅ The compiled program performed REAL file + console IO through the host effects ABI,")
      IO.puts("     byte-identical to the VM (Wasm side ran on a virtual in-memory filesystem).")
    else
      System.halt(1)
    end
  end

  # VM oracle: run in a scratch dir with data/input.txt on the REAL fs; capture stdout (the program's
  # IO.puts lines + the result we print last).
  defp vm_run(fixture_path) do
    dir = Path.join(@tmp, "vm_root")
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "data"))
    File.cp!(fixture_path, Path.join(dir, "data/input.txt"))
    src = Path.join(@here, "effects.ex")
    {out, 0} =
      System.cmd("elixir", ["-e", "Code.require_file(#{inspect(src)}); IO.puts(Effects.run(0))"], cd: dir)
    lines = out |> String.trim_trailing("\n") |> String.split("\n")
    {result, stdout} = {List.last(lines), Enum.drop(lines, -1)}
    output = File.read!(Path.join(dir, "data/output.txt")) |> Base.encode16(case: :lower)
    {result, output, stdout}
  end

  # Wasm: compile (program + File/IO/stdlib beams), run on the virtual fs runner.
  defp wasm_run(fixture_path) do
    src = Path.join(@here, "effects.ex")
    [{mod, bin} | _] = Code.compile_string(File.read!(src))
    beam = Path.join(@tmp, "#{mod}.beam")
    File.write!(beam, bin)
    extra =
      [File, IO, Kernel, Exception, ArgumentError, String, String.Break, Enum, Map, Keyword, :lists, :maps]
      |> Enum.map(fn m -> Code.ensure_loaded(m); to_string(:code.which(m)) end)
      |> Enum.filter(&String.ends_with?(&1, ".beam"))
    watf = Path.join(@tmp, "effects.wat")
    wasmf = Path.join(@tmp, "effects.wasm")
    cmd = "elixir #{inspect(@beam2wasm)} #{Enum.map_join([beam | extra], " ", &inspect/1)} > #{inspect(watf)} 2>/dev/null"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "run:int->int"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf, ["-g"]), stderr_to_stdout: true)
    {out, 0} = Tooling.cmd(@node, [@runner, wasmf, "0", fixture_path])
    decode(out)
  end

  # minimal JSON pick (the runner emits flat JSON with known keys)
  defp decode(json) do
    if String.contains?(json, "\"trap\"") do
      raise "wasm trapped: #{json}"
    end
    result = capture(json, ~r/"result":"([^"]*)"/)
    output = capture(json, ~r/"output_hex":"([^"]*)"/)
    stdout = Regex.scan(~r/"((?:[^"\\]|\\.)*)"/, capture(json, ~r/"stdout":\[([^\]]*)\]/) || "")
             |> Enum.map(fn [_, s] -> s end)
    {result, output, stdout}
  end

  defp capture(s, re) do
    case Regex.run(re, s) do
      [_, v] -> v
      _ -> nil
    end
  end
end

EffectsDemo.main()
