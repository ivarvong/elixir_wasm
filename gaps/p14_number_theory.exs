# extra: Integer Bitwise
# A big-integer number-theory / crypto-ish toolkit: modular exponentiation by repeated squaring,
# deterministic Miller-Rabin primality (fixed witnesses), gcd / extended-gcd, modular inverse, a tiny
# RSA-style encrypt/decrypt round-trip, true-bignum Fibonacci & factorial, and base conversion. Every
# meaningful intermediate is folded into a rolling checksum. Pure, deterministic, arbitrary precision.
defmodule Gap14 do
  import Bitwise
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    h = 14_695_981
    h = mix(h, s0)

    # ---- modular exponentiation: a^e mod m on seed-derived operands ----
    {a, s1} = rng(s0, 1_000_000)
    {e, s2} = rng(s1, 5000)
    {m, s3} = rng(s2, 999_983)
    a = a + 2
    e = e + 7
    m = m + 101
    pe = mod_pow(a, e, m)
    h = h |> mix(a) |> mix(e) |> mix(m) |> mix(pe)
    # repeated squaring with a large modulus that forces bignum intermediates
    bigm = 1_000_000_000_000_000_003
    pe2 = mod_pow(a + 1_000_000, e + 99, bigm)
    h = mix(h, pe2)

    # ---- gcd / extended-gcd / modular inverse ----
    {x0, s4} = rng(s3, 500_000)
    {y0, s5} = rng(s4, 500_000)
    x = x0 + 3
    y = y0 + 5
    g = gcd(x, y)
    {gg, u, v} = ext_gcd(x, y)
    h = h |> mix(x) |> mix(y) |> mix(g) |> mix(gg) |> mix(u) |> mix(v)
    # verify Bezout identity numerically and fold it
    h = mix(h, u * x + v * y)
    # modular inverse where coprime
    {im, s6} = rng(s5, 9973)
    im = im + 257
    inv = mod_inverse(x, im)
    h = mix(h, inv)
    h = if inv != nil, do: mix(h, rem(x * inv, im)), else: mix(h, 0)

    # ---- deterministic Miller-Rabin primality over a seed-derived window ----
    {base, s7} = rng(s6, 100_000)
    base = base + 1000
    cands = base..(base + 60)
    primes = cands |> Enum.filter(&is_prime?/1)
    h = mix(h, length(primes))
    h = fold_list(h, primes)
    # sum and product (product is a bignum) of the found primes
    psum = Enum.sum(primes)
    pprod = Enum.reduce(primes, 1, &(&1 * &2))
    h = h |> mix(psum) |> mix(pprod)
    # a handful of known large primes / composites stressed deterministically
    knowns = [2_147_483_647, 999_999_937, 1_000_000_007, 1_000_000_009, 1_000_003, 1_000_004]
    h = Enum.reduce(knowns, h, fn n, acc -> mix(acc, bool_int(is_prime?(n))) end)

    # ---- tiny RSA-style round-trip on seed-derived small messages ----
    p = next_prime(base + 7)
    q = next_prime(base + 137)
    n = p * q
    phi = (p - 1) * (q - 1)
    enc = pick_e(phi, 3)
    d = mod_inverse(enc, phi)
    h = h |> mix(p) |> mix(q) |> mix(n) |> mix(phi) |> mix(enc)
    h = if d != nil, do: mix(h, d), else: mix(h, -1)
    {msgs, _s8} = gen_msgs(8, s7, n, [])
    h = fold_list(h, msgs)
    {h, ok} =
      Enum.reduce(msgs, {h, 0}, fn msg, {acc, good} ->
        c = mod_pow(msg, enc, n)
        back = if d != nil, do: mod_pow(c, d, n), else: -1
        acc = acc |> mix(c) |> mix(back)
        {acc, good + bool_int(back == msg)}
      end)
    h = mix(h, ok)

    # ---- true bignum Fibonacci & factorial ----
    {fi, _} = rng(s7, 80)
    fi = fi + 90
    fib = fib(fi)
    h = h |> mix(fi) |> mix(fib) |> mix(num_digits(fib))
    fl = 40 + rem(fi, 30)
    fact = factorial(fl)
    h = h |> mix(fl) |> mix(fact) |> mix(num_digits(fact))
    # trailing-zero count of factorial (Legendre) as a sanity fold
    h = mix(h, trailing_zeros_fact(fl))

    # ---- base conversion round-trips ----
    {bn, _s9} = rng(s7, 9_000_000)
    bn = bn + 123_456
    h =
      Enum.reduce([2, 3, 7, 16, 36], h, fn radix, acc ->
        digits = to_base(bn, radix)
        back = from_base(digits, radix)
        acc = acc |> mix(radix) |> mix(length(digits)) |> fold_list(digits) |> mix(back)
        mix(acc, bool_int(back == bn))
      end)

    # ---- bitwise odds and ends on bignums ----
    big = fib + fact
    h =
      h
      |> mix(band(big, 0xFFFFFF))
      |> mix(bor(big, 0xFF))
      |> mix(bxor(big, 0xA5A5A5))
      |> mix(big >>> 17)
      |> mix(popcount(rem(big, 1_000_000_007), 0))
    h = mix(h, num_digits(big))
    h
  end

  # ---- number theory ----
  defp mod_pow(_b, 0, m), do: rem(1, m)
  defp mod_pow(b, e, m) do
    b = rem(b, m)
    do_pow(b, e, m, 1)
  end
  defp do_pow(_b, 0, _m, acc), do: acc
  defp do_pow(b, e, m, acc) do
    acc = if (e &&& 1) == 1, do: rem(acc * b, m), else: acc
    do_pow(rem(b * b, m), e >>> 1, m, acc)
  end

  defp gcd(a, 0), do: abs(a)
  defp gcd(a, b), do: gcd(b, rem(a, b))

  defp ext_gcd(a, 0), do: {a, 1, 0}
  defp ext_gcd(a, b) do
    {g, x, y} = ext_gcd(b, rem(a, b))
    {g, y, x - div(a, b) * y}
  end

  defp mod_inverse(a, m) do
    {g, x, _} = ext_gcd(rem(a, m), m)
    if g != 1, do: nil, else: rem(rem(x, m) + m, m)
  end

  # deterministic Miller-Rabin with fixed witnesses (correct for all n < 3.3e24)
  defp is_prime?(n) when n < 2, do: false
  defp is_prime?(2), do: true
  defp is_prime?(3), do: true
  defp is_prime?(n) when rem(n, 2) == 0, do: false
  defp is_prime?(n) do
    {d, r} = factor_two(n - 1, 0)
    witnesses = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37]
    Enum.all?(witnesses, fn a ->
      if rem(a, n) == 0, do: true, else: mr_check(a, d, n, r)
    end)
  end

  defp factor_two(d, r) when rem(d, 2) == 1, do: {d, r}
  defp factor_two(d, r), do: factor_two(div(d, 2), r + 1)

  defp mr_check(a, d, n, r) do
    x = mod_pow(a, d, n)
    if x == 1 or x == n - 1 do
      true
    else
      mr_loop(x, n, r - 1)
    end
  end
  defp mr_loop(_x, _n, 0), do: false
  defp mr_loop(x, n, r) do
    x = rem(x * x, n)
    cond do
      x == n - 1 -> true
      x == 1 -> false
      true -> mr_loop(x, n, r - 1)
    end
  end

  defp next_prime(n) do
    n = if rem(n, 2) == 0, do: n + 1, else: n + 2
    if is_prime?(n), do: n, else: next_prime(n)
  end

  defp pick_e(phi, e) do
    if gcd(e, phi) == 1, do: e, else: pick_e(phi, e + 2)
  end

  defp gen_msgs(0, s, _n, acc), do: {Enum.reverse(acc), s}
  defp gen_msgs(k, s, n, acc) do
    {v, s1} = rng(s, n)
    gen_msgs(k - 1, s1, n, [rem(v, n) | acc])
  end

  defp fib(n), do: fib(n, 0, 1)
  defp fib(0, a, _b), do: a
  defp fib(n, a, b), do: fib(n - 1, b, a + b)

  defp factorial(0), do: 1
  defp factorial(n), do: n * factorial(n - 1)

  defp trailing_zeros_fact(n), do: tz_fact(n, 5, 0)
  defp tz_fact(n, p, acc) when p > n, do: acc
  defp tz_fact(n, p, acc), do: tz_fact(n, p * 5, acc + div(n, p))

  defp num_digits(0), do: 1
  defp num_digits(n), do: nd(abs(n), 0)
  defp nd(0, acc), do: acc
  defp nd(n, acc), do: nd(div(n, 10), acc + 1)

  defp to_base(0, _r), do: [0]
  defp to_base(n, r), do: tb(n, r, []) |> Enum.reverse()
  defp tb(0, _r, acc), do: acc
  defp tb(n, r, acc), do: tb(div(n, r), r, [rem(n, r) | acc])

  defp from_base(digits, r), do: Enum.reduce(digits, 0, fn d, acc -> acc * r + d end)

  defp popcount(0, acc), do: acc
  defp popcount(n, acc), do: popcount(n >>> 1, acc + (n &&& 1))

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
