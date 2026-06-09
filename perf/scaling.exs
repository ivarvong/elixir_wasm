#!/usr/bin/env elixir
# perf/scaling.exs — complexity probe. For each operation, run it over input sizes 10 → 100k, fit
# the log-log growth exponent, and compare Wasm's exponent against the real VM's. Goal: O(1)/O(log n),
# worst case O(n). Any N² is a failure — and we flag whether it's the COMPILER's fault (Wasm worse
# than the VM) or inherent to the source.
#
# Two probe kinds:
#   bulk      — time op(n): total work building+doing as a function of n (catches bulk N², e.g. building
#               an n-entry map). This is the real-world cost.
#   isolated  — build the input ONCE (a handle), then time `reps` ops on it: the PER-OPERATION
#               complexity, with the build excluded so it can't mask the op.
#
#   elixir scaling.exs            # all probes
#   elixir scaling.exs map        # only probes whose key matches the filter
Code.require_file("jason0.exs", __DIR__)

defmodule Scaling do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../compiler/beam2wasm.exs")
  @scaler Path.join(@here, "scaling.mjs")
  @tmp Path.join(@here, "_work")
  @node System.get_env("NODE", "/Users/ivar/.nvm/versions/node/v24.16.0/bin/node")
  @wasmas System.find_executable("wasm-as") || "/opt/homebrew/bin/wasm-as"
  @reps 300

  @src """
  defmodule Scale do
    def mklist(n), do: mklist(n, [])
    defp mklist(0, acc), do: acc
    defp mklist(n, acc), do: mklist(n - 1, [n | acc])
    def mkmap(n), do: mkmap(n, %{})
    defp mkmap(0, m), do: m
    defp mkmap(n, m), do: mkmap(n - 1, Map.put(m, n, n))

    # ---- bulk probes (int -> int): total work as a function of n ----
    def bulk_map_build(n), do: map_size(mkmap(n))
    def bulk_sort(n), do: hd(Enum.sort(mklist(n)))
    def bulk_map(n), do: hd(Enum.map(mklist(n), fn x -> x + 1 end))
    def bulk_reduce(n), do: Enum.reduce(mklist(n), 0, fn x, a -> a + x end)
    def bulk_member(n), do: (l = mklist(n); memloop(n, l, 0))
    defp memloop(0, _l, a), do: a
    defp memloop(i, l, a), do: memloop(i - 1, l, a + (if Enum.member?(l, i), do: 1, else: 0))
    def bulk_uniq(n), do: length(Enum.uniq(mklist(n)))
    def bulk_badappend(n), do: hd(appendloop(mklist(n), []))
    defp appendloop([], acc), do: [0 | acc]
    defp appendloop([h | t], acc), do: appendloop(t, acc ++ [h])

    # ---- isolated probes: handle built once, then `reps` ops on it (int -> int) ----
    # spread lookups across the WHOLE key range (multiplicative hash) so a linear scan can't exit
    # early on front keys — otherwise get looks O(1) when it is really O(n).
    def op_get(m, reps), do: getreps(reps, m, map_size(m), 0)
    defp getreps(0, _m, _sz, a), do: a
    defp getreps(i, m, sz, a), do: getreps(i - 1, m, sz, a + Map.get(m, rem(i * 2_654_435_761, sz) + 1))
    def op_put(m, reps), do: putreps(reps, m, map_size(m))   # updates existing keys -> size stays n
    defp putreps(0, m, _sz), do: map_size(m)
    defp putreps(i, m, sz), do: putreps(i - 1, Map.put(m, rem(i, sz) + 1, i), sz)
  end
  """

  # {key, op, setup|nil, label, sizes}. setup=nil => bulk. isolated probes cap at 10k (building the
  # input is itself O(n^2) today, so a 100k handle is infeasible until map_put is fixed).
  @probes [
    %{key: "map_build", op: "bulk_map_build", setup: nil, label: "Map build (n puts)", sizes: [10, 100, 1000, 10_000]},
    %{key: "map_get", op: "op_get", setup: "mkmap", label: "Map.get (per op)", sizes: [10, 100, 1000, 10_000]},
    %{key: "map_put", op: "op_put", setup: "mkmap", label: "Map.put (per op, update)", sizes: [10, 100, 1000, 10_000]},
    %{key: "sort", op: "bulk_sort", setup: nil, label: "Enum.sort", sizes: [10, 100, 1000, 10_000, 100_000]},
    %{key: "map", op: "bulk_map", setup: nil, label: "Enum.map", sizes: [10, 100, 1000, 10_000, 100_000]},
    %{key: "reduce", op: "bulk_reduce", setup: nil, label: "Enum.reduce", sizes: [10, 100, 1000, 10_000, 100_000]},
    %{key: "member", op: "bulk_member", setup: nil, label: "Enum.member? ×n", sizes: [10, 100, 1000, 10_000]},
    %{key: "uniq", op: "bulk_uniq", setup: nil, label: "Enum.uniq", sizes: [10, 100, 1000, 10_000]},
    %{key: "append", op: "bulk_badappend", setup: nil, label: "++ in a loop (control)", sizes: [10, 100, 1000, 10_000]}
  ]

  def main(argv) do
    File.mkdir_p!(@tmp)
    filter = List.first(argv)
    probes = Enum.filter(@probes, fn p -> filter == nil or String.contains?(p.key, filter) end)
    wasmf = build()

    IO.puts("\n══════════ SCALING: empirical complexity (Wasm vs the Elixir VM) ══════════\n")
    IO.puts("  Goal: per-op O(log n) or better, bulk ≤ O(n). ⚠ super-linear, ❌ quadratic.\n")
    IO.puts("  #{pad("operation", 26)}#{pad("kind", 6)}#{pad("wasm exp", 10)}#{pad("vm exp", 9)}#{pad("wasm @10k", 12)}verdict")
    IO.puts("  " <> String.duplicate("─", 84))

    for p <- probes do
      pts = Enum.map(p.sizes, fn n -> measure(p, n, wasmf) end)
      wexp = fit(Enum.map(pts, fn x -> {x.n, x.wasm} end))
      bexp = fit(Enum.map(pts, fn x -> {x.n, x.beam} end))
      at10k = pts |> Enum.find(%{wasm: nil}, &(&1.n == 10_000)) |> Map.get(:wasm)
      kind = if p.setup, do: "iso", else: "bulk"
      crash = Enum.find(pts, & &1.crashed)
      v = cond do
        crash -> "❌ stack-overflow @n=#{crash.n} (VM ok — body-recursion grows the Wasm stack)"
        true -> verdict(p.setup != nil, wexp, bexp)
      end
      IO.puts("  #{pad(p.label, 26)}#{pad(kind, 6)}#{pad(fmt(wexp), 10)}#{pad(fmt(bexp), 9)}#{pad(us(at10k), 12)}#{v}")
      detail = Enum.map_join(pts, "  ", fn x -> "#{x.n}:#{if x.crashed, do: "CRASH", else: us(x.wasm)}" end)
      IO.puts("  #{pad("", 26)}#{IO.ANSI.faint()}#{detail}#{IO.ANSI.reset()}")
    end
    IO.puts("")
  end

  defp measure(p, n, wasmf) do
    point = if p.setup, do: %{op: p.op, arg: n, setup: p.setup, reps: @reps}, else: %{op: p.op, arg: n}
    pf = Path.join(@tmp, "points.json")
    File.write!(pf, Jason0.encode([point]))
    {out, status} = System.cmd(@node, [@scaler, wasmf, pf])
    w = if status == 0, do: Jason0.decode(out) |> Enum.find(%{}, &Map.has_key?(&1, "op")), else: %{}
    %{n: n, wasm: w["us_min"], crashed: w["crashed"] == true, beam: time_beam(p, n)}
  end

  # in-process VM timing, same shape (build handle once for isolated probes), median of a few trials.
  defp time_beam(p, n) do
    one =
      if p.setup do
        h = apply(Scale, String.to_atom(p.setup), [n])
        fn -> rem(apply(Scale, String.to_atom(p.op), [h, @reps]), 7) end
      else
        fn -> rem(apply(Scale, String.to_atom(p.op), [n]), 7) end
      end
    one.()
    {single_us, _} = :timer.tc(one)
    iters = max(1, min(2_000_000, round(40_000 / max(single_us, 0.5))))
    for(_ <- 1..5, do: (fn -> {us, _} = :timer.tc(fn -> Enum.each(1..iters, fn _ -> one.() end) end); us / iters end).())
    |> Enum.sort()
    |> Enum.at(2)
  end

  defp build do
    compiled = Code.compile_string(@src)
    [{mod, _} | _] = compiled
    beams = Enum.map(compiled, fn {m, b} -> p = Path.join(@tmp, "#{m}.beam"); File.write!(p, b); p end)
    extra = Enum.map([Map, Enum, Keyword, :lists, :maps], fn m -> to_string(:code.which(m)) end)
    # bulk ops: int->int; isolated ops: term,int->int; their setups: int->term.
    exports =
      (Enum.map(@probes, fn p ->
         if p.setup, do: ["#{p.op}:term,int->int", "#{p.setup}:int->term"], else: ["#{p.op}:int->int"]
       end)
       |> List.flatten() |> Enum.uniq() |> Enum.join(";"))
    watf = Path.join(@tmp, "#{mod}.wat")
    wasmf = Path.join(@tmp, "#{mod}.wasm")
    stubf = Path.join(@tmp, "scale.stubs.txt")
    cmd = "elixir #{inspect(@beam2wasm)} #{Enum.map_join(beams ++ extra, " ", &inspect/1)} > #{inspect(watf)} 2> #{inspect(stubf)}"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", exports}, {"STUB", "1"}, {"BIGNUM", "1"}])
    {_, 0} = System.cmd(@wasmas, [watf, "-o", wasmf, "-all", "-g"], stderr_to_stdout: true)
    wasmf
  end

  # least-squares slope of log(us) vs log(n) over points with n >= 100.
  defp fit(pairs) do
    pts = Enum.filter(pairs, fn {n, us} -> n >= 100 and is_number(us) and us > 0 end)
      |> Enum.map(fn {n, us} -> {:math.log(n), :math.log(us)} end)
    k = length(pts)
    if k < 2 do
      nil
    else
      sx = Enum.sum(Enum.map(pts, &elem(&1, 0)))
      sy = Enum.sum(Enum.map(pts, &elem(&1, 1)))
      sxx = Enum.sum(Enum.map(pts, fn {x, _} -> x * x end))
      sxy = Enum.sum(Enum.map(pts, fn {x, y} -> x * y end))
      (k * sxy - sx * sy) / (k * sxx - sx * sx)
    end
  end

  # isolated probes measure ONE op (slope 0 = O(1)/log n ✓, ~1 = O(n) per op = bulk N²).
  defp verdict(_iso, nil, _), do: "?"
  defp verdict(true, w, b) do
    base = cond do
      w >= 0.6 -> "❌ O(n) per op  (⇒ bulk N²)"
      w >= 0.3 -> "⚠ super-log"
      true -> "✓ O(log n)"
    end
    worse(base, w, b)
  end
  defp verdict(false, w, b) do
    base = cond do
      w >= 1.7 -> "❌ O(n²)"
      w >= 1.25 -> "⚠ super-linear"
      true -> "✓"
    end
    worse(base, w, b)
  end
  defp worse(base, w, b) when is_number(b) and w - b >= 0.4, do: base <> "  (compiler: worse than VM by #{fmt(w - b)})"
  defp worse(base, _w, _b), do: base

  defp pad(s, n), do: String.pad_trailing(to_string(s), n)
  defp fmt(nil), do: "—"
  defp fmt(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 2)
  defp fmt(x), do: to_string(x)
  defp us(nil), do: "—"
  defp us(x) when x >= 1000, do: "#{Float.round(x / 1000, 1)}ms"
  defp us(x), do: "#{Float.round(x, 2)}us"
end

Scaling.main(System.argv())
