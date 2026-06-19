# extra: Enum Map List Bitwise Integer
# A compression playground: synthesize a symbol stream from the seed, run-length-encode and decode it
# (verifying the round-trip), build a frequency table, construct a deterministic Huffman-style prefix
# tree, assign codes, and compute the total encoded bit length plus a naive fixed-width baseline. Heavy
# Enum/Map/recursion/tuple/Bitwise work. Every result is folded into a rolling checksum. Pure.
import Bitwise

defmodule Gap07 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @alphabet ~w(a b c d e f g h)a

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    h = 14_695_981

    # generate a "bursty" symbol stream: each step emits a run of one symbol
    {stream, s1} = gen_stream(60 + rem(seed, 30), s0, [])
    h = mix(h, length(stream))
    h = fold_list(h, Enum.map(stream, &Atom.to_string/1))

    # ---- run-length encoding ----
    rle = rle_encode(stream)
    h = mix(h, length(rle))
    h = Enum.reduce(rle, h, fn {sym, cnt}, a -> a |> mix(sym) |> mix(cnt) end)

    # decode and verify round-trip
    decoded = rle_decode(rle)
    h = mix(h, bool_int(decoded == stream))
    h = fold_list(h, Enum.map(decoded, &Atom.to_string/1))

    # run statistics
    run_lengths = Enum.map(rle, fn {_, c} -> c end)
    {mn, mx} = Enum.min_max(run_lengths)
    h = h |> mix(mn) |> mix(mx) |> mix(Enum.sum(run_lengths))
    h = mix(h, longest_run(rle))

    # ---- frequency table ----
    freq = Enum.frequencies(stream)
    h = fold_map(h, Map.new(freq, fn {k, v} -> {Atom.to_string(k), v} end))
    total = stream |> length()
    h = mix(h, map_size(freq))

    # ---- build a deterministic Huffman tree by repeated merge of two lowest-weight nodes ----
    leaves = freq |> Enum.map(fn {sym, w} -> {w, {:leaf, sym}} end)
    tree = build_tree(leaves)
    h = mix(h, tree_weight(tree))
    h = mix(h, tree_depth(tree))
    h = mix(h, leaf_count(tree))

    # assign codes by walking the tree (left=0, right=1)
    codes = assign_codes(tree, [], %{})
    h = fold_map(h, Map.new(codes, fn {sym, bits} -> {Atom.to_string(sym), bits_to_int(bits)} end))
    h = fold_map(h, Map.new(codes, fn {sym, bits} -> {Atom.to_string(sym) <> "_len", length(bits)} end))

    # encoded bit length = sum over symbols of freq*codelen
    enc_bits =
      Enum.reduce(freq, 0, fn {sym, w}, acc ->
        acc + w * length(Map.fetch!(codes, sym))
      end)

    h = mix(h, enc_bits)

    # naive fixed-width baseline: ceil(log2(distinct)) bits per symbol
    width = bit_width(map_size(freq))
    baseline = total * width
    h = h |> mix(width) |> mix(baseline)
    # compression "savings" surrogate (avoid floats): scaled ratio
    h = mix(h, div(enc_bits * 1000, max(baseline, 1)))

    # ---- bit-packing the whole stream and Bitwise checks ----
    bitstring = stream |> Enum.flat_map(fn sym -> Map.fetch!(codes, sym) end)
    h = mix(h, length(bitstring))
    h = mix(h, bool_int(length(bitstring) == enc_bits))
    # pack bits into integers (chunks of up to 30 bits) and fold
    packed = bitstring |> Enum.chunk_every(30) |> Enum.map(&bits_to_int/1)
    h = fold_list(h, packed)
    h = mix(h, packed |> Enum.reduce(0, fn x, a -> bxor(a, x) end))
    h = mix(h, packed |> Enum.reduce(0, &bor/2))
    h = mix(h, packed |> Enum.reduce(-1, &band/2))

    # popcount over the packed words (Bitwise heavy)
    pop = packed |> Enum.map(&popcount/1) |> Enum.sum()
    h = mix(h, pop)

    # prefix-free property check: no code is a prefix of another
    h = mix(h, bool_int(prefix_free?(Map.values(codes))))

    # shifting / masking exercises
    shifts = Enum.map(packed, fn x -> bsl(x, 2) end)
    masks = Enum.map(packed, fn x -> band(x, 0xFF) end)
    h = fold_list(h, shifts)
    h = fold_list(h, masks)
    h = mix(h, Enum.map(packed, fn x -> bsr(x, 1) end) |> Enum.sum())

    # canonical code lengths sorted (Huffman canonicalization surrogate)
    canon = codes |> Enum.map(fn {sym, b} -> {length(b), Atom.to_string(sym)} end) |> Enum.sort()
    h = Enum.reduce(canon, h, fn {l, sym}, a -> a |> mix(l) |> mix(sym) end)

    h = mix(h, s1)
    h
  end

  # ---- stream generation: runs of symbols ----
  defp gen_stream(0, s, acc), do: {Enum.reverse(acc) |> List.flatten(), s}

  defp gen_stream(n, s, acc) do
    {si, s1} = rng(s, length(@alphabet))
    sym = Enum.at(@alphabet, si)
    {rl, s2} = rng(s1, 5)
    run = List.duplicate(sym, rl + 1)
    gen_stream(n - 1, s2, [run | acc])
  end

  # ---- RLE ----
  defp rle_encode([]), do: []
  defp rle_encode([x | rest]), do: rle_encode(rest, x, 1, [])
  defp rle_encode([], cur, cnt, acc), do: Enum.reverse([{cur, cnt} | acc])
  defp rle_encode([x | rest], cur, cnt, acc) when x == cur, do: rle_encode(rest, cur, cnt + 1, acc)
  defp rle_encode([x | rest], cur, cnt, acc), do: rle_encode(rest, x, 1, [{cur, cnt} | acc])

  defp rle_decode(rle), do: Enum.flat_map(rle, fn {sym, cnt} -> List.duplicate(sym, cnt) end)

  defp longest_run(rle), do: rle |> Enum.map(fn {_, c} -> c end) |> Enum.max()

  # ---- Huffman tree build: deterministic merge of two lowest-weight nodes ----
  defp build_tree([{_w, node}]), do: node

  defp build_tree(nodes) do
    # sort by (weight, tiebreak) so the merge order is canonical
    sorted = Enum.sort_by(nodes, fn {w, node} -> {w, tie(node)} end)
    [{w1, n1}, {w2, n2} | rest] = sorted
    merged = {w1 + w2, {:node, n1, n2}}
    build_tree([merged | rest])
  end

  defp tie({:leaf, sym}), do: Atom.to_string(sym)
  defp tie({:node, l, _r}), do: tie(l)

  defp tree_weight({:leaf, _}), do: 1
  defp tree_weight({:node, l, r}), do: tree_weight(l) + tree_weight(r)

  defp tree_depth({:leaf, _}), do: 1
  defp tree_depth({:node, l, r}), do: 1 + max(tree_depth(l), tree_depth(r))

  defp leaf_count({:leaf, _}), do: 1
  defp leaf_count({:node, l, r}), do: leaf_count(l) + leaf_count(r)

  defp assign_codes({:leaf, sym}, path, acc) do
    bits = if path == [], do: [0], else: Enum.reverse(path)
    Map.put(acc, sym, bits)
  end

  defp assign_codes({:node, l, r}, path, acc) do
    acc = assign_codes(l, [0 | path], acc)
    assign_codes(r, [1 | path], acc)
  end

  defp bits_to_int(bits), do: Enum.reduce(bits, 0, fn b, acc -> bsl(acc, 1) ||| b end)

  defp bit_width(n) when n <= 1, do: 1
  defp bit_width(n), do: bit_width_loop(n - 1, 0)
  defp bit_width_loop(0, acc), do: max(acc, 1)
  defp bit_width_loop(n, acc), do: bit_width_loop(bsr(n, 1), acc + 1)

  defp popcount(0), do: 0
  defp popcount(n) when n > 0, do: (n &&& 1) + popcount(bsr(n, 1))

  defp prefix_free?(codes) do
    pairs = for a <- codes, b <- codes, a != b, do: {a, b}
    Enum.all?(pairs, fn {a, b} -> not prefix_of?(a, b) end)
  end

  defp prefix_of?([], _), do: true
  defp prefix_of?(_, []), do: false
  defp prefix_of?([x | a], [x | b]), do: prefix_of?(a, b)
  defp prefix_of?(_, _), do: false

  defp bool_int(true), do: 1
  defp bool_int(false), do: 0

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
