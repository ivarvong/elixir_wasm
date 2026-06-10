#!/usr/bin/env elixir
# demo/durable-sql — a SQLite client INSIDE compiled Elixir, the database as a host effect.
#
# `Sqlite.query!/2` -> `:sql_host.exec/2` -> host import. Params and rows ride REAL Jason.
# The differential gate runs the same seed-driven ledger session on the BEAM and on WasmGC,
# both against the IDENTICAL engine (node:sqlite — the VM through a line-server Port, the
# Wasm through the `sql` import), and asserts the reports byte-identical. In production the
# same module binds to the Durable Object's synchronous ctx.storage.sql (see worker/).
#
#   cd app && mix deps.get && mix compile && cd ..
#   elixir run.exs
Code.require_file("../../tooling.exs", __DIR__)

defmodule SqlDiff do
  @here Path.dirname(__ENV__.file)
  @app Path.join(@here, "app")
  @beam2wasm Path.join(@here, "../../compiler/beam2wasm.exs")
  @tmp Path.join(@here, "_work")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()
  @seeds [1, 7, 42, 1337, 99_991, 271_828]

  def main do
    File.mkdir_p!(@tmp)
    {_, 0} = System.cmd("mix", ["compile"], cd: @app, stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])
    wasmf = build()
    IO.puts("\n══════════ SQL-IN-ELIXIR: the same ledger session, BEAM vs WasmGC, one SQLite ══════════\n")

    vm = Enum.map(@seeds, &vm_run/1)
    wasm = wasm_runs(wasmf)

    results =
      Enum.zip([@seeds, vm, wasm])
      |> Enum.map(fn {s, v, w} ->
        ok = v == w
        IO.puts("  #{if ok, do: "✅", else: "❌"} seed #{s}  #{byte_size(v)} bytes#{if ok, do: "", else: "  DIVERGED"}")
        unless ok do
          IO.puts("     vm:   #{inspect(String.slice(v, 0, 120))}")
          IO.puts("     wasm: #{inspect(String.slice(w, 0, 120))}")
        end
        ok
      end)

    pass = Enum.count(results, & &1)
    IO.puts("\n  #{pass}/#{length(@seeds)} ledger sessions BYTE-IDENTICAL (schema + inserts + aggregates + Elixir folds)")
    IO.puts("  sample report (seed 42):\n" <> indent(Enum.at(vm, 2)))
    if pass == length(@seeds), do: :ok, else: System.halt(1)
  end

  defp indent(s), do: s |> String.split("\n") |> Enum.map_join("\n", &("    │ " <> &1))

  defp build do
    watf = Path.join(@tmp, "ledger.wat")
    wasmf = Path.join(@tmp, "ledger.wasm")
    stdlib =
      [Kernel, Exception, Enum, String, String.Break, String.Chars, List, Map, MapSet, Keyword,
       Integer, Float, Tuple, Range, Stream, Enumerable, Collectable, Inspect, Inspect.Algebra,
       Access, ArgumentError, RuntimeError, KeyError, :lists, :maps, :sets, :ordsets,
       :io_lib, :io_lib_format,
       Enumerable.List, Enumerable.Map, Enumerable.Range, Enumerable.Function,
       Collectable.List, Collectable.Map, Collectable.BitString,
       String.Chars.Integer, String.Chars.Float, String.Chars.List, String.Chars.BitString, String.Chars.Atom]
      |> Enum.map(fn m -> Code.ensure_loaded(m); to_string(:code.which(m)) end)
      |> Enum.filter(&String.ends_with?(&1, ".beam"))
    ledger = Path.join(@app, "_build/dev/lib/sql_ledger/ebin/Elixir.SqlLedger.beam")
    sqlite = Path.join(@app, "_build/dev/lib/sql_ledger/ebin/Elixir.Sqlite.beam")
    jason = Path.wildcard(Path.join(@app, "_build/dev/lib/jason/ebin/*.beam"))
    consolidated = Path.wildcard(Path.join(@app, "_build/dev/lib/sql_ledger/consolidated/*.beam"))
    beams = Enum.uniq_by([ledger, sqlite] ++ jason ++ stdlib ++ consolidated, &Path.basename/1)
    cmd = "elixir #{inspect(@beam2wasm)} #{Enum.map_join(beams, " ", &inspect/1)} > #{inspect(watf)} 2>#{inspect(watf <> ".stub")}"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "run:int->bin;ledger_op:bin->bin"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf, ["-g"]), stderr_to_stdout: true)
    IO.puts("  built #{Float.round(File.stat!(wasmf).size / 1024, 0)} KB wasm (SqlLedger + Sqlite + real Jason + stdlib)")
    wasmf
  end

  # the VM oracle: same code on the BEAM, :sql_host backed by a node:sqlite line-server Port.
  # One `mix run` per seed = one fresh server = one fresh :memory: database (mirrors the runner).
  defp vm_run(seed) do
    code = """
    defmodule :sql_host do
      def exec(sql, params_json) do
        port = :persistent_term.get(:sqlsrv)
        Port.command(port, Jason.encode!(%{sql: sql, params: params_json}) <> "\\n")
        receive do
          {^port, {:data, {:eol, "OK " <> rows}}} -> rows
          {^port, {:data, {:eol, "ERR " <> msg}}} -> raise msg
        after
          5_000 -> raise "sqlsrv timeout"
        end
      end
    end
    port = Port.open({:spawn_executable, #{inspect(@node)}},
      [:binary, {:line, 1_048_576}, args: [#{inspect(Path.join(@here, "sqlsrv.mjs"))}]])
    :persistent_term.put(:sqlsrv, port)
    IO.write(SqlLedger.run(#{seed}))
    """
    {out, 0} = System.cmd("mix", ["run", "-e", code], cd: @app, env: [{"MIX_ENV", "dev"}])
    out
  end

  defp wasm_runs(wasmf) do
    {out, 0} = Tooling.cmd(@node, [Path.join(@here, "runner.mjs"), wasmf | Enum.map(@seeds, &to_string/1)], timeout: 60_000)
    out |> String.trim() |> String.split("\n") |> Enum.map(&Base.decode64!/1)
  end
end

SqlDiff.main()
