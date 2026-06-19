# extra: Enum List Integer
# A small linear-algebra library over integer matrices represented as lists of lists. Matrices are
# synthesized from the seed, then we exercise multiply, transpose, add, scalar-multiply, identity,
# matrix power (repeated multiply — bignum-producing), determinant (recursive cofactor expansion) and
# trace. Every result is folded into a rolling checksum, so any miscompiled stdlib/arith changes the
# output. Pure & deterministic.
defmodule Gap06 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    h = 14_695_981

    # build a square matrix A (n x n) and a rectangular B (n x p)
    {n, s1} = rng(s0, 3)
    n = n + 3
    {p, s2} = rng(s1, 3)
    p = p + 2
    {a, s3} = gen_matrix(n, n, 9, s2)
    {b, s4} = gen_matrix(n, p, 7, s3)
    {c, s5} = gen_matrix(p, n, 5, s4)

    h = h |> mix(n) |> mix(p)
    h = fold_matrix(h, a)
    h = fold_matrix(h, b)
    h = fold_matrix(h, c)

    # transpose round-trips
    at = transpose(a)
    h = fold_matrix(h, at)
    h = mix(h, bool_int(transpose(at) == a))

    # element-wise add (A + A) and scalar multiply
    a2 = add(a, a)
    a3 = scalar_mul(a, 3)
    h = fold_matrix(h, a2)
    h = fold_matrix(h, a3)
    h = mix(h, bool_int(add(a, scalar_mul(a, 2)) == a3))

    # multiply A*B (n x p) and B-times-C dimension chain
    ab = mul(a, b)
    h = h |> mix(rows(ab)) |> mix(cols(ab)) |> fold_matrix(ab)
    bc = mul(b, c)
    h = fold_matrix(h, bc)
    # associativity surrogate: (A*B)*C vs A*(B*C)
    abc1 = mul(ab, c)
    abc2 = mul(a, bc)
    h = mix(h, bool_int(abc1 == abc2))
    h = fold_matrix(h, abc1)

    # identity and the property A*I == A
    id = identity(n)
    h = fold_matrix(h, id)
    h = mix(h, bool_int(mul(a, id) == a))
    h = mix(h, bool_int(mul(id, a) == a))

    # trace and diagonal
    h = mix(h, trace(a))
    h = fold_list(h, diagonal(a))

    # matrix powers — these blow up into bignums
    a_pow = power(a, 5)
    h = fold_matrix(h, a_pow)
    h = mix(h, trace(a_pow))
    big = power(a, 8)
    h = mix(h, big |> List.flatten() |> Enum.sum())
    h = mix(h, big |> List.flatten() |> Enum.map(&abs/1) |> Enum.max())
    h = mix(h, bool_int(mul(power(a, 3), power(a, 2)) == a_pow))

    # determinants of several leading principal minors (recursive cofactor expansion)
    dets = for k <- 1..n, do: det(leading_minor(a, k))
    h = fold_list(h, dets)
    h = mix(h, det(a))
    h = mix(h, det(at))
    h = mix(h, bool_int(det(a) == det(at)))
    # det of a 2x scaled matrix scales by 2^n
    h = mix(h, det(scalar_mul(a, 2)))

    # cofactor / adjugate-ish: sum of all first-row cofactors
    cof_sum = (0..(n - 1)) |> Enum.map(fn j -> cofactor(a, 0, j) end) |> Enum.sum()
    h = mix(h, cof_sum)

    # row/column reductions
    row_sums = Enum.map(a, &Enum.sum/1)
    col_sums = Enum.map(transpose(a), &Enum.sum/1)
    h = fold_list(h, row_sums)
    h = fold_list(h, col_sums)
    h = mix(h, Enum.sum(row_sums))
    h = mix(h, bool_int(Enum.sum(row_sums) == Enum.sum(col_sums)))

    # Hadamard (element-wise) product and Frobenius-ish norm (sum of squares)
    had = hadamard(a, a)
    h = fold_matrix(h, had)
    frob = had |> List.flatten() |> Enum.sum()
    h = mix(h, frob)

    # min/max element and flattened sort
    flat = List.flatten(a)
    {mn, mx} = Enum.min_max(flat)
    h = h |> mix(mn) |> mix(mx)
    h = fold_list(h, Enum.sort(flat))

    h = mix(h, s5)
    h
  end

  # ---- matrix generation ----
  defp gen_matrix(rows, cols, m, s) do
    Enum.reduce(1..rows, {[], s}, fn _, {racc, sa} ->
      {row, sb} =
        Enum.reduce(1..cols, {[], sa}, fn _, {cacc, sc} ->
          {v, sd} = rng(sc, m)
          {sign, se} = rng(sd, 2)
          v = if sign == 0, do: v, else: -v
          {[v | cacc], se}
        end)

      {[Enum.reverse(row) | racc], sb}
    end)
    |> then(fn {rs, sf} -> {Enum.reverse(rs), sf} end)
  end

  defp rows(m), do: length(m)
  defp cols([]), do: 0
  defp cols([r | _]), do: length(r)

  defp transpose([[] | _]), do: []
  defp transpose([]), do: []
  defp transpose(m), do: m |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

  defp add(a, b), do: Enum.zip(a, b) |> Enum.map(fn {ra, rb} -> Enum.zip(ra, rb) |> Enum.map(fn {x, y} -> x + y end) end)

  defp hadamard(a, b),
    do: Enum.zip(a, b) |> Enum.map(fn {ra, rb} -> Enum.zip(ra, rb) |> Enum.map(fn {x, y} -> x * y end) end)

  defp scalar_mul(a, k), do: Enum.map(a, fn row -> Enum.map(row, &(&1 * k)) end)

  defp mul(a, b) do
    bt = transpose(b)
    Enum.map(a, fn row ->
      Enum.map(bt, fn col ->
        Enum.zip(row, col) |> Enum.reduce(0, fn {x, y}, acc -> acc + x * y end)
      end)
    end)
  end

  defp identity(n) do
    for i <- 0..(n - 1), do: for(j <- 0..(n - 1), do: if(i == j, do: 1, else: 0))
  end

  defp power(a, 1), do: a
  defp power(a, k) when k > 1, do: mul(a, power(a, k - 1))

  defp trace(a) do
    a |> Enum.with_index() |> Enum.reduce(0, fn {row, i}, acc -> acc + Enum.at(row, i) end)
  end

  defp diagonal(a), do: a |> Enum.with_index() |> Enum.map(fn {row, i} -> Enum.at(row, i) end)

  defp leading_minor(a, k), do: a |> Enum.take(k) |> Enum.map(&Enum.take(&1, k))

  # recursive determinant via cofactor expansion along the first row
  defp det([[x]]), do: x
  defp det([[a, b], [c, d]]), do: a * d - b * c

  defp det(m) do
    [first | _] = m
    first
    |> Enum.with_index()
    |> Enum.reduce(0, fn {x, j}, acc ->
      sign = if rem(j, 2) == 0, do: 1, else: -1
      acc + sign * x * det(minor(m, 0, j))
    end)
  end

  defp cofactor(m, i, j) do
    sign = if rem(i + j, 2) == 0, do: 1, else: -1
    sign * det(minor(m, i, j))
  end

  defp minor(m, i, j) do
    m
    |> List.delete_at(i)
    |> Enum.map(&List.delete_at(&1, j))
  end

  defp fold_matrix(h, m), do: Enum.reduce(m, h, fn row, a -> fold_list(a, row) end)
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
