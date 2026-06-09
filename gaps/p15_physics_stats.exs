# extra: Integer
# A units/physics converter and statistics package built on FLOATS and :math: unit-system conversions,
# mean/variance/stddev/median, linear regression (slope/intercept/r), Euclidean distances (sqrt),
# compound interest (pow), and trig (sin/cos/log/exp) on seed-derived angles. EVERY float is folded via
# the kit's intify (trunc * 1e6) so tiny ULP noise surfaces real divergence. Pure & deterministic.
defmodule Gap15 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    h = 14_695_981
    h = mix(h, s0)

    # ---- generate a seed-derived sample of floats ----
    {raw, s1} = gen_floats(64, s0, [])
    h = mix(h, length(raw))
    # scale into a realistic range (e.g. temperatures in Celsius -50..150)
    xs = Enum.map(raw, fn r -> -50.0 + r * 200.0 end)
    h = fold_floats(h, xs)

    # ---- unit conversions: Celsius<->Fahrenheit<->Kelvin ----
    fs = Enum.map(xs, fn c -> c * 9.0 / 5.0 + 32.0 end)
    ks = Enum.map(xs, fn c -> c + 273.15 end)
    h = h |> fold_floats(fs) |> fold_floats(ks)
    # round-trip F->C and fold the residual
    back = Enum.map(fs, fn f -> (f - 32.0) * 5.0 / 9.0 end)
    resid = Enum.zip(xs, back) |> Enum.map(fn {a, b} -> a - b end) |> Enum.sum()
    h = mix(h, resid)

    # ---- distance / length unit conversions (meters <-> feet <-> miles) ----
    {dists, s2} = gen_floats(40, s1, [])
    meters = Enum.map(dists, fn d -> d * 10_000.0 end)
    feet = Enum.map(meters, &(&1 * 3.280839895))
    miles = Enum.map(meters, &(&1 / 1609.344))
    h = h |> fold_floats(feet) |> fold_floats(miles)
    h = mix(h, Enum.sum(meters))

    # ---- descriptive statistics ----
    n = length(xs)
    mean = Enum.sum(xs) / n
    var = (xs |> Enum.map(fn x -> (x - mean) * (x - mean) end) |> Enum.sum()) / n
    sd = :math.sqrt(var)
    sorted = Enum.sort(xs)
    median = median(sorted)
    {mn, mx} = Enum.min_max(xs)
    range = mx - mn
    h = h |> mix(mean) |> mix(var) |> mix(sd) |> mix(median) |> mix(mn) |> mix(mx) |> mix(range)
    # quartiles & IQR
    q1 = percentile(sorted, 0.25)
    q3 = percentile(sorted, 0.75)
    h = h |> mix(q1) |> mix(q3) |> mix(q3 - q1)
    # skewness surrogate via third standardized moment
    skew =
      if sd > 0.0 do
        (xs |> Enum.map(fn x -> :math.pow((x - mean) / sd, 3.0) end) |> Enum.sum()) / n
      else
        0.0
      end
    h = mix(h, skew)

    # ---- linear regression on (i, xs) pairs ----
    pts = xs |> Enum.with_index() |> Enum.map(fn {y, i} -> {i * 1.0, y} end)
    {slope, intercept, r} = regression(pts)
    h = h |> mix(slope) |> mix(intercept) |> mix(r)
    # predicted values & residual sum of squares
    rss =
      pts
      |> Enum.map(fn {x, y} -> p = slope * x + intercept; (y - p) * (y - p) end)
      |> Enum.sum()
    h = mix(h, rss)

    # ---- Euclidean distances between consecutive 2D points (sqrt) ----
    {coords, s3} = gen_points(30, s2, [])
    seglens =
      coords
      |> Enum.zip(Enum.drop(coords, 1))
      |> Enum.map(fn {{x1, y1}, {x2, y2}} ->
        :math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1))
      end)
    h = fold_floats(h, seglens)
    h = mix(h, Enum.sum(seglens))

    # ---- compound interest (pow) over seed-derived rates ----
    {rates, s4} = gen_floats(12, s3, [])
    principal = 1000.0
    finals =
      Enum.map(rates, fn r ->
        rate = 0.01 + r * 0.2
        principal * :math.pow(1.0 + rate / 12.0, 12.0 * 10.0)
      end)
    h = fold_floats(h, finals)
    # continuous compounding via exp
    cont = Enum.map(rates, fn r -> principal * :math.exp((0.01 + r * 0.2) * 5.0) end)
    h = fold_floats(h, cont)

    # ---- trigonometry on seed-derived angles ----
    {angs, s5} = gen_floats(48, s4, [])
    angles = Enum.map(angs, fn a -> a * 2.0 * :math.pi() end)
    trig =
      Enum.map(angles, fn t ->
        :math.sin(t) + :math.cos(t) + :math.sin(t) * :math.cos(t)
      end)
    h = fold_floats(h, trig)
    # Pythagorean identity residual (should be ~0) folded to catch divergence
    pyth =
      angles
      |> Enum.map(fn t -> s = :math.sin(t); c = :math.cos(t); s * s + c * c - 1.0 end)
      |> Enum.sum()
    h = mix(h, pyth)
    # tan via sin/cos and atan round-trip
    rt =
      angles
      |> Enum.take(20)
      |> Enum.map(fn t -> :math.atan(:math.sin(t) / :math.cos(t)) end)
      |> Enum.sum()
    h = mix(h, rt)

    # ---- logarithms / exponentials ----
    {ls, _s6} = gen_floats(24, s5, [])
    logs = Enum.map(ls, fn v -> :math.log(1.0 + v * 1000.0) end)
    log2s = Enum.map(ls, fn v -> :math.log2(2.0 + v * 1000.0) end)
    log10s = Enum.map(ls, fn v -> :math.log10(10.0 + v * 1000.0) end)
    h = h |> fold_floats(logs) |> fold_floats(log2s) |> fold_floats(log10s)
    # geometric mean via logs
    gm = :math.exp((logs |> Enum.sum()) / length(logs))
    h = mix(h, gm)

    # ---- harmonic & RMS means ----
    pos = Enum.map(xs, fn x -> :math.sqrt(x * x) + 1.0 end)
    hm = length(pos) / (pos |> Enum.map(&(1.0 / &1)) |> Enum.sum())
    rms = :math.sqrt((pos |> Enum.map(&(&1 * &1)) |> Enum.sum()) / length(pos))
    h = h |> mix(hm) |> mix(rms)

    # ---- floor/ceil/round/trunc integer extractions ----
    h =
      Enum.reduce(Enum.take(xs, 16), h, fn x, acc ->
        acc
        |> mix(trunc(Float.floor(x)))
        |> mix(trunc(Float.ceil(x)))
        |> mix(round(x))
        |> mix(trunc(x))
      end)
    h
  end

  defp median(sorted) do
    n = length(sorted)
    mid = div(n, 2)
    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    end
  end

  defp percentile(sorted, p) do
    n = length(sorted)
    idx = p * (n - 1)
    lo = trunc(Float.floor(idx))
    hi = trunc(Float.ceil(idx))
    frac = idx - lo
    Enum.at(sorted, lo) * (1.0 - frac) + Enum.at(sorted, hi) * frac
  end

  defp regression(pts) do
    n = length(pts) * 1.0
    sx = pts |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    sy = pts |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    sxx = pts |> Enum.map(fn {x, _} -> x * x end) |> Enum.sum()
    syy = pts |> Enum.map(fn {_, y} -> y * y end) |> Enum.sum()
    sxy = pts |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    denom = n * sxx - sx * sx
    slope = if denom != 0.0, do: (n * sxy - sx * sy) / denom, else: 0.0
    intercept = (sy - slope * sx) / n
    rden = :math.sqrt((n * sxx - sx * sx) * (n * syy - sy * sy))
    r = if rden != 0.0, do: (n * sxy - sx * sy) / rden, else: 0.0
    {slope, intercept, r}
  end

  defp gen_floats(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_floats(k, s, acc) do
    {v, s1} = rng(s, 1_000_000)
    gen_floats(k - 1, s1, [v / 1_000_000.0 | acc])
  end

  defp gen_points(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_points(k, s, acc) do
    {a, s1} = rng(s, 100_000)
    {b, s2} = rng(s1, 100_000)
    gen_points(k - 1, s2, [{a / 1000.0, b / 1000.0} | acc])
  end

  defp fold_floats(h, l), do: Enum.reduce(l, h, fn e, a -> mix(a, e) end)

  # ---- shared checksum kit (identical across the gap corpus) ----
  defp rng(s, m), do: {rem(div(s, 65_536), max(m, 1)), nxt(s)}
  defp nxt(s), do: rem(s * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407, @lcg)
  defp mix(h, x), do: rem(h * 1_000_003 + intify(x) + 1, @cmod)
  defp fold_list(h, l), do: Enum.reduce(l, h, fn e, a -> mix(a, e) end)
  defp fold_map(h, m), do: Enum.reduce(Enum.sort(Map.to_list(m)), h, fn {k, v}, a -> a |> mix(k) |> mix(v) end)
  defp intify(x) when is_integer(x), do: rem(abs(x), @cmod)
  defp intify(x) when is_float(x), do: trunc(x * 1_000_000)
  defp intify(x) when is_binary(x), do: bsum(x, 7)
  defp intify(true), do: 2
  defp intify(false), do: 3
  defp intify(nil), do: 5
  defp intify(x) when is_atom(x), do: bsum(Atom.to_string(x), 11)
  defp intify(x) when is_list(x), do: Enum.reduce(x, 13, fn e, a -> mix(a, intify(e)) end)
  defp intify(x) when is_tuple(x), do: intify(Tuple.to_list(x))
  defp bsum(<<>>, a), do: a
  defp bsum(<<c, r::binary>>, a), do: bsum(r, rem(a * 131 + c, @cmod))
end
