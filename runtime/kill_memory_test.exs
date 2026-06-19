# Memory test for kill-by-unwind (the spike-B property, driven through the REAL scheduler).
# Compiles a program that spawns N processes which PARK, then kills each (a separate killer runs after
# the target suspends), and waits for all N :DOWNs. Runs the scheduler under `--expose-gc` with
# SCHED_MEM=1 at a small and a large N and compares post-GC live heap. With kill-by-unwind + dead-record
# cleanup the heap stays ~flat as N grows; a leaked JSPI stack or process record would grow it with N.
#
#   NODE=/path/to/node24 elixir kill_memory_test.exs
Code.require_file("../tooling.exs", __DIR__)

defmodule KillMem do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../beam2wasm.exs")
  @sched Path.join(@here, "scheduler.mjs")
  @tmp Path.join(@here, "_work")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()

  @src """
  defmodule KillMem do
    def run(n) do
      spawn_pairs(n)
      wait(n)
    end
    defp spawn_pairs(0), do: :ok
    defp spawn_pairs(n) do
      a = spawn(fn -> receive do _ -> :never end end)   # parks
      Process.monitor(a)
      spawn(fn -> Process.exit(a, :boom) end)            # kills it once it has parked
      spawn_pairs(n - 1)
    end
    defp wait(0), do: 0
    defp wait(n) do
      receive do {:DOWN, _, :process, _, _} -> wait(n - 1) end
    end
  end
  """

  def main do
    File.mkdir_p!(@tmp)
    [{_mod, bin} | _] = Code.compile_string(@src)
    beam = Path.join(@tmp, "KillMem.beam"); File.write!(beam, bin)
    watf = Path.join(@tmp, "killmem.wat"); wasmf = Path.join(@tmp, "killmem.wasm")
    cmd = "elixir #{inspect(@beam2wasm)} #{inspect(beam)} > #{inspect(watf)} 2>/dev/null"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "run:int->int"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf, ["-g"]), stderr_to_stdout: true)

    small = measure(wasmf, 100)
    large = measure(wasmf, 10_000)
    grew = large.heap - small.heap

    IO.puts("\n  N=100    heap=#{kb(small.heap)}  live_procs=#{small.procs}  result=#{small.result}")
    IO.puts("  N=10000  heap=#{kb(large.heap)}  live_procs=#{large.procs}  result=#{large.result}")
    IO.puts("  Δheap (100→10000, +9900 spawned-then-killed parkers) = #{kb(grew)}")
    # A leaked stack/record is ~KBs each; 9900 leaks would be tens of MB. Freed -> a few MB of noise.
    limit = 20 * 1024 * 1024
    ok = small.result == "0" and large.result == "0" and grew < limit and large.procs <= 1
    IO.puts(if ok,
      do: "  ✅ PASS — heap stays flat as killed-process count grows (kill-by-unwind frees stacks+records)",
      else: "  ❌ FAIL — heap grew #{kb(grew)} (limit #{kb(limit)}) or processes leaked (live=#{large.procs})")
    System.halt(if ok, do: 0, else: 1)
  end

  defp measure(wasmf, n) do
    {out, _} =
      System.cmd(@node, ["--expose-gc", "--experimental-wasm-jspi", @sched, wasmf, "run", to_string(n)],
        env: [{"SCHED_MEM", "1"}], stderr_to_stdout: true)
    heap = case Regex.run(~r/HEAP_USED (\d+)/, out) do [_, h] -> String.to_integer(h); _ -> -1 end
    procs = case Regex.run(~r/LIVE_PROCS (\d+)/, out) do [_, p] -> String.to_integer(p); _ -> -1 end
    result = case Regex.run(~r/^(\d+)\s*$/m, out) do [_, r] -> r; _ -> "?" end
    %{heap: heap, procs: procs, result: result}
  end

  defp kb(b), do: "#{Float.round(b / 1024 / 1024, 2)} MB"
end

KillMem.main()
