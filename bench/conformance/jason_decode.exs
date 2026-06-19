#!/usr/bin/env elixir

# Differential conformance for the real Jason decoder.
#
# This is intentionally separate from run.exs because it uses a Hex dependency. It compiles a
# checksum wrapper plus the real Jason beams to WasmGC, runs many JSON inputs through Wasm, and
# compares each result with the BEAM oracle.
#
#   elixir conformance/jason_decode.exs

Mix.install([{:jason, "~> 1.4"}], consolidate_protocols: false)

Code.require_file("../../tooling.exs", __DIR__)

defmodule JasonDecodeConf do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../../beam2wasm.exs")
  @driver Path.join(@here, "driver.mjs")
  @tmp Path.join(@here, "_work_jason_decode")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()

  @src """
  defmodule JasonDecodeTarget do
    def score(json) do
      {:ok, term} = Jason.decode(json)
      score_term(term)
    end

    defp score_term(nil), do: 3
    defp score_term(true), do: 5
    defp score_term(false), do: 7
    defp score_term(n) when is_integer(n), do: n * 13 + 1
    defp score_term(s) when is_binary(s), do: byte_size(s) * 17 + bytesum(s, 0)
    defp score_term(l) when is_list(l), do: score_list(l, 1)
    defp score_term(m) when is_map(m), do: score_pairs(:lists.sort(Map.to_list(m)), 11)

    defp score_list([], acc), do: acc * 19 + 2
    defp score_list([h | t], acc), do: score_list(t, acc * 31 + score_term(h))

    defp score_pairs([], acc), do: acc * 23 + 4
    defp score_pairs([{k, v} | t], acc), do: score_pairs(t, acc * 37 + score_term(k) * 3 + score_term(v))

    defp bytesum(<<>>, acc), do: acc
    defp bytesum(<<c, rest::binary>>, acc), do: bytesum(rest, acc + c)
  end
  """

  @jsons [
    "null",
    "true",
    "false",
    "0",
    "1",
    "-1",
    "12345",
    "-9876",
    ~s(""),
    ~s("abcdefghijklmnop"),
    ~s("abcdefghijklmnopqrstuvwxyz0123456789"),
    ~s("a\\nb"),
    ~s("quote: \\\" slash: \\\\ tab:\\t"),
    ~s("unicode: \\u00E9 \\u03BB"),
    "[]",
    "[1,2,3,4,5]",
    "[true,false,null]",
    ~s(["a","bb","ccc"]),
    ~s({"a":1,"b":[2,3],"c":true}),
    ~s({"nested":{"x":10,"y":[1,false,null,"z"]}}),
    ~s({"spaces" : [ 1 , 2 , { "k" : "v" } ] }),
    ~s({"dup":1,"dup":2,"dup":3}),
    ~s({"empty_obj":{},"empty_arr":[],"empty_str":""}),
    ~s([{"id":1,"tags":["red","blue"]},{"id":2,"tags":[]}]),
    ~s({"matrix":[[1,2],[3,4],[5,6]],"ok":false}),
    ~s({"deep":[{"a":[{"b":[{"c":9}]}]}]}),
    ~s({"escapes":"\\b\\f\\n\\r\\t"}),
    ~s({"mix":[0,-1,2,-3,4],"bool":true,"nil":null,"str":"hello"}),
    ~s({"long":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}),
    ~s([7,{"x":9},false])
  ]

  def main do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)

    [{mod, beam}] = Code.compile_string(@src)
    target = Path.join(@tmp, "#{mod}.beam")
    File.write!(target, beam)

    jason_beams = Path.wildcard(Path.join([Path.dirname(to_string(:code.which(Jason))), "*.beam"]))
    extra_beams = Enum.map([Enum, Map, Access, Keyword, List, String, :lists, :maps], fn m -> to_string(:code.which(m)) end)
    exports = "score:bin->int"

    {wat, 0} = System.cmd("elixir", [@beam2wasm, target] ++ jason_beams ++ extra_beams,
      env: [{"EXPORTS", exports}, {"STUB", "1"}], stderr_to_stdout: false)

    watf = Path.join(@tmp, "JasonDecodeTarget.wat")
    wasmf = Path.join(@tmp, "JasonDecodeTarget.wasm")
    casesf = Path.join(@tmp, "cases.json")

    File.write!(watf, wat)
    {asm, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf), stderr_to_stdout: true)
    if asm != "", do: IO.write(asm)

    cases = Enum.map(@jsons, fn json ->
      %{"name" => "score", "ret" => "int", "args" => [%{"type" => "bin", "val" => json}]}
    end)
    File.write!(casesf, IO.iodata_to_binary(:json.encode(cases)))

    if System.get_env("BENCH") do
      Code.require_file("_bench.exs", @here)
      Bench.report("jason-decode", mod, :score, @jsons, wasmf, casesf)
    end

    {out, 0} = System.cmd(@node, [@driver, wasmf, watf, casesf], stderr_to_stdout: true)
    actual = String.split(String.trim_trailing(out), "\n", trim: false)

    expected = Enum.map(@jsons, fn json -> Integer.to_string(apply(mod, :score, [json])) end)

    checks = Enum.zip(@jsons, Enum.zip(expected, actual))
    failures = Enum.filter(checks, fn {_json, {exp, got}} -> exp != got end)

    IO.puts("\n══════════ JASON DECODE CONFORMANCE: WasmGC vs BEAM ══════════\n")
    if failures == [] do
      IO.puts("✅ jason-decode #{length(@jsons)}/#{length(@jsons)}")
    else
      IO.puts("⚠️  jason-decode #{length(@jsons) - length(failures)}/#{length(@jsons)}")
      for {json, {exp, got}} <- failures do
        IO.puts("       ✗ #{inspect(json)}  got #{inspect(got)}  exp #{inspect(exp)}")
      end
    end

    IO.puts("\n──────────────────────────────────────────────────────────────")
    IO.puts("  TOTAL: #{length(@jsons) - length(failures)}/#{length(@jsons)} cases bit-exact vs the VM")
    IO.puts("──────────────────────────────────────────────────────────────\n")

    if failures != [], do: System.halt(1)
  end
end

JasonDecodeConf.main()
