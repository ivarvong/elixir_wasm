# A CSV/tabular data processor: synthesize typed rows from a seed, render to CSV text, parse it back,
# validate fields, then aggregate (group-by, sums, averages, min/max, multi-column sorting) and render a
# report. Every derived value folds into a rolling checksum so any miscompiled stdlib changes Gap02.run(seed).
# Pure & deterministic.
defmodule Gap02 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @depts ~w(eng sales ops legal data design mktg support)
  @cities ~w(amsterdam berlin paris lisbon oslo dublin madrid prague)
  @names ~w(ada alan grace linus edsger barbara john donald ken dennis margaret tim)

  def run(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    {rows, s1} = gen_rows(40 + rem(seed, 25), s0, [])
    h = 14_695_981
    h = mix(h, length(rows))

    # render to CSV text (header + records)
    header = "id,name,dept,city,salary,age,active"
    lines = Enum.map(rows, fn r -> render_row(r) end)
    csv = Enum.join([header | lines], "\n")
    h = h |> mix(String.length(csv)) |> mix(byte_size(csv)) |> mix(length(lines))

    # parse it back from text
    parsed = parse_csv(csv)
    h = mix(h, length(parsed))
    h = Enum.reduce(parsed, h, fn rec, a ->
      a |> mix(rec.id) |> mix(rec.name) |> mix(rec.dept) |> mix(rec.salary) |> mix(rec.age)
    end)

    # validation: salary in band, age in band, name nonempty
    {valid, invalid} = Enum.split_with(parsed, &valid?/1)
    h = h |> mix(length(valid)) |> mix(length(invalid))
    h = fold_list(h, Enum.map(invalid, & &1.id) |> Enum.sort())

    # group-by dept -> aggregate salary stats
    by_dept = Enum.group_by(valid, & &1.dept)
    dept_stats =
      Map.new(by_dept, fn {d, recs} ->
        sals = Enum.map(recs, & &1.salary)
        {min, max} = Enum.min_max(sals)
        sum = Enum.sum(sals)
        avg = div(sum, length(sals))
        {d, {length(recs), sum, avg, min, max}}
      end)
    h = Enum.reduce(Enum.sort(Map.to_list(dept_stats)), h, fn {d, {n, sum, avg, mn, mx}}, a ->
      a |> mix(d) |> mix(n) |> mix(sum) |> mix(avg) |> mix(mn) |> mix(mx)
    end)

    # group-by city -> count + average age (fold via fold_map, canonical)
    by_city = Enum.group_by(valid, & &1.city, & &1.age)
    city_avg = Map.new(by_city, fn {c, ages} -> {c, div(Enum.sum(ages), length(ages))} end)
    h = fold_map(h, city_avg)
    city_count = Map.new(by_city, fn {c, ages} -> {c, length(ages)} end)
    h = fold_map(h, city_count)

    # multi-column sort: by dept asc, then salary desc, then name asc
    sorted = Enum.sort_by(valid, fn r -> {r.dept, -r.salary, r.name} end)
    h = Enum.reduce(Enum.with_index(sorted), h, fn {r, i}, a ->
      a |> mix(i) |> mix(r.id) |> mix(r.salary)
    end)
    top5 = sorted |> Enum.take(5) |> Enum.map(& &1.id)
    h = fold_list(h, top5)

    # active filter + payroll
    active = Enum.filter(valid, & &1.active)
    payroll = active |> Enum.map(& &1.salary) |> Enum.sum()
    h = h |> mix(length(active)) |> mix(payroll)

    # salary buckets (histogram) via reduce + Map.update
    buckets =
      Enum.reduce(valid, %{}, fn r, m ->
        b = div(r.salary, 20_000)
        Map.update(m, b, 1, &(&1 + 1))
      end)
    h = fold_map(h, buckets)

    # tax computation per record (integer brackets), summed
    tax_total =
      valid
      |> Enum.map(fn r -> compute_tax(r.salary) end)
      |> Enum.sum()
    h = mix(h, tax_total)

    # report text: top earners per dept
    report =
      by_dept
      |> Enum.sort_by(fn {d, _} -> d end)
      |> Enum.map(fn {d, recs} ->
        top = recs |> Enum.max_by(& &1.salary)
        "#{d}: #{top.name}=#{top.salary}"
      end)
      |> Enum.join("; ")
    h = h |> mix(report) |> mix(String.length(report)) |> mix(String.upcase(report))

    # pivot: dept x active-flag counts
    pivot =
      Enum.reduce(valid, %{}, fn r, m ->
        key = {r.dept, r.active}
        Map.update(m, key, 1, &(&1 + 1))
      end)
    h = Enum.reduce(Enum.sort(Map.to_list(pivot)), h, fn {{d, act}, n}, a ->
      a |> mix(d) |> mix(act) |> mix(n)
    end)

    # ranking: percentile-ish position of each salary
    all_sals = valid |> Enum.map(& &1.salary) |> Enum.sort()
    rank_sum =
      Enum.reduce(valid, 0, fn r, acc ->
        below = Enum.count(all_sals, &(&1 < r.salary))
        acc + below
      end)
    h = mix(h, rank_sum)

    # running totals (scan) over sorted salaries
    running = Enum.scan(all_sals, &(&1 + &2))
    h = h |> fold_list(running) |> mix(List.last(running) || 0)

    # dedup names, set-style stats
    uniq_names = valid |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()
    h = h |> mix(length(uniq_names)) |> fold_list(uniq_names)

    h = mix(h, s1)
    h
  end

  defp gen_rows(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_rows(n, s, acc) do
    {id, s1} = rng(s, 100_000)
    {ni, s2} = rng(s1, length(@names))
    {di, s3} = rng(s2, length(@depts))
    {ci, s4} = rng(s3, length(@cities))
    {sal, s5} = rng(s4, 140_000)
    {age, s6} = rng(s5, 70)
    {act, s7} = rng(s6, 2)
    row = %{
      id: id,
      name: Enum.at(@names, ni),
      dept: Enum.at(@depts, di),
      city: Enum.at(@cities, ci),
      salary: sal + 10_000,
      age: age + 18,
      active: act == 1
    }
    gen_rows(n - 1, s7, [row | acc])
  end

  defp render_row(r) do
    Enum.join([r.id, r.name, r.dept, r.city, r.salary, r.age, if(r.active, do: "1", else: "0")], ",")
  end

  defp parse_csv(csv) do
    [_header | data] = String.split(csv, "\n", trim: true)
    Enum.map(data, fn line ->
      [id, name, dept, city, sal, age, act] = String.split(line, ",")
      %{
        id: String.to_integer(id),
        name: name,
        dept: dept,
        city: city,
        salary: String.to_integer(sal),
        age: String.to_integer(age),
        active: act == "1"
      }
    end)
  end

  defp valid?(r) do
    r.salary >= 10_000 and r.salary <= 200_000 and r.age >= 18 and r.age <= 90 and
      String.length(r.name) > 0 and r.dept in @depts
  end

  defp compute_tax(sal) do
    cond do
      sal <= 20_000 -> div(sal * 10, 100)
      sal <= 60_000 -> 2_000 + div((sal - 20_000) * 25, 100)
      sal <= 120_000 -> 12_000 + div((sal - 60_000) * 40, 100)
      true -> 36_000 + div((sal - 120_000) * 50, 100)
    end
  end

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
