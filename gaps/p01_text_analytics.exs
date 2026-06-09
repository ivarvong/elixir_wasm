# extra: Enum String Map MapSet List
# A text-analytics pipeline: synthesize a document from a seed, then tokenize, normalize, count, rank,
# and summarize — exercising String/Enum/Map/MapSet/List broadly. Every derived value is folded into a
# rolling checksum, so any miscompiled stdlib function changes Gap01.run(seed). Pure & deterministic.
defmodule Gap01 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @vocab ~w(the quick brown fox jumps over lazy dog elixir wasm compiler beam token map list
            tree hash byte binary atom tuple guard match clause module function recur fold)

  def run(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    {words, s1} = gen_words(120 + rem(seed, 40), s0, [])
    doc = Enum.join(words, " ")
    h = 14_695_981
    h = h |> mix(String.length(doc)) |> mix(byte_size(doc))

    tokens = doc |> String.downcase() |> String.split(~r/\s+/, trim: true) |> Enum.map(&String.trim/1)
    h = mix(h, length(tokens))

    # frequency table, ranked (sort by count desc then word asc) — canonical
    freq = Enum.frequencies(tokens)
    h = fold_map(h, freq)
    ranked = freq |> Enum.sort_by(fn {w, c} -> {-c, w} end) |> Enum.take(10)
    h = Enum.reduce(ranked, h, fn {w, c}, a -> a |> mix(w) |> mix(c) end)

    # unique vocabulary as a set; set algebra
    uniq = MapSet.new(tokens)
    longish = tokens |> Enum.filter(&(String.length(&1) >= 5)) |> MapSet.new()
    h = h |> mix(MapSet.size(uniq)) |> mix(MapSet.size(MapSet.intersection(uniq, longish)))
    h = h |> mix(MapSet.size(MapSet.difference(uniq, longish)))
    h = fold_list(h, MapSet.to_list(uniq) |> Enum.sort())

    # per-initial-letter grouping and stats
    by_initial = Enum.group_by(tokens, &String.first/1)
    h = fold_map(h, Map.new(by_initial, fn {k, vs} -> {k, length(vs)} end))

    # bigrams (zip with tail), counts
    bigrams = tokens |> Enum.zip(Enum.drop(tokens, 1)) |> Enum.map(fn {a, b} -> a <> "_" <> b end)
    h = h |> mix(length(bigrams)) |> fold_map(Enum.frequencies(bigrams) |> Map.take(top_keys(bigrams)))

    # word length histogram via reduce + Map.update
    hist = Enum.reduce(tokens, %{}, fn t, m -> Map.update(m, String.length(t), 1, &(&1 + 1)) end)
    h = fold_map(h, hist)
    {minlen, maxlen} = tokens |> Enum.map(&String.length/1) |> Enum.min_max()
    total_len = tokens |> Enum.map(&String.length/1) |> Enum.sum()
    h = h |> mix(minlen) |> mix(maxlen) |> mix(total_len) |> mix(div(total_len, max(length(tokens), 1)))

    # string transforms: title-case the top words, pad, reverse, slice
    titled = ranked |> Enum.map(fn {w, _} -> String.capitalize(w) end) |> Enum.join("|")
    h = h |> mix(titled) |> mix(String.reverse(titled)) |> mix(String.pad_leading(titled, 80, "."))
    h = h |> mix(String.slice(doc, 0, 40)) |> mix(String.replace(doc, "o", "0"))
    h = mix(h, doc |> String.graphemes() |> Enum.count(&(&1 == "e")))

    # chunking + windowed aggregation
    chunks = tokens |> Enum.chunk_every(7, 7, :discard)
    chunk_sums = Enum.map(chunks, fn c -> c |> Enum.map(&String.length/1) |> Enum.sum() end)
    h = h |> mix(length(chunks)) |> fold_list(chunk_sums)
    h = mix(h, chunk_sums |> Enum.sort(:desc) |> Enum.take(3) |> Enum.sum())

    # a comprehension producing scored pairs
    scored = for {w, c} <- ranked, String.length(w) > 3, do: {w, c * String.length(w)}
    h = Enum.reduce(scored, h, fn {w, sc}, a -> a |> mix(w) |> mix(sc) end)

    # entropy-ish: integer surrogate using sum of c*c
    spread = freq |> Map.values() |> Enum.map(&(&1 * &1)) |> Enum.sum()
    h = h |> mix(spread) |> mix(map_size(freq)) |> mix(s1)
    h
  end

  defp gen_words(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_words(n, s, acc) do
    {i, s1} = rng(s, length(@vocab))
    w = Enum.at(@vocab, i)
    {cap, s2} = rng(s1, 4)
    w = if cap == 0, do: String.upcase(w), else: w
    gen_words(n - 1, s2, [w | acc])
  end

  # Tie-break by key (total order), like the `ranked` sort above. Sorting by -c ALONE leaves
  # equal-count keys in map-iteration order, which is unspecified in Elixir and legitimately
  # differs between BEAM (hash order for >32-entry maps) and the WasmGC runtime (key-sorted) —
  # so a bare -c sort makes this corpus program non-deterministic across conforming impls.
  defp top_keys(list), do: list |> Enum.frequencies() |> Enum.sort_by(fn {k, c} -> {-c, k} end) |> Enum.take(8) |> Enum.map(&elem(&1, 0))

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
