# A JSON-like document builder, canonical serializer, validator, and path-query engine — all pure.
# Build random nested documents (maps/lists/ints/bools/strings/null) from the seed, serialize to a
# canonical string with sorted keys (hand-written, NO Jason), compute structural stats (depth, per-type
# node counts), run a tiny path-query engine, and re-fold the serialized form. Deterministic.
defmodule Gap12 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @keys ~w(id name tags meta count active items value label child nodes data flag score)
  @strs ~w(alpha beta gamma delta epsilon zeta eta theta iota kappa)

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    {doc, s1} = gen_value(s0, 4)

    h = 14_695_981

    # serialize to canonical string and fold it
    str = serialize(doc)
    h = h |> mix(byte_size(str)) |> mix(str) |> mix(String.length(str))
    h = mix(h, bsum(str, 23))

    # structural stats
    h = mix(h, depth(doc))
    type_counts = count_types(doc, %{})
    h = fold_map(h, type_counts)
    h = mix(h, total_nodes(doc))

    # leaf integer sum and string-length total (recursive walks)
    h = h |> mix(int_sum(doc)) |> mix(str_len_total(doc))

    # collect all map keys used anywhere, sorted + unique
    all_keys = collect_keys(doc, []) |> Enum.uniq() |> Enum.sort()
    h = mix(h, length(all_keys))
    h = fold_list(h, Enum.map(all_keys, &bsum(&1, 29)))

    # path query engine: gather all root-to-leaf paths and fold path signatures
    paths = leaf_paths(doc, [], [])
    h = mix(h, length(paths))
    h =
      paths
      |> Enum.map(fn {p, v} -> {Enum.reverse(p), v} end)
      |> Enum.sort_by(fn {p, _} -> Enum.map(p, &path_key/1) end)
      |> Enum.reduce(h, fn {p, v}, acc ->
        acc
        |> fold_list(Enum.map(p, &path_key/1))
        |> mix(leaf_sig(v))
      end)

    # query: fetch a few seed-derived paths and fold results
    {queries, s2} = gen_queries(8, s1, [])
    h =
      Enum.reduce(queries, h, fn q, acc ->
        case query(doc, q) do
          {:ok, v} -> acc |> mix(1) |> mix(leaf_sig(v))
          :error -> mix(acc, 0)
        end
      end)

    # round-trip invariant surrogate: re-serialize each leaf path's value, fold lengths
    leaf_str_total =
      paths |> Enum.map(fn {_p, v} -> byte_size(serialize(v)) end) |> Enum.sum()
    h = mix(h, leaf_str_total)

    # build a flat index map: path-string -> leaf signature, fold canonically
    index =
      paths
      |> Enum.map(fn {p, v} -> {path_to_string(Enum.reverse(p)), leaf_sig(v)} end)
      |> Map.new()
    h = fold_map(h, index)

    h = mix(h, s2)
    h
  end

  # ---- random document generation; depth budget bounds recursion ----
  defp gen_value(s, 0), do: gen_scalar(s)
  defp gen_value(s, budget) do
    {kind, s1} = rng(s, 10)
    cond do
      kind < 4 -> gen_scalar(s1)
      kind < 7 -> gen_list(s1, budget)
      true -> gen_object(s1, budget)
    end
  end

  defp gen_scalar(s) do
    {kind, s1} = rng(s, 6)
    case kind do
      0 -> {n, s2} = rng(s1, 1000); {n, s2}
      1 -> {n, s2} = rng(s1, 1000); {-n, s2}
      2 -> {true, s1}
      3 -> {false, s1}
      4 -> {nil, s1}
      5 -> {i, s2} = rng(s1, length(@strs)); {Enum.at(@strs, i), s2}
    end
  end

  defp gen_list(s, budget) do
    {len, s1} = rng(s, 4)
    gen_list_items(len, s1, budget - 1, [])
  end

  defp gen_list_items(0, s, _budget, acc), do: {Enum.reverse(acc), s}
  defp gen_list_items(n, s, budget, acc) do
    {v, s1} = gen_value(s, budget)
    gen_list_items(n - 1, s1, budget, [v | acc])
  end

  defp gen_object(s, budget) do
    {len, s1} = rng(s, 4)
    gen_object_fields(len + 1, s1, budget - 1, %{})
  end

  defp gen_object_fields(0, s, _budget, acc), do: {acc, s}
  defp gen_object_fields(n, s, budget, acc) do
    {ki, s1} = rng(s, length(@keys))
    key = Enum.at(@keys, ki)
    {v, s2} = gen_value(s1, budget)
    gen_object_fields(n - 1, s2, budget, Map.put(acc, key, v))
  end

  # ---- canonical serializer (sorted keys, no whitespace) ----
  defp serialize(nil), do: "null"
  defp serialize(true), do: "true"
  defp serialize(false), do: "false"
  defp serialize(i) when is_integer(i), do: Integer.to_string(i)
  defp serialize(s) when is_binary(s), do: "\"" <> escape(s) <> "\""
  defp serialize(l) when is_list(l) do
    "[" <> (l |> Enum.map(&serialize/1) |> Enum.join(",")) <> "]"
  end
  defp serialize(m) when is_map(m) do
    body =
      m
      |> Map.to_list()
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> "\"" <> escape(k) <> "\":" <> serialize(v) end)
      |> Enum.join(",")
    "{" <> body <> "}"
  end

  defp escape(s), do: s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  # ---- structural stats ----
  defp depth(m) when is_map(m) do
    if map_size(m) == 0, do: 1, else: 1 + (m |> Map.values() |> Enum.map(&depth/1) |> Enum.max())
  end
  defp depth(l) when is_list(l) do
    if l == [], do: 1, else: 1 + (l |> Enum.map(&depth/1) |> Enum.max())
  end
  defp depth(_), do: 1

  defp count_types(v, acc) do
    t = type_of(v)
    acc = Map.update(acc, t, 1, &(&1 + 1))
    cond do
      is_map(v) -> Enum.reduce(Map.values(v), acc, &count_types/2)
      is_list(v) -> Enum.reduce(v, acc, &count_types/2)
      true -> acc
    end
  end

  defp type_of(nil), do: :null
  defp type_of(b) when is_boolean(b), do: :bool
  defp type_of(i) when is_integer(i), do: :int
  defp type_of(s) when is_binary(s), do: :string
  defp type_of(l) when is_list(l), do: :list
  defp type_of(m) when is_map(m), do: :map

  defp total_nodes(v) do
    cond do
      is_map(v) -> 1 + (v |> Map.values() |> Enum.map(&total_nodes/1) |> Enum.sum())
      is_list(v) -> 1 + (v |> Enum.map(&total_nodes/1) |> Enum.sum())
      true -> 1
    end
  end

  defp int_sum(i) when is_integer(i), do: i
  defp int_sum(m) when is_map(m), do: m |> Map.values() |> Enum.map(&int_sum/1) |> Enum.sum()
  defp int_sum(l) when is_list(l), do: l |> Enum.map(&int_sum/1) |> Enum.sum()
  defp int_sum(_), do: 0

  defp str_len_total(s) when is_binary(s), do: String.length(s)
  defp str_len_total(m) when is_map(m), do: m |> Map.values() |> Enum.map(&str_len_total/1) |> Enum.sum()
  defp str_len_total(l) when is_list(l), do: l |> Enum.map(&str_len_total/1) |> Enum.sum()
  defp str_len_total(_), do: 0

  defp collect_keys(m, acc) when is_map(m) do
    keys = Map.keys(m)
    Enum.reduce(Map.values(m), keys ++ acc, &collect_keys/2)
  end
  defp collect_keys(l, acc) when is_list(l), do: Enum.reduce(l, acc, &collect_keys/2)
  defp collect_keys(_, acc), do: acc

  # ---- leaf path enumeration; path elements are {:key, k} or {:idx, i} ----
  defp leaf_paths(m, path, acc) when is_map(m) and map_size(m) > 0 do
    Enum.reduce(m, acc, fn {k, v}, a -> leaf_paths(v, [{:key, k} | path], a) end)
  end
  defp leaf_paths(l, path, acc) when is_list(l) and l != [] do
    l
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {v, i}, a -> leaf_paths(v, [{:idx, i} | path], a) end)
  end
  defp leaf_paths(v, path, acc), do: [{path, v} | acc]

  defp path_key({:key, k}), do: bsum(k, 31)
  defp path_key({:idx, i}), do: 100_000 + i

  defp path_to_string(path) do
    path
    |> Enum.map(fn
      {:key, k} -> "." <> k
      {:idx, i} -> "[" <> Integer.to_string(i) <> "]"
    end)
    |> Enum.join()
  end

  defp leaf_sig(v) when is_integer(v), do: rem(abs(v) * 7 + 1, @cmod)
  defp leaf_sig(v) when is_binary(v), do: bsum(v, 37)
  defp leaf_sig(true), do: 41
  defp leaf_sig(false), do: 43
  defp leaf_sig(nil), do: 47
  defp leaf_sig([]), do: 53
  defp leaf_sig(m) when is_map(m), do: 59 + map_size(m)
  defp leaf_sig(l) when is_list(l), do: 61 + length(l)

  # ---- query engine: follow a path of {:key,k}/{:idx,i} steps ----
  defp gen_queries(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_queries(n, s, acc) do
    {len, s1} = rng(s, 3)
    {q, s2} = gen_path(len + 1, s1, [])
    gen_queries(n - 1, s2, [q | acc])
  end

  defp gen_path(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_path(n, s, acc) do
    {kind, s1} = rng(s, 2)
    {step, s2} =
      if kind == 0 do
        {ki, sx} = rng(s1, length(@keys))
        {{:key, Enum.at(@keys, ki)}, sx}
      else
        {i, sx} = rng(s1, 4)
        {{:idx, i}, sx}
      end
    gen_path(n - 1, s2, [step | acc])
  end

  defp query(v, []), do: {:ok, v}
  defp query(m, [{:key, k} | rest]) when is_map(m) do
    case Map.fetch(m, k) do
      {:ok, v} -> query(v, rest)
      :error -> :error
    end
  end
  defp query(l, [{:idx, i} | rest]) when is_list(l) and i < length(l) do
    query(Enum.at(l, i), rest)
  end
  defp query(_, _), do: :error

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
