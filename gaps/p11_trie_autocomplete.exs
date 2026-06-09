# A prefix-tree (trie) autocomplete + spell-suggest engine, all pure.
# Build a trie from a seed-generated word list (nested maps keyed by grapheme), support insert/lookup,
# prefix-search, longest-common-prefix, node/word counts, completion suggestions, and Levenshtein
# edit-distance (classic integer DP). Heavy nested Map, recursion, Enum, integer DP. Deterministic.
defmodule Gap11 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @alpha ~w(a b c d e f g h i j k l m n o p q r s t)
  @eow :__end__

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    {words, s1} = gen_words(80 + rem(seed, 30), s0, [])

    h = 14_695_981
    h = mix(h, length(words))

    # build trie by inserting each word
    trie = Enum.reduce(words, %{}, fn w, t -> insert(t, String.graphemes(w)) end)

    uniq = words |> Enum.uniq() |> Enum.sort()
    h = mix(h, length(uniq))
    h = fold_list(h, Enum.map(uniq, &byte_size/1))

    # structural counts
    nodes = count_nodes(trie)
    wcount = count_words(trie)
    h = h |> mix(nodes) |> mix(wcount)

    # lookup: each unique word should be present (invariant), plus some negatives
    present = Enum.count(uniq, fn w -> lookup(trie, String.graphemes(w)) end)
    inv_ok = if present == length(uniq), do: 1, else: 0
    h = h |> mix(present) |> mix(inv_ok)

    # prefix search: for a set of seed-derived prefixes, count completions and fold them
    {prefixes, s2} = gen_prefixes(12, s1, [])
    h =
      Enum.reduce(prefixes, h, fn p, acc ->
        comps = complete(trie, String.graphemes(p)) |> Enum.sort()
        acc
        |> mix(p)
        |> mix(length(comps))
        |> fold_list(Enum.map(comps, &bsum(&1, 17)))
      end)

    # longest common prefix across the sorted unique list
    lcp = longest_common_prefix(uniq)
    h = h |> mix(lcp) |> mix(String.length(lcp))

    # depth of trie and per-depth node histogram
    depth_hist = depth_histogram(trie, 0, %{})
    h = fold_map(h, depth_hist)
    maxdepth = depth_hist |> Map.keys() |> Enum.max(fn -> 0 end)
    h = mix(h, maxdepth)

    # Levenshtein edit distances between consecutive sorted words and across a few pairs
    dist_pairs =
      uniq
      |> Enum.zip(Enum.drop(uniq, 1))
      |> Enum.map(fn {a, b} -> {a, b, levenshtein(a, b)} end)
    h =
      Enum.reduce(dist_pairs, h, fn {a, b, d}, acc ->
        acc |> mix(a) |> mix(b) |> mix(d)
      end)
    total_dist = dist_pairs |> Enum.map(fn {_, _, d} -> d end) |> Enum.sum()
    h = mix(h, total_dist)

    # spell-suggest: for seed-derived "typo" words, find nearest dictionary words by edit distance
    {typos, s3} = gen_words(10, s2, [])
    h =
      Enum.reduce(typos, h, fn typo, acc ->
        scored =
          uniq
          |> Enum.map(fn w -> {levenshtein(typo, w), w} end)
          |> Enum.sort()
          |> Enum.take(3)
        acc
        |> mix(typo)
        |> fold_suggest(scored)
      end)

    # frequency of first letters as a sanity map
    firsts = Enum.reduce(words, %{}, fn w, m -> Map.update(m, String.first(w), 1, &(&1 + 1)) end)
    h = fold_map(h, firsts)

    # word-length histogram
    lhist = Enum.reduce(uniq, %{}, fn w, m -> Map.update(m, String.length(w), 1, &(&1 + 1)) end)
    h = fold_map(h, lhist)

    h = mix(h, s3)
    h
  end

  defp fold_suggest(h, scored) do
    Enum.reduce(scored, h, fn {d, w}, a -> a |> mix(d) |> mix(w) end)
  end

  # ---- word / prefix generation ----
  defp gen_words(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_words(n, s, acc) do
    {len, s1} = rng(s, 6)
    {w, s2} = gen_letters(len + 2, s1, [])
    gen_words(n - 1, s2, [w | acc])
  end

  defp gen_letters(0, s, acc), do: {Enum.join(Enum.reverse(acc)), s}
  defp gen_letters(n, s, acc) do
    {i, s1} = rng(s, length(@alpha))
    gen_letters(n - 1, s1, [Enum.at(@alpha, i) | acc])
  end

  defp gen_prefixes(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_prefixes(n, s, acc) do
    {len, s1} = rng(s, 3)
    {p, s2} = gen_letters(len + 1, s1, [])
    gen_prefixes(n - 1, s2, [p | acc])
  end

  # ---- trie operations (nested maps) ----
  defp insert(node, []), do: Map.update(node, @eow, 1, &(&1 + 1))
  defp insert(node, [g | rest]) do
    child = Map.get(node, g, %{})
    Map.put(node, g, insert(child, rest))
  end

  defp lookup(node, []), do: Map.has_key?(node, @eow)
  defp lookup(node, [g | rest]) do
    case Map.get(node, g) do
      nil -> false
      child -> lookup(child, rest)
    end
  end

  # walk to the prefix node, then collect all completed suffixes
  defp complete(node, []), do: collect(node, "")
  defp complete(node, [g | rest]) do
    case Map.get(node, g) do
      nil -> []
      child -> Enum.map(complete(child, rest), fn suf -> g <> suf end)
    end
  end

  defp collect(node, _prefix) do
    Enum.flat_map(node, fn
      {@eow, _} -> [""]
      {g, child} -> Enum.map(collect(child, ""), fn suf -> g <> suf end)
    end)
  end

  defp count_nodes(node) do
    Enum.reduce(node, 1, fn
      {@eow, _}, a -> a
      {_g, child}, a -> a + count_nodes(child)
    end)
  end

  defp count_words(node) do
    Enum.reduce(node, 0, fn
      {@eow, c}, a -> a + c
      {_g, child}, a -> a + count_words(child)
    end)
  end

  defp depth_histogram(node, d, hist) do
    Enum.reduce(node, hist, fn
      {@eow, _}, h -> h
      {_g, child}, h ->
        h2 = Map.update(h, d, 1, &(&1 + 1))
        depth_histogram(child, d + 1, h2)
    end)
  end

  # ---- longest common prefix of a list of strings ----
  defp longest_common_prefix([]), do: ""
  defp longest_common_prefix([w]), do: w
  defp longest_common_prefix([first | rest]) do
    Enum.reduce(rest, first, fn w, acc -> lcp2(acc, w) end)
  end

  defp lcp2(a, b), do: lcp2(String.graphemes(a), String.graphemes(b), [])
  defp lcp2([x | xs], [x | ys], acc), do: lcp2(xs, ys, [x | acc])
  defp lcp2(_, _, acc), do: acc |> Enum.reverse() |> Enum.join()

  # ---- Levenshtein edit distance, integer DP over a list-based table ----
  # prev is the full previous DP row (length |cb|+1). We build the next row left to right.
  defp levenshtein(a, b) do
    ca = String.graphemes(a)
    cb = String.graphemes(b)
    row0 = Enum.to_list(0..length(cb))
    final =
      ca
      |> Enum.with_index(1)
      |> Enum.reduce(row0, fn {ach, i}, prev ->
        # cur row starts at column 0 = i (cost of deleting i chars of `a`).
        # prev = [prev0, prev1, ...]; prev0 is the diagonal for column 1.
        [diag | above] = prev
        build_row(ach, cb, above, diag, i)
      end)
    List.last(final)
  end

  # above = prev[j..], i.e. hd(above) = prev[j] (cell directly above current).
  # diag = prev[j-1]. left = cur[j-1] (just computed). Returns new row (length |cb|+1).
  defp build_row(ach, cb, above, diag, left), do: build_row(ach, cb, above, diag, left, [left])
  defp build_row(_ach, [], _above, _diag, _left, acc), do: Enum.reverse(acc)
  defp build_row(ach, [bch | bs], [p_above | above_rest], diag, left, acc) do
    cost = if ach == bch, do: 0, else: 1
    v = Enum.min([left + 1, p_above + 1, diag + cost])
    build_row(ach, bs, above_rest, p_above, v, [v | acc])
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
