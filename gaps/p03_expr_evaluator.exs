# An arithmetic expression evaluator: build random ASTs ({:add,l,r}, {:mul,l,r}, {:num,n}, {:neg,e},
# {:if,c,t,e}, {:sub,...}, {:var,k}) from a seed, evaluate them recursively with bignum arithmetic, then
# compile the same ASTs to a tiny stack machine and interpret that, cross-checking the two results.
# Heavy recursion / pattern matching / guards / tuples / bignum. Pure & deterministic.
defmodule Gap03 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616

  def run(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    {env, s1} = gen_env(s0)
    h = 14_695_981

    {trees, s2} = gen_trees(30 + rem(seed, 20), s1, [])
    h = mix(h, length(trees))

    # evaluate each tree directly (recursive interpreter)
    {h, results} =
      Enum.reduce(trees, {h, []}, fn t, {acc, rs} ->
        v = eval(t, env)
        d = depth(t)
        sz = size(t)
        acc = acc |> mix(v) |> mix(d) |> mix(sz)
        {acc, [v | rs]}
      end)
    results = Enum.reverse(results)

    # compile each to stack-machine ops and run the VM; cross-check vs direct eval
    {h, matches} =
      Enum.reduce(Enum.zip(trees, results), {h, 0}, fn {t, expected}, {acc, m} ->
        ops = compile(t, [])
        acc = mix(acc, length(ops))
        got = vm_run(ops, env, [])
        acc = mix(acc, got)
        # fold whether they agree (they must; this is a self-check folded into the hash)
        same = if got == expected, do: 1, else: 0
        {mix(acc, same), m + same}
      end)
    h = mix(h, matches)

    # aggregate over results: sum, min/max, product mod, parity histogram
    h = mix(h, Enum.sum(results))
    {mn, mx} = Enum.min_max(results)
    h = h |> mix(mn) |> mix(mx)
    prod = Enum.reduce(results, 1, fn v, a -> rem(a * (rem(v, 1_000_003) + 1), @cmod) end)
    h = mix(h, prod)
    parity = Enum.frequencies_by(results, &rem(abs(&1), 2))
    h = fold_map(h, parity)

    # constant folding optimization pass; verify it preserves values
    {h, folded_ok} =
      Enum.reduce(trees, {h, 0}, fn t, {acc, ok} ->
        opt = fold_consts(t)
        before = eval(t, env)
        after_ = eval(opt, env)
        acc = acc |> mix(size(opt)) |> mix(after_)
        {acc, ok + if(before == after_, do: 1, else: 0)}
      end)
    h = mix(h, folded_ok)

    # pretty-print to a string and fold its shape
    printed = trees |> Enum.take(8) |> Enum.map(&pp/1) |> Enum.join(" ;; ")
    h = h |> mix(printed) |> mix(String.length(printed))

    # bignum stress: nested exponentiation-ish tower via repeated squaring of a derived base
    {base, _} = rng(s2, 9_999)
    tower = bigpow(base + 2, 40 + rem(abs(seed), 30))
    h = h |> mix(rem(tower, @cmod)) |> mix(Integer.digits(tower) |> length())
    h = mix(h, Integer.digits(tower) |> Enum.sum())

    # factorial bignum + digit checksum
    f = fact(60 + rem(abs(seed), 15))
    h = h |> mix(rem(f, @cmod)) |> mix(Integer.digits(f) |> Enum.sum())

    # gcd/lcm lattice over the results
    nz = results |> Enum.map(&(abs(&1) + 1)) |> Enum.take(12)
    g = Enum.reduce(nz, fn x, a -> Integer.gcd(x, a) end)
    l = Enum.reduce(nz, 1, fn x, a -> div(a * x, Integer.gcd(a, x)) end)
    h = h |> mix(g) |> mix(rem(l, @cmod))

    h = mix(h, s2)
    h
  end

  # ---- AST generation ----
  defp gen_env(s) do
    {a, s1} = rng(s, 50)
    {b, s2} = rng(s1, 50)
    {c, s3} = rng(s2, 50)
    {%{"x" => a - 25, "y" => b - 25, "z" => c + 1}, s3}
  end

  defp gen_trees(0, s, acc), do: {Enum.reverse(acc), s}
  defp gen_trees(n, s, acc) do
    {t, s1} = gen(s, 4)
    gen_trees(n - 1, s1, [t | acc])
  end

  defp gen(s, 0) do
    {kind, s1} = rng(s, 2)
    if kind == 0 do
      {v, s2} = rng(s1, 200)
      {{:num, v - 100}, s2}
    else
      {k, s2} = rng(s1, 3)
      {{:var, Enum.at(["x", "y", "z"], k)}, s2}
    end
  end

  defp gen(s, depth) do
    {pick, s1} = rng(s, 7)
    case pick do
      0 ->
        {v, s2} = rng(s1, 200)
        {{:num, v - 100}, s2}

      p when p in [1, 2] ->
        {op, s2} = rng(s1, 4)
        {l, s3} = gen(s2, depth - 1)
        {r, s4} = gen(s3, depth - 1)
        tag = Enum.at([:add, :sub, :mul, :max], op)
        {{tag, l, r}, s4}

      3 ->
        {e, s2} = gen(s1, depth - 1)
        {{:neg, e}, s2}

      4 ->
        {c, s2} = gen(s1, depth - 1)
        {t, s3} = gen(s2, depth - 1)
        {e, s4} = gen(s3, depth - 1)
        {{:if, c, t, e}, s4}

      _ ->
        {k, s2} = rng(s1, 3)
        {{:var, Enum.at(["x", "y", "z"], k)}, s2}
    end
  end

  # ---- recursive interpreter ----
  defp eval({:num, n}, _env), do: n
  defp eval({:var, k}, env), do: Map.get(env, k, 0)
  defp eval({:add, l, r}, env), do: eval(l, env) + eval(r, env)
  defp eval({:sub, l, r}, env), do: eval(l, env) - eval(r, env)
  defp eval({:mul, l, r}, env), do: eval(l, env) * eval(r, env)
  defp eval({:max, l, r}, env), do: max(eval(l, env), eval(r, env))
  defp eval({:neg, e}, env), do: -eval(e, env)
  defp eval({:if, c, t, e}, env) do
    if eval(c, env) > 0, do: eval(t, env), else: eval(e, env)
  end

  defp depth({:num, _}), do: 1
  defp depth({:var, _}), do: 1
  defp depth({:neg, e}), do: 1 + depth(e)
  defp depth({:if, c, t, e}), do: 1 + Enum.max([depth(c), depth(t), depth(e)])
  defp depth({_, l, r}), do: 1 + max(depth(l), depth(r))

  defp size({:num, _}), do: 1
  defp size({:var, _}), do: 1
  defp size({:neg, e}), do: 1 + size(e)
  defp size({:if, c, t, e}), do: 1 + size(c) + size(t) + size(e)
  defp size({_, l, r}), do: 1 + size(l) + size(r)

  # ---- constant folding ----
  defp fold_consts({:num, n}), do: {:num, n}
  defp fold_consts({:var, k}), do: {:var, k}
  defp fold_consts({:neg, e}) do
    case fold_consts(e) do
      {:num, n} -> {:num, -n}
      o -> {:neg, o}
    end
  end
  defp fold_consts({:if, c, t, e}) do
    cf = fold_consts(c)
    tf = fold_consts(t)
    ef = fold_consts(e)
    case cf do
      {:num, n} -> if n > 0, do: tf, else: ef
      _ -> {:if, cf, tf, ef}
    end
  end
  defp fold_consts({tag, l, r}) do
    lf = fold_consts(l)
    rf = fold_consts(r)
    case {lf, rf} do
      {{:num, a}, {:num, b}} -> {:num, apply_op(tag, a, b)}
      _ -> {tag, lf, rf}
    end
  end

  defp apply_op(:add, a, b), do: a + b
  defp apply_op(:sub, a, b), do: a - b
  defp apply_op(:mul, a, b), do: a * b
  defp apply_op(:max, a, b), do: max(a, b)

  # ---- stack-machine compiler ----
  # produces a reversed-then-flattened list of ops; we build forward.
  defp compile({:num, n}, acc), do: acc ++ [{:push, n}]
  defp compile({:var, k}, acc), do: acc ++ [{:load, k}]
  defp compile({:neg, e}, acc), do: compile(e, acc) ++ [{:neg}]
  defp compile({:if, c, t, e}, acc) do
    # compile condition, then a self-contained branch op carrying both subprograms
    tp = compile(t, [])
    ep = compile(e, [])
    compile(c, acc) ++ [{:branch, tp, ep}]
  end
  defp compile({tag, l, r}, acc) do
    compile(l, acc) ++ compile(r, []) ++ [{:binop, tag}]
  end

  # ---- stack-machine VM ----
  defp vm_run([], _env, [top | _]), do: top
  defp vm_run([], _env, []), do: 0
  defp vm_run([op | rest], env, stack) do
    stack =
      case op do
        {:push, n} -> [n | stack]
        {:load, k} -> [Map.get(env, k, 0) | stack]
        {:neg} -> [a | s] = stack; [-a | s]
        {:binop, tag} ->
          [b, a | s] = stack
          [apply_op(tag, a, b) | s]
        {:branch, tp, ep} ->
          [c | s] = stack
          v = if c > 0, do: vm_run(tp, env, []), else: vm_run(ep, env, [])
          [v | s]
      end
    vm_run(rest, env, stack)
  end

  # ---- pretty printer ----
  defp pp({:num, n}), do: Integer.to_string(n)
  defp pp({:var, k}), do: k
  defp pp({:neg, e}), do: "(-" <> pp(e) <> ")"
  defp pp({:if, c, t, e}), do: "(if " <> pp(c) <> " " <> pp(t) <> " " <> pp(e) <> ")"
  defp pp({tag, l, r}), do: "(" <> Atom.to_string(tag) <> " " <> pp(l) <> " " <> pp(r) <> ")"

  # ---- bignum helpers ----
  defp bigpow(_b, 0), do: 1
  defp bigpow(b, e) when rem(e, 2) == 0 do
    half = bigpow(b, div(e, 2))
    half * half
  end
  defp bigpow(b, e), do: b * bigpow(b, e - 1)

  defp fact(0), do: 1
  defp fact(n), do: n * fact(n - 1)

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
