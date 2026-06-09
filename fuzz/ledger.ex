# A clearinghouse ledger — the service under differential fuzzing.
#
# `run(seed, nops)` is a PURE deterministic function: a 64-bit PRNG (seeded by `seed`)
# generates a stream of `nops` random ledger operations; each is applied to an in-memory
# double-entry ledger; after the stream a rolling hash is folded over the ENTIRE final
# state and returned as a single integer.
#
# Why this is a strong differential test (run on WasmGC vs the real Elixir VM):
#   * The PRNG runs INSIDE the compiled code from the same seed — if integer arithmetic
#     is even slightly wrong, the two op streams diverge at op #1.
#   * The rolling hash is folded over every account's exact balance plus the counters, so
#     a single wrong term anywhere avalanches into a totally different final integer.
#   * It structurally forces every term type + feature: maps (account store), lists +
#     `Enum`/closures (snapshot fold), tuples (sort keys), pattern-match dispatch,
#     recursion (the op loop, via real Wasm tail calls), exceptions (overdraw -> throw/
#     catch), bignums (64-bit LCG products + compounding balances), and term ordering
#     (`Enum.sort` over {balance, id} tuples that may hold bignums).
#
# A correct run and a one-bit-wrong run share NOTHING after the first divergence.
defmodule Ledger do
  @k 16                              # number of distinct accounts (ids 0..15)
  @hmod 2_305_843_009_213_693_951   # 2^61 - 1 (Mersenne) — hash modulus
  @p1 1_000_003                      # mixing primes
  @p2 2_654_435_761
  @p3 1_442_695_040_888_963_407
  # 64-bit LCG (MMIX/Knuth constants); products are ~2^127 before the mod, so every PRNG
  # step exercises bignum multiply + rem. Output is run through a PCG-style xorshift so
  # band/bxor/bsr are on the hot path too.
  @lmul 6_364_136_223_846_793_005
  @linc 1_442_695_040_888_963_407
  @lmod 18_446_744_073_709_551_616   # 2^64

  def run(seed, nops) do
    s0 = rem(abs(seed) + 1, @lmod)
    {accts, _s, txns, errs, vol} = loop(nops, %{}, s0, 0, 0, 0)
    # final fold: the whole ledger state -> one integer
    h = snapshot(accts, 14_695_981_039_346_656_037 |> rem(@hmod))
    h
    |> mix(txns)
    |> mix(errs)
    |> mix(vol)
  end

  # ---- the op loop (tail-recursive -> real Wasm tail calls, safe at 100k+ depth) ----
  defp loop(0, accts, s, txns, errs, vol), do: {accts, s, txns, errs, vol}

  defp loop(n, accts, s, txns, errs, vol) do
    {op, s1} = rng(s, 6)
    {id, s2} = rng(s1, @k)
    {id2, s3} = rng(s2, @k)
    {amt, s4} = rng(s3, 100_000)
    {accts2, txns2, errs2, vol2} = apply_op(op, accts, id, id2, amt, txns, errs, vol)
    loop(n - 1, accts2, s4, txns2, errs2, vol2)
  end

  # ---- the six operations (pattern-match dispatch on op code 0..5) ----
  defp apply_op(0, accts, id, _id2, amt, txns, errs, vol) do
    # open / set
    {Map.put(accts, id, amt), txns + 1, errs, vol + amt}
  end

  defp apply_op(1, accts, id, _id2, amt, txns, errs, vol) do
    # deposit
    {Map.put(accts, id, bal(accts, id) + amt), txns + 1, errs, vol + amt}
  end

  defp apply_op(2, accts, id, _id2, amt, txns, errs, vol) do
    # withdraw — overdraw is rejected via throw/catch (exercises exceptions)
    try do
      cur = bal(accts, id)
      if amt > cur, do: throw(:insufficient)
      {Map.put(accts, id, cur - amt), txns + 1, errs, vol + amt}
    catch
      :throw, :insufficient -> {accts, txns, errs + 1, vol}
    end
  end

  defp apply_op(3, accts, id, id2, amt, txns, errs, vol) do
    # transfer id -> id2, atomic, rejected if insufficient
    try do
      from = bal(accts, id)
      if id == id2 or amt > from, do: throw(:insufficient)
      a1 = Map.put(accts, id, from - amt)
      a2 = Map.put(a1, id2, bal(a1, id2) + amt)
      {a2, txns + 1, errs, vol + amt}
    catch
      :throw, :insufficient -> {accts, txns, errs + 1, vol}
    end
  end

  defp apply_op(4, accts, id, _id2, amt, txns, errs, vol) do
    # accrue interest — compounding pushes balances toward (and past) the i31/i64 tiers
    cur = bal(accts, id)
    rate = rem(amt, 32)
    {Map.put(accts, id, cur + div(cur * rate, 100)), txns + 1, errs, vol}
  end

  defp apply_op(5, accts, _id, _id2, _amt, txns, errs, vol) do
    # snapshot — no state change, but folds the whole book into nothing here; the volume
    # counter is bumped so snapshots still perturb the trace deterministically.
    {accts, txns, errs, vol + 1}
  end

  # ---- helpers ----
  defp bal(accts, id) do
    case Map.get(accts, id) do
      nil -> 0
      v -> v
    end
  end

  # fold the entire book (canonically ordered) into the hash. Map key order differs between
  # Wasm and the VM, so we sort {balance, id} tuples — a TOTAL term order both sides share,
  # and one that puts bignum balances through `term_compare`.
  defp snapshot(accts, h) do
    accts
    |> Map.keys()
    |> Enum.map(fn id -> {bal(accts, id), id} end)
    |> Enum.sort()
    |> Enum.reduce(h, fn {b, id}, acc -> acc |> mix(id) |> mix(b) end)
  end

  # Avalanche hash mixing arithmetic AND bitwise over full bignum values. Exercises mul/add/rem
  # (bignum tiers) plus band/bxor/bsr directly on boxed 2^61-range operands. @hmod is prime.
  defp mix(h, x) do
    xn = rem(x, @hmod)                                   # all call sites pass x >= 0
    v = rem(h * @p1 + xn * @p2 + @p3, @hmod)
    # xorshift-style bitwise round on the full boxed value, then fold back into the field
    w = Bitwise.bxor(v, Bitwise.bsr(v, 23))
    w2 = Bitwise.band(Bitwise.bxor(w, Bitwise.bsr(w, 17)), @hmod)
    rem(w2 * @p1 + 1, @hmod)
  end

  # 64-bit LCG with a PCG-style xorshift output — band/bxor/bsr run on the boxed 2^64 state.
  defp rng(s, m) do
    s2 = rem(s * @lmul + @linc, @lmod)
    x = Bitwise.bxor(s2, Bitwise.bsr(s2, 33))
    {rem(x, m), s2}
  end

  # ── investigation helper: name the operation at a given op index ──
  # After the fuzz harness bisects to the first diverging op count N, it calls this to report WHICH
  # operation diverged. Replays the PRNG exactly as loop/6 does: 4 rng draws per op (op, id, id2, amt).
  @op_names {:open, :deposit, :withdraw, :transfer, :accrue, :snapshot}
  def op_name(seed, i) when i >= 1 do
    s = advance(rem(abs(seed) + 1, @lmod), i - 1)
    {op, _} = rng(s, 6)
    elem(@op_names, op)
  end
  defp advance(s, 0), do: s
  defp advance(s, k) do
    {_, s1} = rng(s, 6); {_, s2} = rng(s1, @k); {_, s3} = rng(s2, @k); {_, s4} = rng(s3, 100_000)
    advance(s4, k - 1)
  end
end
