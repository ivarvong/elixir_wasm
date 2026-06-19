#!/usr/bin/env elixir
# worker/smoke.exs — the workerd prod gate for the rebalancer: build with the CONSUMER commands
# (mix wasm.build), stage the LIBRARY's host.mjs/imports.mjs from priv, serve on local
# workerd (the same runtime Cloudflare runs), and assert every verify/cases.exs request comes
# back byte-identical to the real Elixir VM over HTTP. Then `npx wrangler deploy` ships the
# exact same files.
#
#   elixir smoke.exs        (workerd via WORKERD env, PATH, or ./node_modules/.bin/workerd)
Code.require_file("../../../tooling.exs", __DIR__)

defmodule RebalancerSmoke do
  @here Path.dirname(__ENV__.file)
  @app Path.join(@here, "../app")
  @priv Path.join(@here, "../../../priv")
  @port 8797
  @workerd Tooling.workerd!()

  def main do
    :inets.start()
    build()
    cases = load_cases()
    expected = vm_expected(cases)
    pid = start_workerd()

    try do
      await_up()
      IO.puts("\n══════ WORKERD SMOKE: the rebalancer on Cloudflare's runtime, byte-exact over HTTP ══════\n")

      results =
        Enum.zip(cases, expected)
        |> Enum.with_index()
        |> Enum.map(fn {{req_body, want}, i} ->
          {ms, got} = post(req_body)
          ok = got == want
          label = "case #{i} (#{byte_size(req_body)}B req)"
          IO.puts("  #{if ok, do: "✅", else: "❌"} #{String.pad_trailing(label, 24)} #{byte_size(want)} bytes  #{Float.round(ms, 2)} ms")
          unless ok, do: show_diff(want, got)
          ok
        end)

      bench(hd(cases))
      pass = Enum.count(results, & &1)
      IO.puts("\n  #{pass}/#{length(results)} responses BYTE-IDENTICAL to the VM through workerd")
      if pass != length(results), do: System.halt(1)
    after
      System.cmd("kill", [to_string(pid)])
    end
  end

  defp build do
    {_, 0} =
      System.cmd("mix", ["wasm.build", "--module", "Rebalancer", "--export", "rebalance:bin->bin"],
        cd: @app, stderr_to_stdout: true)

    File.cp!(Path.join(@app, "wasm/rebalancer.wasm"), Path.join(@here, "rebalancer.wasm"))
    File.cp!(Path.join(@priv, "host.mjs"), Path.join(@here, "host.mjs"))
    File.cp!(Path.join(@priv, "imports.mjs"), Path.join(@here, "imports.mjs"))
    kb = div(File.stat!(Path.join(@here, "rebalancer.wasm")).size, 1024)
    IO.puts("  built + staged worker assets (rebalancer.wasm #{kb} KB, host.mjs + imports.mjs from priv)")
  end

  defp load_cases do
    {cases, _} = Code.eval_file(Path.join(@app, "verify/cases.exs"))
    Enum.map(cases["rebalance"], fn [json] -> json end)
  end

  defp vm_expected(cases) do
    # one mix run, all cases: read newline-delimited base64 to keep transport unambiguous
    input = Path.join(System.tmp_dir!(), "rebalancer_smoke_cases.txt")
    File.write!(input, Enum.map_join(cases, "\n", &Base.encode64/1))

    script =
      ~s/File.read!(#{inspect(input)}) |> String.split("\\n") |> Enum.each(fn b -> IO.puts(Base.encode64(Rebalancer.rebalance(Base.decode64!(b)))) end)/

    {out, 0} = System.cmd("mix", ["run", "-e", script], cd: @app)
    File.rm(input)
    out |> String.trim() |> String.split("\n") |> Enum.map(&Base.decode64!/1)
  end

  defp start_workerd do
    port =
      Port.open({:spawn_executable, @workerd},
        [:binary, args: ["serve", Path.join(@here, "config.capnp")], cd: @here])

    {:os_pid, ospid} = Port.info(port, :os_pid)
    ospid
  end

  defp await_up(tries \\ 60) do
    case :httpc.request(:get, {~c"http://127.0.0.1:#{@port}/health", []}, [timeout: 500], []) do
      {:ok, {{_, 200, _}, _, _}} -> :ok
      _ when tries > 0 -> Process.sleep(250); await_up(tries - 1)
      _ -> IO.puts("❌ workerd did not come up"); System.halt(1)
    end
  end

  defp post(body) do
    t0 = System.monotonic_time(:microsecond)

    {:ok, {{_, _status, _}, _, resp}} =
      :httpc.request(:post, {~c"http://127.0.0.1:#{@port}/rebalance", [], ~c"application/json", body},
        [timeout: 10_000], body_format: :binary)

    {(System.monotonic_time(:microsecond) - t0) / 1000, resp}
  end

  defp bench(body) do
    n = 200
    for _ <- 1..20, do: post(body)
    times = for _ <- 1..n do
      {ms, _} = post(body)
      ms
    end |> Enum.sort()

    p = fn q -> Enum.at(times, min(n - 1, trunc(q * n))) end
    IO.puts("\n  end-to-end HTTP latency (#{n} requests, full JSON decode -> plan -> JSON encode each):")
    IO.puts("     p50=#{Float.round(p.(0.50), 2)}ms  p90=#{Float.round(p.(0.90), 2)}ms  p99=#{Float.round(p.(0.99), 2)}ms")
  end

  defp show_diff(want, got) do
    i = Enum.find(0..(min(byte_size(want), byte_size(got)) - 1), 0,
          fn i -> :binary.at(want, i) != :binary.at(got, i) end)
    IO.puts("     first diff at byte #{i}: vm=#{inspect(String.slice(want, max(0, i - 15), 40))} workerd=#{inspect(String.slice(got, max(0, i - 15), 40))}")
  end
end

RebalancerSmoke.main()
