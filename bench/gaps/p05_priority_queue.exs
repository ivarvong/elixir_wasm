# A priority-queue / sorting library: an immutable pairing heap (tuple/list nodes), push seed-derived
# elements then pop-min repeatedly to heap-sort; a hand-written merge-sort and quick-sort; and a
# leftist-heap variant. All sorts cross-check against each other and against Enum.sort, folding agreement
# into the checksum. Heavy recursion / tuples / lists / comparison. Pure & deterministic.
defmodule Gap05 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616

  def run(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    {nums, s1} = gen_nums(80 + rem(seed, 40), s0, [])
    h = 14_695_981
    h = mix(h, length(nums)) |> fold_list(nums)

    reference = Enum.sort(nums)
    h = fold_list(h, reference)

    # pairing-heap heap-sort
    pheap = Enum.reduce(nums, :empty, fn x, hp -> ph_insert(hp, x) end)
    {ph_sorted, ph_pops} = ph_drain(pheap, [])
    h = h |> fold_list(ph_sorted) |> mix(ph_pops)
    h = mix(h, agree(ph_sorted, reference))

    # leftist-heap heap-sort
    lheap = Enum.reduce(nums, :leaf, fn x, hp -> lh_insert(hp, x) end)
    lh_sorted = lh_drain(lheap, [])
    h = h |> fold_list(lh_sorted) |> mix(agree(lh_sorted, reference))
    h = mix(h, lh_rank(lheap))

    # merge sort
    ms = merge_sort(nums)
    h = h |> fold_list(ms) |> mix(agree(ms, reference))

    # quick sort
    qs = quick_sort(nums)
    h = h |> fold_list(qs) |> mix(agree(qs, reference))

    # insertion sort (for good measure)
    is_ = insertion_sort(nums)
    h = h |> fold_list(is_) |> mix(agree(is_, reference))

    # descending variants via custom comparator
    desc = Enum.sort(nums, &(&1 >= &2))
    ms_desc = ms |> Enum.reverse()
    h = h |> fold_list(desc) |> mix(agree(ms_desc, desc))

    # k-smallest via heap (pop k times)
    k = 10
    {ksmall, _} = ph_take(pheap, k, [])
    h = h |> fold_list(ksmall) |> mix(length(ksmall))
    h = mix(h, agree(ksmall, Enum.take(reference, k)))

    # median + quartiles from sorted
    med = nth(reference, div(length(reference), 2))
    q1 = nth(reference, div(length(reference), 4))
    q3 = nth(reference, div(3 * length(reference), 4))
    h = h |> mix(med) |> mix(q1) |> mix(q3)

    # priority queue as event scheduler: pairs {priority, payload}, drain in priority order
    {events, s2} = gen_events(40 + rem(seed, 20), s1, [])
    eheap = Enum.reduce(events, :empty, fn ev, hp -> ph_insert_by(hp, ev, fn {p, _} -> p end) end)
    drained = ph_drain_by(eheap, [], fn {p, _} -> p end)
    h = mix(h, length(drained))
    h =
      Enum.reduce(drained, h, fn {p, pay}, a -> a |> mix(p) |> mix(pay) end)
    # verify priorities come out non-decreasing
    prios = Enum.map(drained, fn {p, _} -> p end)
    h = mix(h, if(prios == Enum.sort(prios), do: 1, else: 0))

    # merge two sorted runs (classic merge), checksum the merge
    {a_run, s3} = gen_nums(30, s2, [])
    {b_run, _} = gen_nums(30, s3, [])
    merged = merge(Enum.sort(a_run), Enum.sort(b_run))
    h = h |> fold_list(merged) |> mix(agree(merged, Enum.sort(a_run ++ b_run)))

    # stable counting-ish stats: frequency, mode
    freq = Enum.frequencies(nums)
    h = fold_map(h, freq)
    {mode_v, mode_c} = freq |> Enum.max_by(fn {v, c} -> {c, v} end)
    h = h |> mix(mode_v) |> mix(mode_c)

    # running min/max scan
    run_min = Enum.scan(nums, fn x, acc -> min(x, acc) end)
    run_max = Enum.scan(nums, fn x, acc -> max(x, acc) end)
    h = h |> fold_list(run_min) |> fold_list(run_max)

    # heapify cost surrogate: total comparisons via sizes
    modprod = Enum.reduce(nums, 1, fn x, a -> rem(a * (rem(x, 9973) + 10_000), @cmod) end)
    h = h |> mix(ph_size(pheap)) |> mix(Enum.sum(nums)) |> mix(modprod)

    h = mix(h, s3)
    h
  end

  defp gen_nums(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_nums(n, s, acc) do
    {v, s1} = rng(s, 1000)
    gen_nums(n - 1, s1, [v - 500 | acc])
  end

  defp gen_events(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_events(n, s, acc) do
    {p, s1} = rng(s, 100)
    {pay, s2} = rng(s1, 10_000)
    gen_events(n - 1, s2, [{p, pay} | acc])
  end

  defp agree(a, b), do: if(a == b, do: 1, else: 0)

  defp nth([x | _], 0), do: x
  defp nth([_ | r], n), do: nth(r, n - 1)
  defp nth([], _), do: 0

  # ---- pairing heap (min) ----
  defp ph_insert(hp, x), do: ph_merge(hp, {x, []})
  defp ph_merge(:empty, h), do: h
  defp ph_merge(h, :empty), do: h
  defp ph_merge({x, hs1} = h1, {y, hs2} = h2) do
    if x <= y, do: {x, [h2 | hs1]}, else: {y, [h1 | hs2]}
  end

  defp ph_find_min({x, _}), do: x
  defp ph_delete_min({_, hs}), do: ph_merge_pairs(hs)
  defp ph_merge_pairs([]), do: :empty
  defp ph_merge_pairs([h]), do: h
  defp ph_merge_pairs([a, b | rest]), do: ph_merge(ph_merge(a, b), ph_merge_pairs(rest))

  defp ph_drain(:empty, acc), do: {Enum.reverse(acc), length(acc)}
  defp ph_drain(hp, acc), do: ph_drain(ph_delete_min(hp), [ph_find_min(hp) | acc])

  defp ph_take(:empty, _k, acc), do: {Enum.reverse(acc), 0}
  defp ph_take(_hp, 0, acc), do: {Enum.reverse(acc), 0}
  defp ph_take(hp, k, acc), do: ph_take(ph_delete_min(hp), k - 1, [ph_find_min(hp) | acc])

  defp ph_size(:empty), do: 0
  defp ph_size({_, hs}), do: 1 + Enum.reduce(hs, 0, fn h, a -> a + ph_size(h) end)

  # pairing heap keyed by a projection function
  defp ph_insert_by(hp, x, f), do: ph_merge_by(hp, {x, []}, f)
  defp ph_merge_by(:empty, h, _f), do: h
  defp ph_merge_by(h, :empty, _f), do: h
  defp ph_merge_by({x, hs1} = h1, {y, hs2} = h2, f) do
    if f.(x) <= f.(y), do: {x, [h2 | hs1]}, else: {y, [h1 | hs2]}
  end
  defp ph_delete_min_by({_, hs}, f), do: ph_merge_pairs_by(hs, f)
  defp ph_merge_pairs_by([], _f), do: :empty
  defp ph_merge_pairs_by([h], _f), do: h
  defp ph_merge_pairs_by([a, b | rest], f),
    do: ph_merge_by(ph_merge_by(a, b, f), ph_merge_pairs_by(rest, f), f)
  defp ph_drain_by(:empty, acc, _f), do: Enum.reverse(acc)
  defp ph_drain_by({x, _} = hp, acc, f), do: ph_drain_by(ph_delete_min_by(hp, f), [x | acc], f)

  # ---- leftist heap (min) ----
  # node: {rank, value, left, right}; leaf: :leaf
  defp lh_insert(hp, x), do: lh_merge(hp, {1, x, :leaf, :leaf})
  defp lh_merge(:leaf, h), do: h
  defp lh_merge(h, :leaf), do: h
  defp lh_merge({_, x, l1, r1}, {_, y, _, _} = h2) when x <= y do
    merged = lh_merge(r1, h2)
    lh_make(x, l1, merged)
  end
  defp lh_merge(h1, {_, y, l2, r2}) do
    merged = lh_merge(h1, r2)
    lh_make(y, l2, merged)
  end
  defp lh_make(x, a, b) do
    if lh_rank(a) >= lh_rank(b) do
      {lh_rank(b) + 1, x, a, b}
    else
      {lh_rank(a) + 1, x, b, a}
    end
  end
  defp lh_rank(:leaf), do: 0
  defp lh_rank({r, _, _, _}), do: r
  defp lh_drain(:leaf, acc), do: Enum.reverse(acc)
  defp lh_drain({_, x, l, r}, acc), do: lh_drain(lh_merge(l, r), [x | acc])

  # ---- merge sort ----
  defp merge_sort([]), do: []
  defp merge_sort([x]), do: [x]
  defp merge_sort(list) do
    {a, b} = Enum.split(list, div(length(list), 2))
    merge(merge_sort(a), merge_sort(b))
  end
  defp merge([], b), do: b
  defp merge(a, []), do: a
  defp merge([x | xs] = a, [y | ys] = b) do
    if x <= y, do: [x | merge(xs, b)], else: [y | merge(a, ys)]
  end

  # ---- quick sort ----
  defp quick_sort([]), do: []
  defp quick_sort([pivot | rest]) do
    {less, geq} = Enum.split_with(rest, &(&1 < pivot))
    quick_sort(less) ++ [pivot] ++ quick_sort(geq)
  end

  # ---- insertion sort ----
  defp insertion_sort(list), do: Enum.reduce(list, [], fn x, acc -> ins(x, acc) end)
  defp ins(x, []), do: [x]
  defp ins(x, [y | ys]) when x <= y, do: [x, y | ys]
  defp ins(x, [y | ys]), do: [y | ins(x, ys)]

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
