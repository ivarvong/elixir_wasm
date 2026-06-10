#!/usr/bin/env elixir
# THE STDLIB API SCOREBOARD — the direct measurement of "any pure Elixir runs here".
#
# For every PUBLIC function of every roster module (via __info__(:functions)):
#   1. generate a concrete call from a typed input pool (the first candidate the VM accepts and
#      whose result our checksum can fold becomes the case; none -> NOGEN, counted separately);
#   2. compile a wrapper module (one `run(idx)` dispatching to every generated call) to WasmGC
#      alongside the real stdlib beams;
#   3. run every case on Wasm AND the VM, diff the checksums bit-exact;
#   4. print the per-module scoreboard and write SCOREBOARD.md.
#
#   elixir run.exs           # whole roster
#   elixir run.exs Enum      # one module
Code.require_file("../tooling.exs", __DIR__)

defmodule Scoreboard do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../compiler/beam2wasm.exs")
  @driver Path.join(@here, "../conformance/driver.mjs")
  @tmp Path.join(@here, "_work")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()

  @roster [Enum, List, Map, Keyword, Tuple, Integer, String, Range, MapSet, Float]

  # Typed candidate args (SOURCE strings — funs/ranges must be literals in the generated module).
  # Ordered: most-typical first so the generated call is idiomatic.
  @pool1 ["[3,1,2,2]", ~s("hello world"), "%{a: 1, b: 2}", "{1, 2, 3}", "5", "-7", "3.5", "1..5",
          "[a: 1, b: 2]", ":an_atom", ~s(""), "[]", "mapset1"]
  # arity-2/3 combos are cross-products of these typed slots (kept small but diverse)
  @slot ["[3,1,2,2]", ~s("hello world"), ~s("o"), "%{a: 1, b: 2}", "{1, 2, 3}", "5", "2", ":a",
         "[a: 1, b: 2]", "fun1", "fun2", "1..5", "mapset1", ~s(","), "0", "-1", "3.5"]
  @aliases %{"fun1" => "&(&1 * 2)", "fun2" => "fn a, b -> a + b end", "mapset1" => "MapSet.new([1, 2, 3])"}
  # genuinely nondeterministic functions: equal output across runs/impls is not even defined.
  @nondet [random: 1, shuffle: 1, take_random: 2, unique_integer: 0]
  # results whose ORDER is unspecified by the language when derived from map iteration (the documented
  # map-order delta, LIMITATIONS §2): normalize by sorting before checksumming — both sides identically.
  @sort_result %{{Map, :keys, 1} => :sort, {Map, :values, 1} => :sort, {Map, :to_list, 1} => :sort,
                 {Keyword, :new, 1} => :sort, {Enum, :unzip, 1} => :sort_tuple}

  def main(args) do
    # candidate probes intentionally crash a lot — keep their crash reports out of the output
    :logger.set_primary_config(:level, :none)
    File.mkdir_p!(@tmp)
    filter = List.first(args)
    roster = if filter, do: Enum.filter(@roster, &(inspect(&1) == filter)), else: @roster
    IO.puts("\n══════════ STDLIB API SCOREBOARD: every public function, Wasm vs the VM ══════════\n")

    rows = Enum.map(roster, &score_module/1)

    IO.puts("\n  ── SCOREBOARD " <> String.duplicate("─", 60))
    total = {0, 0, 0, 0}
    {p, f, n, t} =
      Enum.reduce(rows, total, fn {mod, pass, fail, nogen, all, _details}, {ap, af, an, at} ->
        IO.puts("  #{String.pad_trailing(inspect(mod), 10)} #{pass}/#{pass + fail} bit-exact" <>
                  if(nogen > 0, do: "  (#{nogen} nogen of #{all})", else: "  (all #{all} generated)"))
        {ap + pass, af + fail, an + nogen, at + all}
      end)
    pct = if p + f > 0, do: Float.round(p / (p + f) * 100, 1), else: 0.0
    IO.puts("  " <> String.duplicate("─", 73))
    IO.puts("  TOTAL      #{p}/#{p + f} bit-exact (#{pct}%) · #{n} not yet generated · #{t} public functions\n")
    write_md(rows, {p, f, n, t, pct})
  end

  defp score_module(mod) do
    Code.ensure_loaded(mod)
    fns = mod.__info__(:functions) |> Enum.sort()
    cases = fns |> Enum.map(fn {f, a} -> {f, a, (if {f, a} in @nondet, do: nil, else: gen_call(mod, f, a))} end)
    gen = Enum.filter(cases, fn {_, _, c} -> c != nil end)
    nogen = Enum.count(cases, fn {_, _, c} -> c == nil end)
    IO.puts("  #{inspect(mod)}: #{length(fns)} public fns, #{length(gen)} generated, #{nogen} nogen")

    {wasmf, watf, wrapper_mod} = build(mod, gen)
    vm = Enum.with_index(gen) |> Enum.map(fn {_, i} -> vm_case(wrapper_mod, i) end)
    wasm = wasm_cases(wasmf, watf, length(gen))

    details =
      Enum.zip([gen, vm, wasm])
      |> Enum.map(fn {{f, a, _call}, v, w} -> {f, a, v == w, v, w} end)
    pass = Enum.count(details, fn {_, _, ok, _, _} -> ok end)
    fail = length(details) - pass
    for {f, a, false, v, w} <- details, do: IO.puts("     ❌ #{inspect(mod)}.#{f}/#{a}  vm=#{v} wasm=#{w}")
    {mod, pass, fail, nogen, length(fns), details}
  end

  # try candidate arg combos on the VM; the first whose call + checksum succeeds wins.
  defp gen_call(mod, f, a) do
    candidates(a)
    |> Enum.find_value(fn args_src ->
      call = "#{inspect(mod)}.#{f}(#{Enum.join(args_src, ", ")})"
      probe = "Scoreboard.Chk.chk(#{call})"
      task = Task.async(fn ->
        try do
          {v, _} = Code.eval_string(probe, [], __ENV__)
          if is_integer(v), do: call, else: nil
        rescue _ -> nil
        catch _, _ -> nil
        end
      end)
      case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, r} -> r
        _ -> nil
      end
    end)
  end

  defp candidates(0), do: [[]]
  defp candidates(1), do: Enum.map(@pool1, fn s -> [expand(s)] end)
  defp candidates(2) do
    for a <- @slot, b <- @slot, do: [expand(a), expand(b)]
  end
  defp candidates(3) do
    base = ["[3,1,2,2]", ~s("hello world"), "%{a: 1, b: 2}", "1..5"]
    for a <- base, b <- ["2", "\"o\"", ":a", "0"], c <- ["5", "fun2", "\"X\"", "[9]"], do: [expand(a), expand(b), expand(c)]
  end
  defp candidates(_), do: []

  defp expand(s), do: Map.get(@aliases, s, s)

  defp build(mod, gen) do
    clauses =
      gen
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{f, a, call}, i} ->
        case Map.get(@sort_result, {mod, f, a}) do
          :sort -> "      #{i} -> chk(Enum.sort(#{call}))"
          :sort_tuple -> "      #{i} -> chk((fn {sa, sb} -> {Enum.sort(sa), Enum.sort(sb)} end).(#{call}))"
          _ -> "      #{i} -> chk(#{call})"
        end
      end)
    wrapper = :"Elixir.SB#{inspect(mod) |> String.replace(".", "")}"
    src = """
    defmodule #{inspect(wrapper)} do
      def run(idx) do
        case idx do
    #{clauses}
          _ -> -1
        end
      end
      #{chk_src()}
    end
    """
    [{m, bin} | _] = Code.compile_string(src)
    beam = Path.join(@tmp, "#{m}.beam")
    File.write!(beam, bin)
    extra =
      ([mod] ++ [Kernel, Enum, List, Map, Keyword, Tuple, Integer, String, String.Break, Range, MapSet, Float,
                 Exception, ArgumentError, RuntimeError, KeyError, Enumerable, Enumerable.List, Enumerable.Map,
                 Enumerable.Range, Enumerable.MapSet, Collectable, Collectable.List, Collectable.Map,
                 Collectable.MapSet, Stream, Stream.Reducers, Enumerable.Function, Enumerable.Stream,
                 Function, :lists, :maps, :sets, :ordsets])
      |> Enum.uniq()
      |> Enum.map(fn x -> Code.ensure_loaded(x); to_string(:code.which(x)) end)
      |> Enum.filter(&String.ends_with?(&1, ".beam"))
    watf = Path.join(@tmp, "#{m}.wat")
    wasmf = Path.join(@tmp, "#{m}.wasm")
    cmd = "elixir #{inspect(@beam2wasm)} #{Enum.map_join([beam | extra], " ", &inspect/1)} > #{inspect(watf)} 2>/dev/null"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "run:int->int"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf, ["-g"]), stderr_to_stdout: true)
    {wasmf, watf, m}
  end

  defp vm_case(wrapper_mod, i) do
    task = Task.async(fn ->
      try do
        Integer.to_string(apply(wrapper_mod, :run, [i]))
      rescue _ -> "VMERR"
      catch _, _ -> "VMERR"
      end
    end)
    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, r} -> r
      _ -> "VMERR"
    end
  end

  defp wasm_cases(wasmf, watf, n) do
    casesf = Path.join(@tmp, "cases.json")
    File.write!(casesf, "[" <> Enum.map_join(0..(n - 1), ",", fn i ->
      ~s({"name":"run","ret":"int","args":[{"type":"int","val":#{i}}]})
    end) <> "]")
    case Tooling.cmd(@node, [@driver, wasmf, watf, casesf], timeout: 120_000) do
      {out, 0} -> String.split(out, "\n")
      {_, _} -> List.duplicate("DRIVER_ERR", n)
    end
  end

  # term -> integer checksum, identical logic compiled to Wasm and run on the VM. Maps fold via
  # sorted key order (so the >32-key iteration-order delta can't bite); floats via 1e6 fixed-point.
  defp chk_src do
    """
      def chk(x), do: ch(x, 17)
      defp ch(x, a) when is_integer(x), do: rem(a * 131 + rem(x, 1_000_000_007) + 1_000_000_007, 1_000_000_007)
      defp ch(x, a) when is_float(x), do: ch(trunc(x * 1_000_000), a + 3)
      defp ch(true, a), do: a + 11
      defp ch(false, a), do: a + 13
      defp ch(nil, a), do: a + 19
      defp ch(x, a) when is_atom(x), do: bs(:erlang.atom_to_binary(x), a + 5)
      defp ch(x, a) when is_binary(x), do: bs(x, a + 7)
      defp ch(x, a) when is_list(x), do: Enum.reduce(x, a + 23, fn e, acc -> ch(e, acc) end)
      defp ch(x, a) when is_tuple(x), do: ch(Tuple.to_list(x), a + 29)
      defp ch(%MapSet{} = x, a), do: ch(MapSet.to_list(x) |> Enum.sort_by(&inspect_key/1), a + 37)
      defp ch(x, a) when is_map(x), do: Enum.reduce(Enum.sort_by(Map.to_list(x), fn {k, _} -> inspect_key(k) end), a + 31, fn {k, v}, acc -> ch(v, ch(k, acc)) end)
      defp ch(_, a), do: a + 997
      defp bs(<<>>, a), do: a
      defp bs(<<c, r::binary>>, a), do: bs(r, rem(a * 131 + c, 1_000_000_007))
      defp inspect_key(k) when is_integer(k), do: {0, k, ""}
      defp inspect_key(k) when is_atom(k), do: {1, 0, :erlang.atom_to_binary(k)}
      defp inspect_key(k) when is_binary(k), do: {2, 0, k}
      defp inspect_key(k), do: {3, 0, ""}
    """
  end

  defp write_md(rows, {p, f, n, t, pct}) do
    body =
      Enum.map_join(rows, "\n", fn {mod, pass, fail, nogen, all, details} ->
        fails = for {fn_, a, false, _, _} <- details, do: "`#{fn_}/#{a}`"
        "| #{inspect(mod)} | #{pass}/#{pass + fail} | #{nogen} | #{all} | #{Enum.join(fails, " ")} |"
      end)
    File.write!(Path.join(@here, "SCOREBOARD.md"), """
    # Stdlib API scoreboard — every public function, Wasm vs the VM, bit-exact

    Generated by `scoreboard/run.exs`. For each public function (via `__info__(:functions)`) a
    concrete call is generated from a typed input pool (VM-validated); the SAME call runs compiled
    on WasmGC and on the Elixir VM, results folded through an identical checksum and diffed.
    `nogen` = no candidate input matched yet (a harness gap, not a runtime failure).

    **TOTAL: #{p}/#{p + f} bit-exact (#{pct}%) · #{n} not yet generated · #{t} public functions**

    | Module | bit-exact | nogen | public fns | failing |
    |--------|-----------|-------|------------|---------|
    #{body}
    """)
    IO.puts("  wrote SCOREBOARD.md")
  end
end

defmodule Scoreboard.Chk do
  # VM-side probe checksum: identical semantics to the compiled chk (defined directly here).
  def chk(x), do: ch(x, 17)
  defp ch(x, a) when is_integer(x), do: rem(a * 131 + rem(x, 1_000_000_007) + 1_000_000_007, 1_000_000_007)
  defp ch(x, a) when is_float(x), do: ch(trunc(x * 1_000_000), a + 3)
  defp ch(true, a), do: a + 11
  defp ch(false, a), do: a + 13
  defp ch(nil, a), do: a + 19
  defp ch(x, a) when is_atom(x), do: bs(:erlang.atom_to_binary(x), a + 5)
  defp ch(x, a) when is_binary(x), do: bs(x, a + 7)
  defp ch(x, a) when is_list(x), do: Enum.reduce(x, a + 23, fn e, acc -> ch(e, acc) end)
  defp ch(x, a) when is_tuple(x), do: ch(Tuple.to_list(x), a + 29)
  defp ch(%MapSet{} = x, a), do: ch(MapSet.to_list(x) |> Enum.sort_by(&inspect_key/1), a + 37)
  defp ch(x, a) when is_map(x), do: Enum.reduce(Enum.sort_by(Map.to_list(x), fn {k, _} -> inspect_key(k) end), a + 31, fn {k, v}, acc -> ch(v, ch(k, acc)) end)
  defp ch(_, a), do: a + 997
  defp bs(<<>>, a), do: a
  defp bs(<<c, r::binary>>, a), do: bs(r, rem(a * 131 + c, 1_000_000_007))
  defp inspect_key(k) when is_integer(k), do: {0, k, ""}
  defp inspect_key(k) when is_atom(k), do: {1, 0, :erlang.atom_to_binary(k)}
  defp inspect_key(k) when is_binary(k), do: {2, 0, k}
  defp inspect_key(_k), do: {3, 0, ""}
end

Scoreboard.main(System.argv())
