#!/usr/bin/env elixir
# genfuzz — the GENERATIVE program fuzzer: seeded random Elixir programs over the full term
# algebra (3-tier integers across the bignum boundaries, floats, binaries, lists, tuples, maps,
# atoms, closures, branching, bounded recursion, try/rescue), each compiled to WasmGC and run on
# Wasm AND the real VM across multiple inputs, checksums diffed bit-exact.
#
# This probes the COMPILER's lowering with program shapes no hand-written suite contains. Every
# generated program is saved to _work/gen_<n>.exs — a failure is immediately reproducible:
#
#   elixir run.exs                  # default corpus (PROGS × SEEDS)
#   PROGS=50 elixir run.exs         # bigger sweep
#   GENSEED=99 elixir run.exs       # different generation universe
#   elixir run.exs 7                # re-run ONLY saved program 7 (after a failure)
Code.require_file("../../tooling.exs", __DIR__)

defmodule GenFuzz do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../../beam2wasm.exs")
  @driver Path.join(@here, "../conformance/driver.mjs")
  @tmp Path.join(@here, "_work")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()
  @inputs [0, 1, -7, 42, 1000, 99_991]

  # ---- typed expression generator ----------------------------------------------------------
  # Each gen_* returns Elixir SOURCE for an expression of that type. `env` lists bound int vars.
  # Division/shift operands are wrapped to stay defined; recursion is depth-bounded.

  defp pick(l), do: Enum.at(l, :rand.uniform(length(l)) - 1)
  defp small, do: :rand.uniform(20) - 10
  # constants straddling every integer-tier boundary (i31 / i64 / host bignum)
  defp big_const do
    pick([1_073_741_823, 1_073_741_824, -1_073_741_825, 2_147_483_648, 4_611_686_018_427_387_904,
          9_223_372_036_854_775_807, -9_223_372_036_854_775_808, 18_446_744_073_709_551_616,
          :rand.uniform(1_000_000_000_000_000_000_000_000)])
  end

  defp gen_int(0, env), do: pick(["#{small()}", "#{big_const()}", pick(env), pick(env)])
  defp gen_int(d, env) do
    case :rand.uniform(14) do
      1 -> "(#{gen_int(d - 1, env)} + #{gen_int(d - 1, env)})"
      2 -> "(#{gen_int(d - 1, env)} - #{gen_int(d - 1, env)})"
      3 -> "(#{gen_int(d - 1, env)} * #{gen_int(d - 1, env)})"
      4 -> "div(#{gen_int(d - 1, env)}, (abs(#{gen_int(d - 1, env)}) + 1))"
      5 -> "rem(#{gen_int(d - 1, env)}, (abs(#{gen_int(d - 1, env)}) + 1))"
      6 -> "Bitwise.band(#{gen_int(d - 1, env)}, #{gen_int(d - 1, env)})"
      7 -> "Bitwise.bxor(#{gen_int(d - 1, env)}, #{gen_int(d - 1, env)})"
      8 -> "Bitwise.bsl(#{gen_int(d - 1, env)}, rem(abs(#{gen_int(0, env)}), 64))"
      9 -> "abs(#{gen_int(d - 1, env)})"
      10 -> "if(#{gen_bool(d - 1, env)}, do: #{gen_int(d - 1, env)}, else: #{gen_int(d - 1, env)})"
      11 -> "Enum.sum(#{gen_listexpr(d - 1, env)})"
      12 -> "tuple_size(#{gen_tuple(d - 1, env)}) + elem(#{gen_tuple(d - 1, env)}, 0)"
      13 -> "byte_size(#{gen_bin(d - 1, env)})"
      14 -> "map_size(#{gen_map(d - 1, env)}) + Map.get(#{gen_map(d - 1, env)}, :a, 0)"
    end
  end

  defp gen_bool(0, _env), do: pick(["true", "false"])
  defp gen_bool(d, env) do
    case :rand.uniform(5) do
      1 -> "(#{gen_int(d - 1, env)} > #{gen_int(d - 1, env)})"
      2 -> "(#{gen_int(d - 1, env)} == #{gen_int(d - 1, env)})"
      3 -> "(#{gen_int(d - 1, env)} <= #{gen_int(d - 1, env)})"
      4 -> "not #{gen_bool(d - 1, env)}"
      5 -> "(#{gen_bool(d - 1, env)} and #{gen_bool(d - 1, env)})"
    end
  end

  defp gen_listexpr(0, env), do: "[#{gen_int(0, env)}, #{gen_int(0, env)}, #{gen_int(0, env)}]"
  defp gen_listexpr(d, env) do
    case :rand.uniform(7) do
      1 -> "[#{gen_int(d - 1, env)} | #{gen_listexpr(d - 1, env)}]"
      2 -> "(#{gen_listexpr(d - 1, env)} ++ #{gen_listexpr(d - 1, env)})"
      3 -> "Enum.sort(#{gen_listexpr(d - 1, env)})"
      4 -> ":lists.reverse(#{gen_listexpr(d - 1, env)})"
      5 -> "Enum.map(#{gen_listexpr(d - 1, env)}, fn x -> x * 2 + #{gen_int(0, env)} end)"
      6 -> "Enum.filter(#{gen_listexpr(d - 1, env)}, fn x -> rem(x, 2) == 0 end)"
      7 -> "Enum.take(Enum.drop(#{gen_listexpr(d - 1, env)}, 1), 2)"
    end
  end

  defp gen_tuple(d, env) when d <= 0, do: "{#{gen_int(0, env)}, #{gen_int(0, env)}}"
  defp gen_tuple(d, env), do: "put_elem({#{gen_int(d - 1, env)}, #{gen_int(d - 1, env)}}, 1, #{gen_int(d - 1, env)})"

  defp gen_bin(d, env) when d <= 0, do: ~s|<<#{:rand.uniform(255)}, #{:rand.uniform(255)}>>|
  defp gen_bin(d, env) do
    case :rand.uniform(4) do
      1 -> "(#{gen_bin(d - 1, env)} <> #{gen_bin(d - 1, env)})"
      2 -> "<<Bitwise.band(#{gen_int(d - 1, env)}, 255), #{gen_bin(d - 1, env)}::binary>>"
      3 -> "<<Bitwise.band(#{gen_int(d - 1, env)}, 65535)::16, 7::8>>"
      4 -> "Integer.to_string(#{gen_int(d - 1, env)})"
    end
  end

  defp gen_map(d, env) when d <= 0, do: "%{a: #{gen_int(0, env)}, b: #{gen_int(0, env)}}"
  defp gen_map(d, env) do
    case :rand.uniform(3) do
      1 -> "Map.put(#{gen_map(d - 1, env)}, :c, #{gen_int(d - 1, env)})"
      2 -> "Map.delete(#{gen_map(d - 1, env)}, :b)"
      3 -> "Map.update(#{gen_map(d - 1, env)}, :a, 0, fn v -> v + 1 end)"
    end
  end

  # a whole program: bound helpers + a run/1 folding several expressions through the checksum
  def gen_program(n) do
    nexprs = 4 + :rand.uniform(4)
    exprs = for i <- 1..nexprs do
      body =
        case :rand.uniform(8) do
          k when k <= 4 -> gen_int(3, ["a", "b", "c"])
          5 -> "Enum.sum(#{gen_listexpr(2, ["a", "b", "c"])})"
          6 -> "byte_size(#{gen_bin(2, ["a", "b", "c"])})"
          7 -> """
               try do
                 div(#{gen_int(2, ["a", "b", "c"])}, rem(a, 3))
               rescue
                 ArithmeticError -> #{gen_int(1, ["a", "b", "c"])}
               end\
               """
          8 -> "loop(rem(abs(a), 17) + 3, #{gen_int(1, ["a", "b", "c"])})"
        end
      "    x#{i} = #{body}"
    end
    fold = Enum.map_join(1..nexprs, " ", fn i -> "|> fold(x#{i})" end)
    """
    defmodule Gen#{n} do
      import Bitwise, warn: false
      def run(seed) do
        a = seed
        b = rem(seed * 7919 + 13, 100_003)
        c = seed - 64
        _ = {a, b, c}
    #{Enum.join(exprs, "\n")}
        17 #{fold}
      end
      defp fold(acc, x) when is_integer(x), do: rem(acc * 131 + rem(x, 1_000_000_007) + 1_000_000_007, 1_000_000_007)
      defp fold(acc, _), do: acc + 997
      defp loop(0, acc), do: acc
      defp loop(k, acc), do: loop(k - 1, rem(acc * 31 + k, 1_000_000_007))
    end
    """
  end

  # ---- harness ------------------------------------------------------------------------------
  def main(args) do
    File.mkdir_p!(@tmp)
    genseed = String.to_integer(System.get_env("GENSEED") || "1")
    nprogs = String.to_integer(System.get_env("PROGS") || "12")
    only = List.first(args)
    IO.puts("\n══════════ GENFUZZ: #{nprogs} random programs (GENSEED=#{genseed}), Wasm vs the VM ══════════\n")

    results =
      for n <- 0..(nprogs - 1), only == nil or to_string(n) == only do
        :rand.seed(:exsss, {genseed, n * 7 + 1, 1042})
        src = gen_program(n)
        File.write!(Path.join(@tmp, "gen_#{n}.exs"), src)
        run_program(n, src)
      end

    pass = Enum.count(results, & &1)
    IO.puts("\n  " <> String.duplicate("─", 70))
    IO.puts("  #{pass}/#{length(results)} programs bit-exact vs the VM across #{length(@inputs)} inputs each")
    if pass == length(results), do: :ok, else: System.halt(1)
  end

  defp run_program(n, src) do
    [{mod, bin} | _] = Code.compile_string(src)
    beam = Path.join(@tmp, "#{mod}.beam")
    File.write!(beam, bin)
    extra =
      [Enum, List, Map, Integer, Enumerable, Enumerable.List, :lists, :maps]
      |> Enum.map(fn x -> Code.ensure_loaded(x); to_string(:code.which(x)) end)
      |> Enum.filter(&String.ends_with?(&1, ".beam"))
    watf = Path.join(@tmp, "gen_#{n}.wat")
    wasmf = Path.join(@tmp, "gen_#{n}.wasm")
    cmd = "elixir #{inspect(@beam2wasm)} #{Enum.map_join([beam | extra], " ", &inspect/1)} > #{inspect(watf)} 2>#{inspect(watf <> ".stub")}"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "run:int->int"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf, ["-g"]), stderr_to_stdout: true)
    stubs = File.read!(watf <> ".stub") |> then(fn s -> Regex.run(~r/STUBS: (\d+)/, s) end) |> then(fn [_, c] -> c end)

    vm = Enum.map(@inputs, fn i ->
      try do
        Integer.to_string(apply(mod, :run, [i]))
      rescue _ -> "VMERR"
      catch _, _ -> "VMERR"
      end
    end)
    casesf = Path.join(@tmp, "cases_#{n}.json")
    File.write!(casesf, "[" <> Enum.map_join(@inputs, ",", fn i ->
      ~s({"name":"run","ret":"int","args":[{"type":"int","val":#{i}}]})
    end) <> "]")
    wasm =
      case Tooling.cmd(@node, [@driver, wasmf, watf, casesf], timeout: 60_000) do
        {out, 0} -> String.split(out, "\n", trim: true)
        {_, _} -> List.duplicate("DRIVER_ERR", length(@inputs))
      end
    # a program may legitimately raise on some input (e.g. an uncaught ArithmeticError the
    # generator produced): both sides erroring is AGREEMENT. Only value-vs-value or
    # value-vs-error diffs are failures. (Error-CLASS comparison is a future tightening.)
    norm = fn
      "VMERR" -> :err
      "TRAP" <> _ -> :err
      v -> v
    end
    ok = Enum.map(vm, norm) == Enum.map(wasm, norm)
    status = if ok, do: "✅", else: "❌"
    IO.puts("  #{status} gen_#{n}  stubs=#{stubs}  #{if ok, do: "#{length(@inputs)}/#{length(@inputs)} bit-exact", else: "DIVERGED"}")
    unless ok do
      Enum.zip([@inputs, vm, wasm])
      |> Enum.reject(fn {_, v, w} -> v == w end)
      |> Enum.each(fn {i, v, w} -> IO.puts("       input #{i}: vm=#{v} wasm=#{w}   (repro: _work/gen_#{n}.exs)") end)
    end
    ok
  end
end

GenFuzz.main(System.argv())
