#!/usr/bin/env elixir
# worker/smoke.exs — the workerd prod gate: serve the markdown worker on LOCAL workerd (the same
# runtime Cloudflare runs) and assert byte-identical output vs the real Elixir VM over HTTP,
# then measure end-to-end request latency. This is the last verification step before a real
# `wrangler deploy` — same module, same worker script, same config shape.
#
#   elixir smoke.exs        (workerd via WORKERD env, PATH, or ./node_modules/.bin/workerd)
Code.require_file("../../../tooling.exs", __DIR__)

defmodule WorkerSmoke do
  @here Path.dirname(__ENV__.file)
  @md Path.join(@here, "..")
  @app Path.join(@md, "app")
  @beam2wasm Path.join(@here, "../../../compiler/beam2wasm.exs")
  @imports Path.join(@here, "../../../runtime/imports.mjs")
  @port 8796
  @workerd Tooling.workerd!()
  @wasmas Tooling.wasmas!()

  def main do
    :inets.start()
    build()
    expected = vm_expected()
    pid = start_workerd()
    try do
      await_up()
      IO.puts("\n══════════ WORKERD SMOKE: the pipeline on Cloudflare's runtime, byte-exact over HTTP ══════════\n")
      results =
        Enum.map(Enum.with_index(expected), fn {{label, want}, i} ->
          {ms, got} = req(i, label)
          ok = got == want
          IO.puts("  #{if ok, do: "✅", else: "❌"} #{String.pad_trailing(label, 22)} #{byte_size(want)} bytes  #{Float.round(ms, 2)} ms")
          unless ok, do: show_diff(want, got)
          ok
        end)
      bench()
      pass = Enum.count(results, & &1)
      IO.puts("\n  #{pass}/#{length(results)} responses BYTE-IDENTICAL to the VM through workerd")
      if pass != length(results), do: System.halt(1)
    after
      System.cmd("kill", [to_string(pid)])
    end
  end

  defp build do
    # the same build as bench_vs_js (render:int + render_md:bin exports); artifacts copied in
    {_, 0} = System.cmd("mix", ["compile"], cd: @app, stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])
    {_, 0} = System.cmd("elixir", [Path.join(@md, "bench_vs_js.exs")],
      cd: @md, stderr_to_stdout: true, env: [{"BUILD_ONLY", "1"}])
    File.cp!(Path.join(@md, "_work/blog_vsjs.wasm"), Path.join(@here, "blog.wasm"))
    File.cp!(@imports, Path.join(@here, "imports.mjs"))
    IO.puts("  built + staged worker assets (blog.wasm #{File.stat!(Path.join(@here, "blog.wasm")).size |> div(1024)} KB)")
  end

  defp vm_expected do
    doc = File.read!(Path.join(@md, "vs_js/doc.md"))
    seeds = for s <- 0..2 do
      {out, 0} = System.cmd("mix", ["run", "-e", "IO.write(Blog.render(#{s}))"], cd: @app, env: [{"MIX_ENV", "dev"}])
      {"GET /?seed=#{s}", out}
    end
    {md_html, 0} = System.cmd("mix", ["run", "-e", "IO.write(Blog.render_md(File.read!(#{inspect(Path.join(@md, "vs_js/doc.md"))})))"],
      cd: @app, env: [{"MIX_ENV", "dev"}])
    seeds ++ [{"POST /render (3.7KB md)", md_html}, {:_doc, doc}] |> Enum.reject(&match?({:_doc, _}, &1))
  end

  defp start_workerd do
    port = Port.open({:spawn_executable, @workerd},
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

  defp req(i, label) do
    t0 = System.monotonic_time(:microsecond)
    {:ok, {{_, 200, _}, _, body}} =
      if String.starts_with?(label, "POST") do
        md = File.read!(Path.join(@md, "vs_js/doc.md"))
        :httpc.request(:post, {~c"http://127.0.0.1:#{@port}/render", [], ~c"text/plain", md}, [timeout: 10_000], body_format: :binary)
      else
        :httpc.request(:get, {~c"http://127.0.0.1:#{@port}/?seed=#{i}", []}, [timeout: 10_000], body_format: :binary)
      end
    {(System.monotonic_time(:microsecond) - t0) / 1000, body}
  end

  defp bench do
    n = 200
    # warm
    for _ <- 1..20, do: :httpc.request(:get, {~c"http://127.0.0.1:#{@port}/?seed=1", []}, [timeout: 10_000], body_format: :binary)
    times = for _ <- 1..n do
      t0 = System.monotonic_time(:microsecond)
      {:ok, {{_, 200, _}, _, _}} = :httpc.request(:get, {~c"http://127.0.0.1:#{@port}/?seed=1", []}, [timeout: 10_000], body_format: :binary)
      System.monotonic_time(:microsecond) - t0
    end |> Enum.sort()
    p = fn q -> Enum.at(times, min(n - 1, trunc(q * n))) / 1000 end
    IO.puts("\n  end-to-end HTTP latency (#{n} requests, full JSON->markdown->HTML render each):")
    IO.puts("     p50=#{Float.round(p.(0.50), 2)}ms  p90=#{Float.round(p.(0.90), 2)}ms  p99=#{Float.round(p.(0.99), 2)}ms")
  end

  defp show_diff(want, got) do
    i = Enum.find(0..(min(byte_size(want), byte_size(got)) - 1), 0, fn i -> :binary.at(want, i) != :binary.at(got, i) end)
    IO.puts("     first diff at byte #{i}: vm=#{inspect(String.slice(want, max(0, i - 15), 40))} workerd=#{inspect(String.slice(got, max(0, i - 15), 40))}")
  end
end

WorkerSmoke.main()
