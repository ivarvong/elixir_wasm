#!/usr/bin/env elixir
# Differential FUZZ harness for the clearinghouse ledger (fuzz/ledger.ex).
#
# Compiles Ledger.run/2 to WasmGC, then for many (seed, nops) pairs runs the SAME function
# on Wasm and on the real Elixir VM in-process and diffs the returned hash bit-exact. Because
# the PRNG, the ledger, and the hash all run inside the compiled code, a single miscompiled
# term avalanches the final integer — a correct run and a one-bit-wrong run share nothing.
#
#   elixir run.exs                 # default seed grid + escalating op counts
#   elixir run.exs 200000          # also append a heavy run at nops=200000
#
# On any mismatch it bisects nops to report the FIRST op count where Wasm and the VM diverge.
Code.require_file("../../tooling.exs", __DIR__)

defmodule Fuzz do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../../beam2wasm.exs")
  @driver Path.join(@here, "../conformance/driver.mjs")
  @src Path.join(@here, "ledger.ex")
  @tmp Path.join(@here, "_work")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()
  @extra [Map, Enum, Keyword, :lists, :maps]

  # build the .wasm once; returns the wasm file path. Asserts 0 reachable stubs.
  defp build do
    File.mkdir_p!(@tmp)
    src = File.read!(@src)
    [{mod, bin} | _] = Code.compile_string(src)   # also loads Ledger into THIS VM (the oracle)
    beam = Path.join(@tmp, "#{mod}.beam")
    File.write!(beam, bin)
    extra_beams = Enum.map(@extra, fn m -> to_string(:code.which(m)) end)
    watf = Path.join(@tmp, "#{mod}.wat")
    wasmf = Path.join(@tmp, "#{mod}.wasm")
    stubf = Path.join(@tmp, "stubs.txt")

    # System.shell so we can split stdout (the WAT) from stderr (the STUBS report) cleanly.
    files = Enum.map_join([beam | extra_beams], " ", &inspect/1)
    cmd = "elixir #{inspect(@beam2wasm)} #{files} > #{inspect(watf)} 2> #{inspect(stubf)}"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "run:int,int->int"}, {"STUB", "1"}, {"BIGNUM", "1"}])

    stub_report = File.read!(stubf)
    stubs =
      case Regex.run(~r/STUBS:\s+(\d+)/, stub_report) do
        [_, n] -> String.to_integer(n)
        _ -> -1
      end
    IO.puts("  compile: #{File.stat!(watf).size} bytes WAT, reachable stubs = #{stubs}")
    if stubs != 0 do
      IO.puts("  ⚠️  STUBS PRESENT — the program is NOT provably supported. Report:\n#{stub_report}")
    end

    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf), stderr_to_stdout: true)
    IO.puts("  binary:  #{File.stat!(wasmf).size} bytes .wasm\n")
    {wasmf, mod}
  end

  # --- run a batch of {seed, nops} on Wasm (one node process) -> list of canonical strings ---
  defp wasm_run(wasmf, watf, pairs) do
    cases = Enum.map(pairs, fn {seed, nops} ->
      %{name: "run", ret: "int",
        args: [%{type: "int", val: seed}, %{type: "int", val: nops}]}
    end)
    casesf = Path.join(@tmp, "ledger.cases.json")
    File.write!(casesf, json(cases))
    case Tooling.cmd(@node, [@driver, wasmf, watf, casesf]) do
      {out, 0} -> if out == "", do: [], else: String.split(out, "\n")
      {_, :timeout} -> Enum.map(pairs, fn _ -> "TIMEOUT" end)
      {out, st} -> raise "fuzz driver exited #{st}: #{String.slice(out, 0, 200)}"
    end
  end

  # --- the VM oracle: the same loaded Ledger module, in-process ---
  defp vm_run({seed, nops}), do: Integer.to_string(apply(Ledger, :run, [seed, nops]))

  def main(args) do
    IO.puts("\n══════════ LEDGER FUZZ: compiled Elixir (WasmGC) vs the Elixir VM ══════════\n")
    {wasmf, mod} = build()
    watf = Path.join(@tmp, "#{mod}.wat")

    seeds = [1, 2, 7, 42, 1337, 8675309, 99991, 271_828, 1_618_033, 2_147_483_646]
    light = for s <- seeds, n <- [50, 500, 5_000], do: {s, n}
    heavy = [{42, 50_000}, {1337, 100_000}, {271_828, 100_000}]
    extra = case args do
      [n | _] -> [{31337, String.to_integer(n)}]
      _ -> []
    end
    pairs = light ++ heavy ++ extra

    IO.puts("  running #{length(pairs)} (seed, nops) cases (#{Enum.sum(Enum.map(pairs, &elem(&1, 1)))} total ops)...\n")
    wasm = wasm_run(wasmf, watf, pairs)

    checks =
      Enum.with_index(pairs)
      |> Enum.map(fn {{seed, nops} = p, i} ->
        got = Enum.at(wasm, i, "MISSING")
        exp = vm_run(p)
        %{seed: seed, nops: nops, pass: got == exp, got: got, exp: exp}
      end)

    report(checks)

    # localize the first failure (if any) by bisecting nops
    case Enum.find(checks, fn c -> not c.pass end) do
      nil -> :ok
      bad -> localize(wasmf, watf, bad)
    end
  end

  defp report(checks) do
    pass = Enum.count(checks, & &1.pass)
    total = length(checks)
    by_nops =
      checks
      |> Enum.group_by(& &1.nops)
      |> Enum.sort_by(fn {n, _} -> n end)
    for {n, cs} <- by_nops do
      p = Enum.count(cs, & &1.pass)
      bar = if p == length(cs), do: "✅", else: "⚠️ "
      IO.puts("#{bar} nops=#{String.pad_trailing(Integer.to_string(n), 7)} #{p}/#{length(cs)}")
      for c <- cs, not c.pass do
        IO.puts("       ✗ seed=#{c.seed}  got #{c.got}  exp #{c.exp}")
      end
    end
    IO.puts("\n──────────────────────────────────────────────────────────────────────────")
    IO.puts("  TOTAL: #{pass}/#{total} cases bit-exact vs the VM")
    IO.puts("──────────────────────────────────────────────────────────────────────────\n")
  end

  # binary-search the smallest nops at which Wasm and the VM disagree for this seed.
  defp localize(wasmf, watf, %{seed: seed, nops: nops}) do
    IO.puts("  ── localizing first divergence for seed=#{seed} (≤#{nops} ops) ──")
    eq = fn n ->
      [w] = wasm_run(wasmf, watf, [{seed, n}])
      v = vm_run({seed, n})
      {w == v, w, v}
    end
    first = bisect(eq, 0, nops)
    {_, w, v} = eq.(first)
    IO.puts("  first diverging op count: nops=#{first}")
    IO.puts("    Wasm = #{w}")
    IO.puts("    VM   = #{v}")
    # Name the op(s) around the divergence so the finding is actionable, not just "op #N".
    near = for i <- max(1, first - 2)..first, do: "##{i}=#{Ledger.op_name(seed, i)}"
    IO.puts("  => op ##{first} (1-indexed) is the first miscompiled operation for this seed.")
    IO.puts("     ops near divergence: #{Enum.join(near, "  ")}\n")
  end

  # invariant: eq(lo) is equal, eq(hi) is NOT. Returns smallest n in (lo,hi] that differs.
  defp bisect(_eq, lo, hi) when hi - lo <= 1, do: hi
  defp bisect(eq, lo, hi) do
    mid = div(lo + hi, 2)
    {same, _, _} = eq.(mid)
    if same, do: bisect(eq, mid, hi), else: bisect(eq, lo, mid)
  end

  # minimal JSON encoder for the cases file (mirrors conformance/run.exs)
  defp json(i) when is_integer(i), do: Integer.to_string(i)
  defp json(s) when is_binary(s), do: ~s(") <> s <> ~s(")
  defp json(l) when is_list(l), do: "[" <> Enum.map_join(l, ",", &json/1) <> "]"
  defp json(m) when is_map(m),
    do: "{" <> Enum.map_join(m, ",", fn {k, v} -> json(Atom.to_string(k)) <> ":" <> json(v) end) <> "}"
end

Fuzz.main(System.argv())
