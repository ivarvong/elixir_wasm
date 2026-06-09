# A pure poker hand scorer / tournament. Deal random 5-card hands from a 52-card deck (cards as
# {rank, suit} tuples) using a seed-driven Fisher-Yates shuffle, classify each hand (high card,
# pair, two-pair, trips, straight, flush, full-house, quads, straight-flush) with hand-written rank
# counting, compute comparable hand values, sort a tournament, and tally results. Deterministic.
defmodule Gap13 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  # ranks 2..14 (14 = ace), suits 0..3
  @ranks Enum.to_list(2..14)
  @suits [0, 1, 2, 3]

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    deck = for r <- @ranks, s <- @suits, do: {r, s}

    h = 14_695_981
    h = mix(h, length(deck))

    nhands = 40 + rem(seed, 20)
    {hands, s1} = deal_hands(nhands, deck, s0, [])

    # classify each hand, fold its category + tiebreak value
    classified = Enum.map(hands, fn cards -> {cards, classify(cards)} end)

    h =
      Enum.reduce(classified, h, fn {cards, {cat, tiebreak}}, acc ->
        acc
        |> mix(cat_rank(cat))
        |> fold_list(tiebreak)
        |> fold_list(Enum.map(cards, &card_sig/1))
      end)

    # category histogram across all hands
    cat_hist =
      Enum.reduce(classified, %{}, fn {_c, {cat, _}}, m ->
        Map.update(m, cat, 1, &(&1 + 1))
      end)
    h = fold_map(h, cat_hist)

    # comparable integer value per hand (category dominates, then tiebreak digits)
    valued = Enum.map(classified, fn {cards, cls} -> {hand_value(cls), cards, cls} end)
    h = fold_list(h, Enum.map(valued, fn {v, _, _} -> v end))

    # tournament: sort hands strongest first, fold ranking
    ranked = Enum.sort_by(valued, fn {v, _, _} -> -v end)
    h =
      ranked
      |> Enum.with_index(1)
      |> Enum.reduce(h, fn {{v, cards, {cat, _}}, place}, acc ->
        acc
        |> mix(place)
        |> mix(v)
        |> mix(cat_rank(cat))
        |> mix(hand_key(cards))
      end)

    # winner and loser detail
    {wv, wcards, {wcat, wtb}} = hd(ranked)
    {lv, lcards, {lcat, ltb}} = List.last(ranked)
    h =
      h
      |> mix(wv)
      |> mix(cat_rank(wcat))
      |> fold_list(wtb)
      |> fold_list(Enum.map(wcards, &card_sig/1))
      |> mix(lv)
      |> mix(cat_rank(lcat))
      |> fold_list(ltb)
      |> fold_list(Enum.map(lcards, &card_sig/1))

    # round-robin: count pairwise wins (hand i beats hand j when value greater)
    values = Enum.map(valued, fn {v, _, _} -> v end)
    wins =
      Enum.map(values, fn v -> Enum.count(values, fn o -> v > o end) end)
    h = fold_list(h, wins)
    h = mix(h, Enum.sum(wins))

    # suit/rank distribution across all dealt cards
    all_cards = Enum.concat(hands)
    rank_hist = Enum.reduce(all_cards, %{}, fn {r, _}, m -> Map.update(m, r, 1, &(&1 + 1)) end)
    suit_hist = Enum.reduce(all_cards, %{}, fn {_, s}, m -> Map.update(m, s, 1, &(&1 + 1)) end)
    h = h |> fold_map(rank_hist) |> fold_map(suit_hist)

    # high-card sum and a sorted ranks digest
    high_sum = all_cards |> Enum.map(fn {r, _} -> r end) |> Enum.sum()
    sorted_ranks = all_cards |> Enum.map(fn {r, _} -> r end) |> Enum.sort(:desc) |> Enum.take(20)
    h = h |> mix(high_sum) |> fold_list(sorted_ranks)

    h = mix(h, s1)
    h
  end

  # ---- dealing: Fisher-Yates shuffle, take first 5 ----
  defp deal_hands(0, _deck, s, acc), do: {Enum.reverse(acc), s}
  defp deal_hands(n, deck, s, acc) do
    {shuffled, s1} = shuffle(deck, s)
    hand = Enum.take(shuffled, 5)
    deal_hands(n - 1, deck, s1, [hand | acc])
  end

  defp shuffle(list, s) do
    arr = list
    do_shuffle(arr, length(arr) - 1, s)
  end

  # swap element i with a random j in 0..i, descending
  defp do_shuffle(arr, 0, s), do: {arr, s}
  defp do_shuffle(arr, i, s) do
    {j, s1} = rng(s, i + 1)
    arr2 = swap(arr, i, j)
    do_shuffle(arr2, i - 1, s1)
  end

  defp swap(arr, i, i), do: arr
  defp swap(arr, i, j) do
    vi = Enum.at(arr, i)
    vj = Enum.at(arr, j)
    arr
    |> List.replace_at(i, vj)
    |> List.replace_at(j, vi)
  end

  # ---- hand classification ----
  # returns {category_atom, tiebreak_list} where tiebreak is ranks in descending importance.
  defp classify(cards) do
    ranks = cards |> Enum.map(fn {r, _} -> r end)
    suits = cards |> Enum.map(fn {_, s} -> s end)
    counts = rank_counts(ranks)
    # group ranks by count desc, then rank desc: list of {count, rank}
    groups =
      counts
      |> Enum.sort_by(fn {rank, cnt} -> {-cnt, -rank} end)
    count_pattern = groups |> Enum.map(fn {_r, c} -> c end)
    ordered_ranks = groups |> Enum.map(fn {r, _c} -> r end)

    is_flush = suits |> Enum.uniq() |> length() == 1
    {is_straight, straight_high} = straight_info(ranks)

    cond do
      is_straight and is_flush -> {:straight_flush, [straight_high]}
      count_pattern == [4, 1] -> {:four_kind, ordered_ranks}
      count_pattern == [3, 2] -> {:full_house, ordered_ranks}
      is_flush -> {:flush, Enum.sort(ranks, :desc)}
      is_straight -> {:straight, [straight_high]}
      count_pattern == [3, 1, 1] -> {:three_kind, ordered_ranks}
      count_pattern == [2, 2, 1] -> {:two_pair, ordered_ranks}
      count_pattern == [2, 1, 1, 1] -> {:pair, ordered_ranks}
      true -> {:high_card, Enum.sort(ranks, :desc)}
    end
  end

  # hand-written rank frequency counting (no Enum.frequencies)
  defp rank_counts(ranks) do
    ranks
    |> Enum.reduce(%{}, fn r, m -> Map.update(m, r, 1, &(&1 + 1)) end)
    |> Map.to_list()
  end

  # straight detection; handles wheel A-2-3-4-5 (ace low)
  defp straight_info(ranks) do
    uniq = ranks |> Enum.uniq() |> Enum.sort()
    cond do
      length(uniq) != 5 -> {false, 0}
      consecutive?(uniq) -> {true, List.last(uniq)}
      uniq == [2, 3, 4, 5, 14] -> {true, 5}
      true -> {false, 0}
    end
  end

  defp consecutive?([_]), do: true
  defp consecutive?([a, b | rest]) when b == a + 1, do: consecutive?([b | rest])
  defp consecutive?(_), do: false

  defp cat_rank(:high_card), do: 1
  defp cat_rank(:pair), do: 2
  defp cat_rank(:two_pair), do: 3
  defp cat_rank(:three_kind), do: 4
  defp cat_rank(:straight), do: 5
  defp cat_rank(:flush), do: 6
  defp cat_rank(:full_house), do: 7
  defp cat_rank(:four_kind), do: 8
  defp cat_rank(:straight_flush), do: 9

  # comparable value: category in high digits, then tiebreak ranks base-15
  defp hand_value({cat, tiebreak}) do
    base = cat_rank(cat) * 15 * 15 * 15 * 15 * 15
    {val, _} =
      Enum.reduce(tiebreak, {base, 15 * 15 * 15 * 15}, fn r, {acc, place} ->
        {acc + r * place, max(div(place, 15), 1)}
      end)
    val
  end

  defp card_sig({r, s}), do: r * 4 + s
  defp hand_key(cards), do: cards |> Enum.map(&card_sig/1) |> Enum.sort() |> Enum.reduce(0, fn x, a -> a * 53 + x + 1 end)

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
