# extra: Integer
# A hand-rolled regular-expression / glob matcher (NO Regex module): a tiny pattern language (literals,
# '.', '*', '+', '?', char classes '[...]', anchors '^' '$') is parsed into an AST, then matched against
# seed-generated strings by recursive backtracking. Also a glob matcher ('*' '?' '[..]') and a wildcard
# search over a generated word list. Heavy recursion, charlist/binary matching, pattern matching, Enum.
defmodule Gap17 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @alpha ~c"abcde"
  @patterns ["a.c", "ab*c", "a+b", "colou?r", "[abc]+", "^ab", "c$", "a.*z", "[a-c]d", ".*", "a?b?c?", "ab+a*c"]
  @globs ["a*c", "?b?", "[ab]*", "a?c*", "*z", "ab*", "[a-c]*d"]

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    h = 14_695_981
    h = mix(h, s0)

    # ---- generate a corpus of strings ----
    {words, s1} = gen_words(60, s0, [])
    h = mix(h, length(words))
    h = fold_list(h, words)
    h = mix(h, words |> Enum.map(&String.length/1) |> Enum.sum())

    # ---- parse each pattern into an AST and fold its structure ----
    asts = Enum.map(@patterns, &parse/1)
    h = Enum.reduce(asts, h, fn ast, acc -> mix(acc, ast_sig(ast, 0)) end)

    # ---- regex match every pattern against every word ----
    h =
      Enum.reduce(asts, h, fn ast, acc ->
        matches =
          words
          |> Enum.with_index()
          |> Enum.filter(fn {w, _i} -> regex_match?(ast, w) end)
          |> Enum.map(fn {_w, i} -> i end)
        acc |> mix(length(matches)) |> fold_list(matches)
      end)

    # ---- count total (pattern,word) matches and a per-pattern histogram ----
    hist =
      Enum.reduce(@patterns, %{}, fn p, m ->
        ast = parse(p)
        c = Enum.count(words, fn w -> regex_match?(ast, w) end)
        Map.put(m, p, c)
      end)
    h = fold_map(h, hist)
    h = mix(h, hist |> Map.values() |> Enum.sum())

    # ---- glob matching ----
    h =
      Enum.reduce(@globs, h, fn g, acc ->
        gl = String.to_charlist(g)
        matched =
          words
          |> Enum.filter(fn w -> glob_match?(gl, String.to_charlist(w)) end)
          |> Enum.sort()
        acc |> mix(g) |> mix(length(matched)) |> fold_list(matched)
      end)

    # ---- wildcard search: find words containing a generated sub-pattern ----
    {needles, s2} = gen_words(8, s1, [])
    h =
      Enum.reduce(needles, h, fn ndl, acc ->
        np = "a*" <> ndl <> "*"
        ast = parse(np)
        hits = Enum.count(words, fn w -> regex_match?(ast, w) end)
        gl = String.to_charlist("*" <> ndl <> "*")
        ghits = Enum.count(words, fn w -> glob_match?(gl, String.to_charlist(w)) end)
        acc |> mix(ndl) |> mix(hits) |> mix(ghits)
      end)

    # ---- anchored full-match vs unanchored search distinction ----
    {h, _} =
      Enum.reduce(["abc", "aXc", "abbbc", "xyz"], {h, s2}, fn lit, {acc, ss} ->
        ast = parse("a.*c")
        full = regex_match?(parse("^" <> "a.*c" <> "$"), lit)
        srch = regex_match?(ast, lit)
        acc = acc |> mix(lit) |> mix(bool_int(full)) |> mix(bool_int(srch))
        {acc, ss}
      end)

    # ---- character class membership stress over the alphabet ----
    cls = parse("[a-c]")
    h =
      Enum.reduce(?a..?z, h, fn ch, acc ->
        mix(acc, bool_int(regex_match?(cls, <<ch>>)))
      end)

    # ---- repetition counting: how many words have 3+ of the same run ----
    runs = words |> Enum.map(&max_run/1)
    h = fold_list(h, runs)
    h = mix(h, Enum.max(runs))

    # ---- longest-match length per word for a greedy pattern ----
    greedy = parse(".*b")
    lens =
      Enum.map(words, fn w ->
        if regex_match?(greedy, w), do: String.length(w), else: 0
      end)
    h = fold_list(h, lens)
    h
  end

  # ---- pattern parser -> token list with quantifiers ----
  # AST node forms:
  #   {:char, c} {:dot} {:class, ranges, negate?} {:anchor_start} {:anchor_end}
  #   {:star, node} {:plus, node} {:opt, node}
  defp parse(str) do
    chars = String.to_charlist(str)
    {anchored_start, chars} =
      case chars do
        [?^ | rest] -> {true, rest}
        _ -> {false, chars}
      end
    {nodes, anchored_end} = parse_seq(chars, [])
    nodes = if anchored_start, do: [{:anchor_start} | nodes], else: nodes
    nodes = if anchored_end, do: nodes ++ [{:anchor_end}], else: nodes
    nodes
  end

  defp parse_seq([], acc), do: {Enum.reverse(acc), false}
  defp parse_seq([?$], acc), do: {Enum.reverse(acc), true}
  defp parse_seq([c | rest], acc) do
    {atom, rest2} = parse_atom(c, rest)
    {atom, rest3} = apply_quant(atom, rest2)
    parse_seq(rest3, [atom | acc])
  end

  defp parse_atom(?., rest), do: {{:dot}, rest}
  defp parse_atom(?[, rest) do
    {neg, rest} =
      case rest do
        [?^ | r] -> {true, r}
        _ -> {false, rest}
      end
    {ranges, rest2} = parse_class(rest, [])
    {{:class, ranges, neg}, rest2}
  end
  defp parse_atom(c, rest), do: {{:char, c}, rest}

  defp parse_class([?] | rest], acc), do: {Enum.reverse(acc), rest}
  defp parse_class([a, ?-, b | rest], acc) when b != ?], do: parse_class(rest, [{a, b} | acc])
  defp parse_class([c | rest], acc), do: parse_class(rest, [{c, c} | acc])
  defp parse_class([], acc), do: {Enum.reverse(acc), []}

  defp apply_quant(atom, [?* | rest]), do: {{:star, atom}, rest}
  defp apply_quant(atom, [?+ | rest]), do: {{:plus, atom}, rest}
  defp apply_quant(atom, [?? | rest]), do: {{:opt, atom}, rest}
  defp apply_quant(atom, rest), do: {atom, rest}

  # ---- matcher: try at each start position unless anchored ----
  defp regex_match?(nodes, str) do
    cs = String.to_charlist(str)
    case nodes do
      [{:anchor_start} | rest] -> match_here(rest, cs)
      _ -> try_positions(nodes, cs)
    end
  end

  defp try_positions(nodes, cs) do
    if match_here(nodes, cs) do
      true
    else
      case cs do
        [] -> false
        [_ | t] -> try_positions(nodes, t)
      end
    end
  end

  defp match_here([], _cs), do: true
  defp match_here([{:anchor_end}], cs), do: cs == []
  defp match_here([{:star, node} | rest], cs), do: match_star(node, rest, cs)
  defp match_here([{:plus, node} | rest], cs) do
    case match_one(node, cs) do
      {:ok, rem} -> match_star(node, rest, rem)
      :no -> false
    end
  end
  defp match_here([{:opt, node} | rest], cs) do
    case match_one(node, cs) do
      {:ok, rem} -> match_here(rest, rem) or match_here(rest, cs)
      :no -> match_here(rest, cs)
    end
  end
  defp match_here([node | rest], cs) do
    case match_one(node, cs) do
      {:ok, rem} -> match_here(rest, rem)
      :no -> false
    end
  end

  # greedy star with backtracking
  defp match_star(node, rest, cs) do
    expansions = collect_star(node, cs, [cs])
    Enum.any?(expansions, fn rem -> match_here(rest, rem) end)
  end
  defp collect_star(node, cs, acc) do
    case match_one(node, cs) do
      {:ok, rem} when rem != cs -> collect_star(node, rem, [rem | acc])
      _ -> acc
    end
  end

  defp match_one({:char, c}, [c | t]), do: {:ok, t}
  defp match_one({:char, _}, _), do: :no
  defp match_one({:dot}, [_ | t]), do: {:ok, t}
  defp match_one({:dot}, []), do: :no
  defp match_one({:class, ranges, neg}, [c | t]) do
    inside = Enum.any?(ranges, fn {a, b} -> c >= a and c <= b end)
    if inside != neg, do: {:ok, t}, else: :no
  end
  defp match_one({:class, _, _}, []), do: :no

  # ---- glob matcher (charlists): '*' any run, '?' one, '[..]' class ----
  defp glob_match?([], []), do: true
  defp glob_match?([?* | p], cs) do
    glob_match?(p, cs) or (cs != [] and glob_match?([?* | p], tl(cs)))
  end
  defp glob_match?([?? | p], [_ | cs]), do: glob_match?(p, cs)
  defp glob_match?([?[ | p], [c | cs]) do
    {ranges, rest} = parse_glob_class(p, [])
    if Enum.any?(ranges, fn {a, b} -> c >= a and c <= b end) do
      glob_match?(rest, cs)
    else
      false
    end
  end
  defp glob_match?([c | p], [c | cs]), do: glob_match?(p, cs)
  defp glob_match?(_, _), do: false

  defp parse_glob_class([?] | rest], acc), do: {Enum.reverse(acc), rest}
  defp parse_glob_class([a, ?-, b | rest], acc) when b != ?], do: parse_glob_class(rest, [{a, b} | acc])
  defp parse_glob_class([c | rest], acc), do: parse_glob_class(rest, [{c, c} | acc])
  defp parse_glob_class([], acc), do: {Enum.reverse(acc), []}

  # ---- AST signature for folding pattern structure ----
  defp ast_sig(nodes, h0) when is_list(nodes) do
    Enum.reduce(nodes, h0, fn n, a -> ast_sig(n, a) end)
  end
  defp ast_sig({:char, c}, h), do: mix(h, c)
  defp ast_sig({:dot}, h), do: mix(h, 1001)
  defp ast_sig({:anchor_start}, h), do: mix(h, 1002)
  defp ast_sig({:anchor_end}, h), do: mix(h, 1003)
  defp ast_sig({:class, ranges, neg}, h) do
    h = mix(h, bool_int(neg))
    Enum.reduce(ranges, h, fn {a, b}, acc -> acc |> mix(a) |> mix(b) end)
  end
  defp ast_sig({:star, n}, h), do: ast_sig(n, mix(h, 2001))
  defp ast_sig({:plus, n}, h), do: ast_sig(n, mix(h, 2002))
  defp ast_sig({:opt, n}, h), do: ast_sig(n, mix(h, 2003))

  defp max_run(w) do
    case String.to_charlist(w) do
      [] -> 0
      [first | rest] -> mr(rest, first, 1, 1)
    end
  end
  defp mr([], _prev, cur, best), do: max(cur, best)
  defp mr([c | t], c, cur, best), do: mr(t, c, cur + 1, best)
  defp mr([c | t], _prev, cur, best), do: mr(t, c, 1, max(cur, best))

  defp gen_words(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_words(k, s, acc) do
    {len, s1} = rng(s, 6)
    {w, s2} = gen_chars(len + 1, s1, [])
    gen_words(k - 1, s2, [List.to_string(w) | acc])
  end
  defp gen_chars(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_chars(k, s, acc) do
    {i, s1} = rng(s, length(@alpha))
    gen_chars(k - 1, s1, [Enum.at(@alpha, i) | acc])
  end

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
