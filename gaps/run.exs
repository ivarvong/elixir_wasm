#!/usr/bin/env elixir
# Gap-hunting differential harness. Each gaps/pNN_*.exs defines `defmodule GapNN do def run(seed) ...`
# returning an INTEGER checksum folded over a realistic, seed-derived computation across a broad
# stdlib surface. For every program × seed we run the SAME code on WasmGC and on the real Elixir VM
# and diff bit-exact. A single miscompiled stdlib function anywhere changes the checksum.
#
#   elixir run.exs            # all programs
#   elixir run.exs p03        # only programs whose file matches the filter
#
# Reports, per program: reachable STUBS (compiler's own "unsupported but reachable" meter, 0 = provably
# supported) and seeds passed/total (bit-exact vs the VM). FAIL/TRAP/BUILD_ERR localize the gap.
defmodule Gaps do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../compiler/beam2wasm.exs")
  @driver Path.join(@here, "../conformance/driver.mjs")
  @runner Path.join(@here, "runner.mjs")
  @runproc Path.join(@here, "../runtime/scheduler.mjs")
  @tmp Path.join(@here, "_work")
  @node System.get_env("NODE", "/Users/ivar/.nvm/versions/node/v24.16.0/bin/node")
  @wasmas System.find_executable("wasm-as") || "/opt/homebrew/bin/wasm-as"
  # A generous default stdlib surface; DCE keeps only what each program reaches.
  # NB: do NOT include Erlang modules the compiler already shims (:math/:binary/:unicode/:string/:erlang)
  # — that double-defines functions. Their BIFs come in via host imports / builtins.
  @default_extra [Enum, String, String.Break, Map, MapSet, Keyword, List, Range, Integer, Float, Tuple,
                  Stream, Stream.Reducers, Enumerable, Enumerable.List, Enumerable.Map, Enumerable.Range,
                  Access, Bitwise, :lists, :maps, :ordsets, :sets]
  @seeds [1, 7, 42, 1337, 271_828, 99_991, 1_618_033, 2_147_483_646]

  def manifest do
    Path.wildcard(Path.join(@here, "p*.exs"))
    |> Enum.sort()
    |> Enum.map(fn file ->
      src = File.read!(file)
      mod = Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)\s+do/, src) |> Enum.at(1) |> String.to_atom() |> then(&Module.concat([&1]))
      extra = case Regex.run(~r/#\s*extra:\s*(.+)/, src) do
        [_, list] -> list |> String.split([",", " "], trim: true) |> Enum.map(&parse_mod/1)
        _ -> []
      end
      proc = String.contains?(src, "# proc")
      %{file: file, name: Path.basename(file, ".exs"), src: src, mod: mod, extra: extra, proc: proc}
    end)
  end

  defp parse_mod(":" <> a), do: String.to_atom(a)
  defp parse_mod(a), do: Module.concat([a])

  def main(args) do
    File.mkdir_p!(@tmp)
    filter = List.first(args)
    progs = manifest() |> Enum.filter(fn p -> filter == nil or String.contains?(p.name, filter) end)
    IO.puts("\n══════════ GAP HUNT: 20 realistic programs, WasmGC vs the Elixir VM ══════════\n")
    IO.puts("  #{pad("program", 26)}#{pad("stubs", 7)}#{pad("seeds", 9)}status")
    IO.puts("  " <> String.duplicate("─", 70))
    results = Enum.map(progs, &run_prog/1)
    IO.puts("\n  " <> String.duplicate("─", 70))
    full = Enum.count(results, & &1.ok)
    IO.puts("  #{full}/#{length(results)} programs PROVABLY CORRECT (0 stubs, all seeds bit-exact)")

    wrong = Enum.filter(results, &Map.get(&1, :wrong))
    if wrong != [] do
      IO.puts("\n  ❌❌ COMPILER LIES (wrong answer, not a trap — the prize):")
      for g <- wrong, do: IO.puts("   • #{pad(g.name, 24)} #{g.note}")
    end

    # master gap list: every unsupported (stubbed) stdlib function found, ranked by how many programs hit it
    allstubs = results |> Enum.flat_map(&Map.get(&1, :stubs, [])) |> Enum.frequencies()
              |> Enum.sort_by(fn {_, c} -> -c end)
    if allstubs != [] do
      IO.puts("\n  MASTER GAP LIST — unsupported stdlib functions (stubbed), [n programs]:")
      for {fn_, c} <- allstubs, do: IO.puts("   • #{pad(fn_, 40)} [#{c}]")
    end
    File.write!(Path.join(@here, "GAPS_FOUND.txt"), Enum.map_join(allstubs, "\n", fn {f, c} -> "#{f}\t#{c}" end))
    IO.puts("")
  end

  defp run_prog(p) do
    compiled = try_compile_vm(p)
    case compiled do
      {:error, e} ->
        IO.puts("  #{pad(p.name, 26)}#{pad("—", 7)}#{pad("—", 9)}VM_COMPILE_ERR: #{e}")
        %{name: p.name, ok: false, note: "won't compile on the VM: #{e}"}
      {:ok, beams} ->
        {wasmf, watf, stubs, names, build_err} = build_wasm(p, beams)
        cond do
          build_err ->
            IO.puts("  #{pad(p.name, 26)}#{pad("—", 7)}#{pad("—", 9)}BUILD_ERR")
            %{name: p.name, ok: false, note: "wasm build failed (#{build_err})", stubs: names}
          true ->
            {pass, total, firstbad, mism?} = run_seeds(p, wasmf, watf)
            status = cond do
              pass == total and stubs == 0 -> "✅ provably correct"
              pass == total -> "⚠️  ok, #{stubs} latent stubs"
              mism? -> "❌ WRONG (compiler lie!): #{firstbad}"
              true -> "❌ TRAP (reached a stub): #{firstbad}"
            end
            IO.puts("  #{pad(p.name, 26)}#{pad(to_string(stubs), 7)}#{pad("#{pass}/#{total}", 9)}#{status}")
            ok = pass == total and stubs == 0
            note = cond do
              mism? -> "WRONG: #{firstbad}"
              pass < total -> "trap: #{firstbad}"
              stubs > 0 -> "#{stubs} latent stubs"
              true -> ""
            end
            %{name: p.name, ok: ok, note: note, stubs: names, wrong: mism?}
        end
    end
  end

  defp try_compile_vm(p) do
    try do
      compiled = Code.compile_string(p.src)   # loads GapNN into THIS VM (the oracle)
      {:ok, compiled}
    rescue e -> {:error, Exception.message(e) |> String.slice(0, 80)}
    catch _, e -> {:error, inspect(e) |> String.slice(0, 80)} end
  end

  defp build_wasm(p, compiled) do
    beams = Enum.map(compiled, fn {m, b} -> f = Path.join(@tmp, "#{m}.beam"); File.write!(f, b); f end)
    # only modules with a real .beam file (preloaded ones like :erlang are handled by BIF shims)
    extra = (@default_extra ++ p.extra) |> Enum.uniq()
            |> Enum.map(fn m -> to_string(:code.which(m)) end) |> Enum.filter(&String.ends_with?(&1, ".beam"))
    watf = Path.join(@tmp, "#{p.name}.wat")
    wasmf = Path.join(@tmp, "#{p.name}.wasm")
    stubf = Path.join(@tmp, "#{p.name}.stub")
    cmd = "elixir #{inspect(@beam2wasm)} #{Enum.map_join(beams ++ extra, " ", &inspect/1)} > #{inspect(watf)} 2> #{inspect(stubf)}"
    {_, code} = System.shell(cmd, env: [{"EXPORTS", "run:int->int"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    stubs = case Regex.run(~r/STUBS:\s+(\d+)/, File.read!(stubf)) do
      [_, n] -> String.to_integer(n); _ -> -1
    end
    names = if File.exists?(watf), do: stub_names(File.read!(watf)), else: []
    if code != 0 do
      {wasmf, watf, stubs, names, "elixir #{code}"}
    else
      # -all enables every feature, but its custom-descriptors emits `exact` heap types that Node 24
      # rejects without a flag; we don't use RTTs, so disable it to keep output runnable on stock Node.
      case System.cmd(@wasmas, [watf, "-o", wasmf, "-all", "--disable-custom-descriptors", "-g"], stderr_to_stdout: true) do
        {_, 0} -> {wasmf, watf, stubs, names, nil}
        {err, _} -> {wasmf, watf, stubs, names, "wasm-as: " <> String.slice(err, 0, 60)}
      end
    end
  end

  defp stub_names(wat) do
    ext = Regex.scan(~r/;; stub: external (\S+\/\d+)/, wat) |> Enum.map(&Enum.at(&1, 1))
    named = Regex.scan(~r/\(func (\$\S+).*;; STUB fn/, wat) |> Enum.map(fn [_, n] -> demangle(n) end)
    (ext ++ named) |> Enum.uniq()
  end
  defp demangle(n), do: n |> String.replace("$Elixir_46_", "") |> String.replace("_46_", ".") |> String.replace(~r/_(\d+)$/, "/\\1")

  defp run_seeds(p, wasmf, watf) do
    results = Enum.map(@seeds, fn seed ->
      exp = try do
        Integer.to_string(apply(p.mod, :run, [seed]))
      rescue _ -> "ORACLE_ERR" catch _, _ -> "ORACLE_ERR" end
      got =
        if p.proc do
          case System.cmd(@node, ["--experimental-wasm-jspi", @runproc, wasmf, "run", to_string(seed)], stderr_to_stdout: true) do
            {out, 0} -> String.trim(out); _ -> "PROC_ERR"
          end
        else
          case System.cmd(@node, [@runner, wasmf, to_string(seed)]) do
            {out, 0} -> String.trim(out); _ -> "DRIVER_ERR"
          end
        end
      {seed, exp == got, exp, got}
    end)
    pass = Enum.count(results, fn {_, ok, _, _} -> ok end)
    firstbad = Enum.find(results, fn {_, ok, _, _} -> not ok end)
    # a WRONG answer (got is a real number, not a TRAP/ERR sentinel) = the compiler LIED. Most interesting.
    mism? = case firstbad do
      {_, _, _, got} -> got =~ ~r/^-?\d+$/
      nil -> false
    end
    note = case firstbad do
      {s, _, exp, got} -> "seed=#{s} exp #{String.slice(exp, 0, 22)} got #{String.slice(got, 0, 22)}"
      nil -> ""
    end
    {pass, length(@seeds), note, mism?}
  end

  defp pad(s, n), do: String.pad_trailing(to_string(s), n)
end

Gaps.main(System.argv())
