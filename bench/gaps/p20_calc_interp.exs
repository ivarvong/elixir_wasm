# extra: Enum Map List
# A recursive-descent expression interpreter. We synthesize arithmetic expression STRINGS from a seed
# (with +,-,*,/, parens, unary minus, and let-bindings/variables), tokenize them char-by-char over the
# raw binary (our OWN lexer — no String.split / no Regex), parse to an AST with a recursive-descent
# parser honoring precedence, and evaluate against an environment map (integer/bignum arithmetic with
# floored division). Every result and intermediate folds into a rolling checksum. Pure & deterministic.
defmodule Gap20 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @vars ["x", "y", "z", "n", "k"]

  def run(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    h = 14_695_981

    # Generate, lex, parse, and evaluate many expressions.
    {h, _s} =
      Enum.reduce(1..(30 + rem(abs(seed), 12)), {h, s0}, fn _, {a, s} ->
        {src, s1} = gen_expr_str(s)
        a = a |> mix(byte_size(src)) |> mix(src)

        toks = lex(src)
        a = mix(a, length(toks))
        a = fold_list(a, Enum.map(toks, &tok_int/1))

        {env, s2} = gen_env(s1)
        a = fold_map(a, env)

        {ast, _rest} = parse_expr(toks)
        a = mix(a, ast_size(ast))
        a = mix(a, ast_depth(ast))

        val = eval(ast, env)
        a = mix(a, val)
        {a, s2}
      end)

    # A few hand-built fixed programs with let-bindings to exercise the env + precedence directly.
    fixed = [
      "let x = 3 in x * x + 1",
      "1 + 2 * 3 - 4 / 2",
      "- (5 + 6) * 2",
      "let y = 10 in let z = y - 3 in y * z + y",
      "((1 + 2) * (3 + 4)) - 5",
      "let n = 7 in n * n * n - n",
      "100 / 7 + 100 / 6 - 3 * 9",
      "let k = 2 in let x = k * k in let y = x * x in x + y - k"
    ]

    h =
      Enum.reduce(fixed, h, fn src, a ->
        toks = lex(src)
        {ast, _} = parse_expr(toks)
        v = eval(ast, %{})
        a |> mix(src) |> mix(length(toks)) |> mix(ast_size(ast)) |> mix(v)
      end)

    # Evaluate a fixed expression over a sweep of environment values (bignum growth via repeated *).
    h =
      Enum.reduce(1..25, h, fn i, a ->
        toks = lex("x * x * x + x * 2 - 1")
        {ast, _} = parse_expr(toks)
        v = eval(ast, %{"x" => i * 37 - 11})
        mix(a, v)
      end)

    # S-expression style: build nested ((op a b)) trees directly and evaluate (no string), comparing
    # to the infix evaluator on equivalent structure.
    h =
      Enum.reduce(1..20, h, fn i, a ->
        ast = build_balanced(i, 3)
        mix(a, eval(ast, %{}))
      end)

    h |> mix(s0)
  end

  # ---- expression string generation ----
  defp gen_expr_str(s) do
    {depth, s1} = rng(s, 4)
    gen_e(s1, depth + 1)
  end

  # produce {string, state}
  defp gen_e(s, 0) do
    {leaf, s1} = rng(s, 3)

    case leaf do
      0 ->
        {n, s2} = rng(s1, 50)
        {Integer.to_string(n + 1), s2}

      1 ->
        {vi, s2} = rng(s1, length(@vars))
        {Enum.at(@vars, vi), s2}

      _ ->
        {n, s2} = rng(s1, 9)
        {"(" <> Integer.to_string(n + 1) <> ")", s2}
    end
  end

  defp gen_e(s, depth) do
    {form, s1} = rng(s, 6)

    case form do
      0 ->
        # unary minus
        {sub, s2} = gen_e(s1, depth - 1)
        {"- " <> wrap(sub), s2}

      f when f in [1, 2, 3, 4] ->
        op = Enum.at(["+", "-", "*", "/"], f - 1)
        {l, s2} = gen_e(s1, depth - 1)
        {r, s3} = gen_e(s2, depth - 1)
        {"(" <> l <> " " <> op <> " " <> r <> ")", s3}

      _ ->
        # let-binding
        {vi, s2} = rng(s1, length(@vars))
        v = Enum.at(@vars, vi)
        {val, s3} = gen_e(s2, depth - 1)
        {body, s4} = gen_e(s3, depth - 1)
        {"let " <> v <> " = " <> val <> " in " <> body, s4}
    end
  end

  defp wrap(s), do: "(" <> s <> ")"

  defp gen_env(s) do
    Enum.reduce(@vars, {%{}, s}, fn v, {m, st} ->
      {n, st1} = rng(st, 40)
      {Map.put(m, v, n - 20), st1}
    end)
  end

  # ---- lexer: char-by-char over the raw binary ----
  # Tokens: {:num, int} | {:var, string} | {:op, ?+|?-|?*|?/} | {:lparen} | {:rparen}
  #         | {:let} | {:eq} | {:in}
  defp lex(bin), do: lex(bin, [])

  defp lex(<<>>, acc), do: Enum.reverse(acc)

  defp lex(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n], do: lex(rest, acc)
  defp lex(<<?(, rest::binary>>, acc), do: lex(rest, [{:lparen} | acc])
  defp lex(<<?), rest::binary>>, acc), do: lex(rest, [{:rparen} | acc])
  defp lex(<<?+, rest::binary>>, acc), do: lex(rest, [{:op, ?+} | acc])
  defp lex(<<?-, rest::binary>>, acc), do: lex(rest, [{:op, ?-} | acc])
  defp lex(<<?*, rest::binary>>, acc), do: lex(rest, [{:op, ?*} | acc])
  defp lex(<<?/, rest::binary>>, acc), do: lex(rest, [{:op, ?/} | acc])
  defp lex(<<?=, rest::binary>>, acc), do: lex(rest, [{:eq} | acc])

  defp lex(<<c, _::binary>> = bin, acc) when c >= ?0 and c <= ?9 do
    {n, rest} = lex_num(bin, 0)
    lex(rest, [{:num, n} | acc])
  end

  defp lex(<<c, _::binary>> = bin, acc) when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) do
    {word, rest} = lex_word(bin, [])

    tok =
      case word do
        "let" -> {:let}
        "in" -> {:in}
        other -> {:var, other}
      end

    lex(rest, [tok | acc])
  end

  defp lex_num(<<c, rest::binary>>, acc) when c >= ?0 and c <= ?9,
    do: lex_num(rest, acc * 10 + (c - ?0))

  defp lex_num(bin, acc), do: {acc, bin}

  defp lex_word(<<c, rest::binary>>, acc)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9),
       do: lex_word(rest, [c | acc])

  defp lex_word(bin, acc), do: {acc |> Enum.reverse() |> List.to_string(), bin}

  defp tok_int({:num, n}), do: n
  defp tok_int({:op, c}), do: c
  defp tok_int({:var, w}), do: bsum(w, 3)
  defp tok_int({:lparen}), do: 901
  defp tok_int({:rparen}), do: 902
  defp tok_int({:let}), do: 903
  defp tok_int({:in}), do: 904
  defp tok_int({:eq}), do: 905

  # ---- recursive-descent parser ----
  # expr   := let | add
  # let    := 'let' var '=' expr 'in' expr
  # add    := mul (('+'|'-') mul)*
  # mul    := unary (('*'|'/') unary)*
  # unary  := '-' unary | primary
  # primary:= num | var | '(' expr ')'
  defp parse_expr([{:let}, {:var, v}, {:eq} | rest]) do
    {val_ast, rest1} = parse_expr(rest)

    rest2 =
      case rest1 do
        [{:in} | r] -> r
        r -> r
      end

    {body_ast, rest3} = parse_expr(rest2)
    {{:let, v, val_ast, body_ast}, rest3}
  end

  defp parse_expr(toks), do: parse_add(toks)

  defp parse_add(toks) do
    {left, rest} = parse_mul(toks)
    parse_add_loop(left, rest)
  end

  defp parse_add_loop(left, [{:op, op} | rest]) when op in [?+, ?-] do
    {right, rest1} = parse_mul(rest)
    parse_add_loop({:bin, op, left, right}, rest1)
  end

  defp parse_add_loop(left, rest), do: {left, rest}

  defp parse_mul(toks) do
    {left, rest} = parse_unary(toks)
    parse_mul_loop(left, rest)
  end

  defp parse_mul_loop(left, [{:op, op} | rest]) when op in [?*, ?/] do
    {right, rest1} = parse_unary(rest)
    parse_mul_loop({:bin, op, left, right}, rest1)
  end

  defp parse_mul_loop(left, rest), do: {left, rest}

  defp parse_unary([{:op, ?-} | rest]) do
    {operand, rest1} = parse_unary(rest)
    {{:neg, operand}, rest1}
  end

  defp parse_unary(toks), do: parse_primary(toks)

  defp parse_primary([{:num, n} | rest]), do: {{:num, n}, rest}
  defp parse_primary([{:var, v} | rest]), do: {{:var, v}, rest}

  defp parse_primary([{:lparen} | rest]) do
    {inner, rest1} = parse_expr(rest)

    rest2 =
      case rest1 do
        [{:rparen} | r] -> r
        r -> r
      end

    {inner, rest2}
  end

  # fallback: treat as zero literal (keeps total function)
  defp parse_primary(rest), do: {{:num, 0}, rest}

  # ---- evaluator ----
  defp eval({:num, n}, _env), do: n
  defp eval({:var, v}, env), do: Map.get(env, v, 0)
  defp eval({:neg, e}, env), do: -eval(e, env)

  defp eval({:let, v, val, body}, env) do
    x = eval(val, env)
    eval(body, Map.put(env, v, x))
  end

  defp eval({:bin, ?+, l, r}, env), do: eval(l, env) + eval(r, env)
  defp eval({:bin, ?-, l, r}, env), do: eval(l, env) - eval(r, env)
  defp eval({:bin, ?*, l, r}, env), do: eval(l, env) * eval(r, env)

  defp eval({:bin, ?/, l, r}, env) do
    d = eval(r, env)
    if d == 0, do: 0, else: floor_div(eval(l, env), d)
  end

  defp floor_div(a, b) do
    q = div(a, b)
    if rem(a, b) != 0 and (a < 0) != (b < 0), do: q - 1, else: q
  end

  # ---- AST metrics ----
  defp ast_size({:num, _}), do: 1
  defp ast_size({:var, _}), do: 1
  defp ast_size({:neg, e}), do: 1 + ast_size(e)
  defp ast_size({:let, _, v, b}), do: 1 + ast_size(v) + ast_size(b)
  defp ast_size({:bin, _, l, r}), do: 1 + ast_size(l) + ast_size(r)

  defp ast_depth({:num, _}), do: 1
  defp ast_depth({:var, _}), do: 1
  defp ast_depth({:neg, e}), do: 1 + ast_depth(e)
  defp ast_depth({:let, _, v, b}), do: 1 + max(ast_depth(v), ast_depth(b))
  defp ast_depth({:bin, _, l, r}), do: 1 + max(ast_depth(l), ast_depth(r))

  # ---- balanced tree builder (S-expression-ish) ----
  defp build_balanced(seed, 0), do: {:num, rem(seed, 9) + 1}

  defp build_balanced(seed, depth) do
    op = Enum.at([?+, ?-, ?*, ?/], rem(seed, 4))
    l = build_balanced(seed * 2 + 1, depth - 1)
    r = build_balanced(seed * 2 + 2, depth - 1)
    {:bin, op, l, r}
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
