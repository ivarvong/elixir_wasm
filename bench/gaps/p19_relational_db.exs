# extra: Enum Map MapSet List
# A relational / set-algebra mini-database: tables are lists of row-maps generated from a seed. We
# implement select (filter), project (key subset), nested-loop join, group-by + aggregate, order-by,
# distinct, and union/intersect/difference over row-sets, then chain a small query. Rows are sorted
# canonically before folding so the checksum is order-independent at the boundaries. Every meaningful
# intermediate folds into a rolling checksum. Pure & deterministic.
defmodule Gap19 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @depts ~w(eng sales ops legal hr data)
  @cities ~w(ams ber lon nyc sfo tok)

  def run(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    {emps, s1} = gen_emps(18 + rem(abs(seed), 10), s0, [])
    {depts, s2} = gen_depts(s1)
    h = 14_695_981
    h = h |> mix(length(emps)) |> mix(length(depts))

    # fold raw tables canonically
    h = fold_rows(h, emps)
    h = fold_rows(h, depts)

    # SELECT: employees with salary >= 5000
    high = select(emps, fn r -> r.salary >= 5000 end)
    h = h |> mix(length(high)) |> fold_rows(high)

    # PROJECT: keep only :name and :dept
    proj = project(high, [:dept, :name])
    h = h |> mix(length(proj)) |> fold_rows(proj)

    # ORDER-BY: by {dept, -salary, name}
    ordered = order_by(emps, fn r -> {r.dept, -r.salary, r.name} end)
    h = h |> mix(length(ordered)) |> fold_rows_ordered(ordered)

    # GROUP-BY dept + aggregate (count, sum salary, max age, avg salary as integer)
    groups = group_by(emps, fn r -> r.dept end)
    aggs =
      groups
      |> Enum.map(fn {dept, rows} ->
        sal = rows |> Enum.map(& &1.salary) |> Enum.sum()
        cnt = length(rows)
        {dept,
         %{
           count: cnt,
           sum_sal: sal,
           max_age: rows |> Enum.map(& &1.age) |> Enum.max(),
           min_age: rows |> Enum.map(& &1.age) |> Enum.min(),
           avg_sal: div(sal, cnt)
         }}
      end)
      |> Enum.sort_by(fn {d, _} -> d end)

    h =
      Enum.reduce(aggs, h, fn {dept, agg}, a ->
        a |> mix(dept) |> fold_map(agg)
      end)

    # JOIN: nested-loop join employees ⋈ depts on dept key, project to {name, city, budget}
    joined = join(emps, depts, fn e -> e.dept end, fn d -> d.dept end)

    joined_rows =
      Enum.map(joined, fn {e, d} ->
        %{name: e.name, dept: e.dept, city: d.city, budget: d.budget, salary: e.salary}
      end)

    h = h |> mix(length(joined_rows)) |> fold_rows(joined_rows)

    # DISTINCT on dept
    distinct_depts = emps |> Enum.map(& &1.dept) |> distinct() |> Enum.sort()
    h = h |> mix(length(distinct_depts)) |> fold_list(distinct_depts)

    # SET ALGEBRA over row-key sets: high earners vs young employees
    set_a = emps |> select(fn r -> r.salary >= 4500 end) |> row_keys()
    set_b = emps |> select(fn r -> r.age < 35 end) |> row_keys()
    uni = MapSet.union(set_a, set_b)
    inter = MapSet.intersection(set_a, set_b)
    diff = MapSet.difference(set_a, set_b)
    h = h |> mix(MapSet.size(set_a)) |> mix(MapSet.size(set_b))
    h = h |> mix(MapSet.size(uni)) |> mix(MapSet.size(inter)) |> mix(MapSet.size(diff))
    h = fold_list(h, Enum.sort(MapSet.to_list(uni)))
    h = fold_list(h, Enum.sort(MapSet.to_list(inter)))
    h = fold_list(h, Enum.sort(MapSet.to_list(diff)))

    # Keyword-list "query plan" walked as ordered ops
    plan = [from: :emps, where: :salary, group: :dept, having: :count, order: :sum_sal]
    h = Enum.reduce(plan, h, fn {op, arg}, a -> a |> mix(op) |> mix(arg) end)
    h = mix(h, Keyword.get(plan, :group))
    h = mix(h, length(Keyword.keys(plan)))

    # CHAINED QUERY: select age>=30, join with depts, group by city, sum salaries, order by total desc
    chained =
      emps
      |> select(fn r -> r.age >= 30 end)
      |> join(depts, fn e -> e.dept end, fn d -> d.dept end)
      |> Enum.map(fn {e, d} -> %{city: d.city, salary: e.salary} end)
      |> group_by(fn r -> r.city end)
      |> Enum.map(fn {city, rows} -> {city, rows |> Enum.map(& &1.salary) |> Enum.sum()} end)
      |> Enum.sort_by(fn {city, total} -> {-total, city} end)

    h =
      Enum.reduce(chained, h, fn {city, total}, a ->
        a |> mix(city) |> mix(total)
      end)

    # UNION/INTERSECT of two projected tables as MapSets of tuples
    t1 = emps |> Enum.map(fn r -> {r.dept, r.city} end) |> MapSet.new()
    t2 = depts |> Enum.map(fn r -> {r.dept, r.city} end) |> MapSet.new()
    common = MapSet.intersection(t1, t2)
    h = h |> mix(MapSet.size(t1)) |> mix(MapSet.size(t2)) |> mix(MapSet.size(common))
    h = fold_list(h, Enum.sort(MapSet.to_list(common)))

    # Aggregate-of-aggregates: grand totals
    grand_sal = emps |> Enum.map(& &1.salary) |> Enum.sum()
    {min_sal, max_sal} = emps |> Enum.map(& &1.salary) |> Enum.min_max()
    h = h |> mix(grand_sal) |> mix(min_sal) |> mix(max_sal) |> mix(div(grand_sal, length(emps)))

    h |> mix(s2) |> mix(s1)
  end

  # ---- table generators ----
  defp gen_emps(0, s, acc), do: {Enum.reverse(acc), s}

  defp gen_emps(n, s, acc) do
    {id, s1} = rng(s, 100000)
    {di, s2} = rng(s1, length(@depts))
    {ci, s3} = rng(s2, length(@cities))
    {age, s4} = rng(s3, 45)
    {sal, s5} = rng(s4, 8000)

    row = %{
      id: id,
      name: "e#{rem(id, 1000)}",
      dept: Enum.at(@depts, di),
      city: Enum.at(@cities, ci),
      age: 22 + age,
      salary: 3000 + sal
    }

    gen_emps(n - 1, s5, [row | acc])
  end

  defp gen_depts(s) do
    {rows, s1} =
      Enum.reduce(Enum.with_index(@depts), {[], s}, fn {d, i}, {acc, st} ->
        {ci, st1} = rng(st, length(@cities))
        {bud, st2} = rng(st1, 500000)
        row = %{dept: d, city: Enum.at(@cities, rem(i + ci, length(@cities))), budget: 100000 + bud, head: "h#{i}"}
        {[row | acc], st2}
      end)

    {Enum.reverse(rows), s1}
  end

  # ---- relational operators ----
  defp select(table, pred), do: Enum.filter(table, pred)
  defp project(table, keys), do: Enum.map(table, fn r -> Map.take(r, keys) end)
  defp order_by(table, keyfun), do: Enum.sort_by(table, keyfun)
  defp group_by(table, keyfun), do: Enum.group_by(table, keyfun)
  defp distinct(list), do: list |> MapSet.new() |> MapSet.to_list()

  defp join(left, right, lkey, rkey) do
    for l <- left, r <- right, lkey.(l) == rkey.(r), do: {l, r}
  end

  defp row_keys(rows), do: rows |> Enum.map(& &1.id) |> MapSet.new()

  # ---- canonical folds ----
  # A single row folded by sorted keys.
  defp fold_row(h, row), do: fold_map(h, row)

  # Order-independent fold: sort rows by a stable canonical signature first.
  defp fold_rows(h, rows) do
    rows
    |> Enum.sort_by(&row_sig/1)
    |> Enum.reduce(h, fn r, a -> fold_row(a, r) end)
  end

  # Order-sensitive fold for order_by results.
  defp fold_rows_ordered(h, rows), do: Enum.reduce(rows, h, fn r, a -> fold_row(a, r) end)

  defp row_sig(row) do
    row |> Map.to_list() |> Enum.sort() |> Enum.map(fn {k, v} -> {to_string(k), sig_val(v)} end)
  end

  defp sig_val(v) when is_integer(v), do: {0, v}
  defp sig_val(v) when is_binary(v), do: {1, v}
  defp sig_val(v) when is_atom(v), do: {2, Atom.to_string(v)}

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
