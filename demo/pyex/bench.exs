#!/usr/bin/env elixir
# demo/pyex/bench.exs — HAVERSINE BENCHMARK: random CONUS airport pairs, the same Python
# program (values injected as query-param variables) run two ways:
#   local:  pyex on the BEAM (this machine)
#   remote: pyex on WasmGC on production Cloudflare Workers (elixir-python)
# Transcripts are compared pair-by-pair (both engines, one interpreter); timings reported
# honestly (local = in-process eval; remote = HTTP TTFB + the worker's own x-eval-ms).
#
#   elixir bench.exs            # N=40 pairs, SEED=1
#   N=100 SEED=7 elixir bench.exs
Code.require_file("../../tooling.exs", __DIR__)

defmodule HaversineBench do
  @here Path.dirname(__ENV__.file)
  @app Path.join(@here, "app")
  @remote "https://elixir-python.ivar.workers.dev"

  # CONUS majors: {code, lat, lon}
  @airports [
    {"ATL", 33.6407, -84.4277}, {"LAX", 33.9416, -118.4085}, {"ORD", 41.9742, -87.9073},
    {"DFW", 32.8998, -97.0403}, {"DEN", 39.8561, -104.6737}, {"JFK", 40.6413, -73.7781},
    {"SFO", 37.6213, -122.3790}, {"SEA", 47.4502, -122.3088}, {"LAS", 36.0840, -115.1537},
    {"MCO", 28.4312, -81.3081}, {"EWR", 40.6895, -74.1745}, {"MIA", 25.7959, -80.2870},
    {"PHX", 33.4373, -112.0078}, {"IAH", 29.9902, -95.3368}, {"BOS", 42.3656, -71.0096},
    {"MSP", 44.8848, -93.2223}, {"DTW", 42.2162, -83.3554}, {"FLL", 26.0742, -80.1506},
    {"PHL", 39.8744, -75.2424}, {"LGA", 40.7769, -73.8740}, {"BWI", 39.1774, -76.6684},
    {"SLC", 40.7899, -111.9791}, {"SAN", 32.7338, -117.1933}, {"IAD", 38.9531, -77.4565},
    {"DCA", 38.8512, -77.0402}, {"MDW", 41.7868, -87.7522}, {"TPA", 27.9772, -82.5311},
    {"PDX", 45.5898, -122.5951}, {"STL", 38.7499, -90.3748}, {"MCI", 39.2976, -94.7139},
    {"AUS", 30.1975, -97.6664}, {"SMF", 38.6951, -121.5908}, {"SJC", 37.3639, -121.9289},
    {"RDU", 35.8801, -78.7880}, {"CLE", 41.4117, -81.8498}, {"PIT", 40.4919, -80.2329},
    {"CVG", 39.0533, -84.6630}, {"CMH", 39.9980, -82.8919}, {"IND", 39.7169, -86.2956},
    {"BNA", 36.1263, -86.6774}, {"MSY", 29.9911, -90.2592}, {"SAT", 29.5312, -98.4683}
  ]

  # the Python program; lat1/lon1/lat2/lon2/code1/code2 arrive as injected variables
  @py """
  import math
  R = 6371.0088
  p1 = math.radians(lat1)
  p2 = math.radians(lat2)
  a = math.sin(math.radians(lat2 - lat1) / 2)**2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2)**2
  d = 2 * R * math.asin(math.sqrt(a))
  print(f"{code1}->{code2} {d} km")
  """

  def main do
    n = String.to_integer(System.get_env("N") || "40")
    seed = String.to_integer(System.get_env("SEED") || "1")
    :rand.seed(:exsss, {seed, 271, 828})
    pairs =
      Stream.repeatedly(fn ->
        [a, b] = Enum.take_random(@airports, 2)
        {a, b}
      end)
      |> Enum.take(n)

    IO.puts("\n══════════ HAVERSINE: #{n} random CONUS pairs · pyex local (BEAM) vs pyex-wasm (Workers) ══════════\n")

    local = local_runs(pairs)
    {remote, http_ms, eval_ms} = remote_runs(pairs)

    # exact = byte-identical transcript; ulp = same to within 1e-12 relative (the documented
    # :math fidelity boundary — libm vs V8 transcendentals differ in the last ulp; LIMITATIONS §1.1)
    {exact, ulp} =
      Enum.zip([pairs, local, remote])
      |> Enum.reduce({0, 0}, fn {{{c1, _, _}, {c2, _, _}}, {_us, l}, r}, {ex, ul} ->
        cond do
          l == r ->
            {ex + 1, ul}
          ulp_close?(l, r) ->
            IO.puts("  ≈ #{c1}->#{c2} (1-ulp transcendental delta: libm vs V8)")
            {ex, ul + 1}
          true ->
            IO.puts("  ✗ #{c1}->#{c2} REAL DIVERGENCE")
            IO.puts("     beam: #{l |> String.split("\n") |> Enum.at(1)}")
            IO.puts("     wasm: #{r |> String.split("\n") |> Enum.at(1)}")
            {ex, ul}
        end
      end)
    matches = exact + ulp

    {l1, _} = hd(local)
    sample = local |> hd() |> elem(1) |> String.split("\n") |> Enum.at(1)
    IO.puts("  sample: #{sample}   (local eval #{Float.round(l1 / 1000, 2)} ms)")
    IO.puts("\n  transcripts: #{exact}/#{n} byte-identical · #{ulp}/#{n} within 1 ulp (libm-vs-V8) · #{n - matches}/#{n} divergent")

    lus = local |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    IO.puts("\n  local (pyex on BEAM, in-process):")
    IO.puts("     p50=#{ms(pct(lus, 0.5))}  p90=#{ms(pct(lus, 0.9))}  p99=#{ms(pct(lus, 0.99))}  (per eval)")
    IO.puts("  remote (pyex on WasmGC, production Workers, from this client):")
    IO.puts("     HTTP   p50=#{fms(pct(http_ms, 0.5))}  p90=#{fms(pct(http_ms, 0.9))}  p99=#{fms(pct(http_ms, 0.99))}")
    IO.puts("     server p50=#{fms(pct(eval_ms, 0.5))}  p90=#{fms(pct(eval_ms, 0.9))}  p99=#{fms(pct(eval_ms, 0.99))}  (x-eval-ms)")
    if matches != n, do: System.halt(1)
  end


  # both lines parse as "C1->C2 <float> km": compare the floats at 1e-12 relative tolerance
  defp ulp_close?(l, r) do
    with [_, dl] <- Regex.run(~r/ ([\d.]+) km/, l),
         [_, dr] <- Regex.run(~r/ ([\d.]+) km/, r) do
      a = String.to_float(dl)
      b = String.to_float(dr)
      abs(a - b) <= 1.0e-12 * max(abs(a), abs(b))
    else
      _ -> false
    end
  end

  defp pct(sorted, q), do: Enum.at(sorted, min(length(sorted) - 1, trunc(q * length(sorted))))
  defp ms(us), do: "#{Float.round(us / 1000, 2)}ms"
  defp fms(v), do: "#{v}ms"

  defp prelude({{c1, lat1, lon1}, {c2, lat2, lon2}}) do
    # EXACTLY the worker's injection format: numbers raw, strings JSON-quoted
    "lat1 = #{lat1}\nlon1 = #{lon1}\nlat2 = #{lat2}\nlon2 = #{lon2}\ncode1 = \"#{c1}\"\ncode2 = \"#{c2}\""
  end

  defp local_runs(pairs) do
    sources = Enum.map(pairs, fn p -> prelude(p) <> "\n" <> @py end)
    code = """
    for src <- #{inspect(sources, limit: :infinity, printable_limit: :infinity)} do
      {us, out} = :timer.tc(fn -> PyexWasm.eval(src) end)
      IO.puts("B64:" <> Integer.to_string(us) <> ":" <> Base.encode64(out))
    end
    """
    {out, 0} = System.cmd("mix", ["run", "-e", code], cd: @app, env: [{"MIX_ENV", "dev"}])
    out
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "B64:"))
    |> Enum.map(fn "B64:" <> rest ->
      [us, b] = String.split(rest, ":", parts: 2)
      {String.to_integer(us), Base.decode64!(b)}
    end)
  end

  defp remote_runs(pairs) do
    :inets.start()
    :ssl.start()
    # warm the isolate
    :httpc.request(:post, {~c"#{@remote}/?lat1=1.0&lon1=1.0&lat2=2.0&lon2=2.0&code1=A&code2=B", [], ~c"text/plain", @py}, [timeout: 30_000], body_format: :binary)
    results =
      Enum.map(pairs, fn {{c1, lat1, lon1}, {c2, lat2, lon2}} = _pair ->
        q = "lat1=#{lat1}&lon1=#{lon1}&lat2=#{lat2}&lon2=#{lon2}&code1=#{c1}&code2=#{c2}"
        t0 = System.monotonic_time(:microsecond)
        {:ok, {{_, 200, _}, headers, body}} =
          :httpc.request(:post, {~c"#{@remote}/?#{q}", [], ~c"text/plain", @py}, [timeout: 30_000], body_format: :binary)
        dt = (System.monotonic_time(:microsecond) - t0) / 1000
        eval = headers |> Enum.find_value(fn {k, v} -> if to_string(k) == "x-eval-ms", do: String.to_integer(to_string(v)) end) || -1
        {body, Float.round(dt, 1), eval}
      end)
    {Enum.map(results, &elem(&1, 0)),
     results |> Enum.map(&elem(&1, 1)) |> Enum.sort(),
     results |> Enum.map(&elem(&1, 2)) |> Enum.sort()}
  end
end

HaversineBench.main()
