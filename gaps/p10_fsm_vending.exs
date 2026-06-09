# A pure finite-state-machine simulation: a vending machine modeled as a state machine.
# The machine state is a map (credit, inventory, stats). A seed-generated event stream is folded
# through transitions with heavy pattern matching on {state, event}, guards, tuples and recursion.
# Every transition result and statistic is folded into a rolling checksum. Pure & deterministic.
defmodule Gap10 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616

  # slot -> {price, name}
  @catalog %{
    0 => {120, "cola"},
    1 => {95, "water"},
    2 => {150, "juice"},
    3 => {80, "chips"},
    4 => {200, "candy"},
    5 => {65, "gum"}
  }
  @coins [5, 10, 25, 100]

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    n = 200 + rem(seed, 60)
    {events, s1} = gen_events(n, s0, [])

    init_inv = Map.new(0..5, fn slot -> {slot, 4 + rem(slot * 3, 5)} end)
    state = %{
      credit: 0,
      inventory: init_inv,
      vended: 0,
      revenue: 0,
      rejected: 0,
      refunds: 0,
      refunded_coins: 0,
      max_credit: 0,
      sold_out_hits: 0,
      bad_slot: 0,
      log: []
    }

    h = 14_695_981
    h = h |> mix(n) |> mix(map_size(@catalog)) |> fold_list(@coins)
    h = fold_map(h, init_inv)

    {final, h} = Enum.reduce(events, {state, h}, fn ev, {st, acc} ->
      {st2, outcome} = step(st, ev)
      acc2 =
        acc
        |> mix(tag(outcome))
        |> mix(st2.credit)
        |> mix(st2.vended)
        |> mix(st2.revenue)
      {st2, acc2}
    end)

    # fold final inventory and aggregate stats
    h = fold_map(h, final.inventory)
    h =
      h
      |> mix(final.credit)
      |> mix(final.vended)
      |> mix(final.revenue)
      |> mix(final.rejected)
      |> mix(final.refunds)
      |> mix(final.refunded_coins)
      |> mix(final.max_credit)
      |> mix(final.sold_out_hits)
      |> mix(final.bad_slot)

    # invariant checks: revenue must equal sum over slots of sold*price (recomputed)
    sold_value =
      Enum.reduce(0..5, 0, fn slot, a ->
        {price, _} = Map.fetch!(@catalog, slot)
        start = Map.fetch!(init_inv, slot)
        now = Map.fetch!(final.inventory, slot)
        a + (start - now) * price
      end)
    inv_ok = if sold_value == final.revenue, do: 1, else: 0
    h = h |> mix(sold_value) |> mix(inv_ok)

    # the rolling log (most recent 12 outcomes) carries fine-grained history
    recent = final.log |> Enum.reverse() |> Enum.take(12)
    h = fold_list(h, Enum.map(recent, &tag/1))

    # histogram of outcomes across full log
    hist = Enum.reduce(final.log, %{}, fn o, m -> Map.update(m, otype(o), 1, &(&1 + 1)) end)
    h = fold_map(h, hist)

    # per-slot sales summary, sorted
    sales =
      Enum.map(0..5, fn slot ->
        {start, now} = {Map.fetch!(init_inv, slot), Map.fetch!(final.inventory, slot)}
        {slot, start - now}
      end)
    h = Enum.reduce(sales, h, fn {slot, cnt}, a -> a |> mix(slot) |> mix(cnt) end)
    best = sales |> Enum.sort_by(fn {slot, cnt} -> {-cnt, slot} end) |> hd()
    h = h |> mix(elem(best, 0)) |> mix(elem(best, 1))

    h = mix(h, s1)
    h
  end

  # ---- event generation ----
  # events: {:coin, value} | {:select, slot} | :refund | :inspect
  defp gen_events(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_events(n, s, acc) do
    {kind, s1} = rng(s, 10)
    {ev, s2} =
      cond do
        kind < 5 ->
          {ci, sx} = rng(s1, length(@coins))
          {{:coin, Enum.at(@coins, ci)}, sx}
        kind < 8 ->
          {slot, sx} = rng(s1, 8)
          {{:select, slot}, sx}
        kind < 9 ->
          {:refund, s1}
        true ->
          {:inspect, s1}
      end
    gen_events(n - 1, s2, [ev | acc])
  end

  # ---- transition function: pattern-match heavily on {state, event} ----
  defp step(st, {:coin, v}) when v > 0 do
    credit = st.credit + v
    st = %{st | credit: credit, max_credit: max(st.max_credit, credit)}
    push(st, {:accepted_coin, v, credit})
  end

  defp step(st, {:select, slot}) when slot >= 0 and slot <= 5 do
    {price, name} = Map.fetch!(@catalog, slot)
    stock = Map.fetch!(st.inventory, slot)
    cond do
      stock <= 0 ->
        st = %{st | sold_out_hits: st.sold_out_hits + 1}
        push(st, {:sold_out, slot})
      st.credit < price ->
        st = %{st | rejected: st.rejected + 1}
        push(st, {:insufficient, slot, price - st.credit})
      true ->
        change = st.credit - price
        st = %{
          st
          | credit: 0,
            vended: st.vended + 1,
            revenue: st.revenue + price,
            inventory: Map.update!(st.inventory, slot, &(&1 - 1))
        }
        push(st, {:vended, slot, name, price, change})
    end
  end

  defp step(st, {:select, slot}) do
    st = %{st | bad_slot: st.bad_slot + 1}
    push(st, {:bad_slot, slot})
  end

  defp step(%{credit: 0} = st, :refund) do
    push(st, {:nothing_to_refund})
  end

  defp step(st, :refund) do
    {coins, count} = make_change(st.credit)
    st = %{st | credit: 0, refunds: st.refunds + 1, refunded_coins: st.refunded_coins + count}
    push(st, {:refunded, coins, count})
  end

  defp step(st, :inspect) do
    total = st.inventory |> Map.values() |> Enum.sum()
    push(st, {:inspected, total, st.credit})
  end

  # greedy change-making over coin denominations (largest first)
  defp make_change(amount), do: make_change(Enum.sort(@coins, :desc), amount, [], 0)
  defp make_change(_, 0, acc, n), do: {Enum.reverse(acc), n}
  defp make_change([], _rem, acc, n), do: {Enum.reverse(acc), n}
  defp make_change([c | rest], amount, acc, n) when c <= amount do
    k = div(amount, c)
    make_change(rest, rem(amount, c), [{c, k} | acc], n + k)
  end
  defp make_change([_ | rest], amount, acc, n), do: make_change(rest, amount, acc, n)

  defp push(st, outcome), do: {%{st | log: [outcome | st.log]}, outcome}

  # outcome tagging — turns a transition tuple into an integer signature
  defp tag(outcome), do: intify(outcome)

  defp otype(o) when is_tuple(o), do: elem(o, 0)

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
