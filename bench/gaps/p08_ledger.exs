# extra: Enum Map List Integer
# A double-entry accounting engine: synthesize a batch of transactions (deposits, withdrawals,
# transfers, interest accrual) over named accounts from the seed, apply them while enforcing invariants
# (overdrafts rejected via guards), maintain a journal of postings, then compute per-account balances,
# a trial balance, and an audit checksum over the sorted final state. Heavy Map/Enum/recursion/pattern
# matching with bignum-scale integer money (amounts in cents). Pure & deterministic.
defmodule Gap08 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @accounts ~w(cash bank payroll vendor revenue expense reserve escrow)a

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    h = 14_695_981

    # seed opening balances (in cents)
    {ledger, s1} = open_accounts(@accounts, s0, %{})
    h = fold_map(h, Map.new(ledger, fn {k, v} -> {Atom.to_string(k), v} end))
    opening_total = ledger |> Map.values() |> Enum.sum()
    h = mix(h, opening_total)

    # generate a stream of transactions
    {txns, s2} = gen_txns(80 + rem(seed, 40), s1, [])
    h = mix(h, length(txns))

    # apply transactions, accumulating a journal of accepted postings and a reject log
    {final_ledger, journal, rejects} = apply_all(txns, ledger, [], [])

    h = mix(h, length(journal))
    h = mix(h, length(rejects))

    # fold the journal (each posting: {seq, account, delta, kind})
    h =
      Enum.reduce(journal, h, fn {seq, acct, delta, kind}, a ->
        a |> mix(seq) |> mix(Atom.to_string(acct)) |> mix(delta) |> mix(Atom.to_string(kind))
      end)

    # fold reject reasons (sorted by sequence for determinism)
    h =
      rejects
      |> Enum.sort_by(fn {seq, _reason} -> seq end)
      |> Enum.reduce(h, fn {seq, reason}, a -> a |> mix(seq) |> mix(Atom.to_string(reason)) end)

    # ---- final balances ----
    h = fold_map(h, Map.new(final_ledger, fn {k, v} -> {Atom.to_string(k), v} end))

    # ---- conservation invariant: total of all internal transfers nets to zero;
    # net change in the system equals deposits - withdrawals + interest ----
    closing_total = final_ledger |> Map.values() |> Enum.sum()
    h = mix(h, closing_total)

    external_delta =
      Enum.reduce(journal, 0, fn {_seq, _acct, delta, kind}, acc ->
        case kind do
          :deposit -> acc + delta
          :withdraw -> acc + delta
          :interest -> acc + delta
          # transfer legs net to zero internally
          _ -> acc
        end
      end)

    h = mix(h, external_delta)
    h = mix(h, bool_int(closing_total == opening_total + external_delta))

    # ---- trial balance: split into debit (negative-side) and credit (positive) columns ----
    {debits, credits} =
      Enum.reduce(final_ledger, {0, 0}, fn {_acct, bal}, {d, c} ->
        if bal < 0, do: {d + bal, c}, else: {d, c + bal}
      end)

    h = h |> mix(debits) |> mix(credits) |> mix(debits + credits)

    # ---- per-account posting counts and turnover ----
    by_acct = Enum.group_by(journal, fn {_seq, acct, _d, _k} -> acct end)

    posting_counts = Map.new(by_acct, fn {acct, posts} -> {Atom.to_string(acct), length(posts)} end)
    h = fold_map(h, posting_counts)

    turnover =
      Map.new(by_acct, fn {acct, posts} ->
        {Atom.to_string(acct), posts |> Enum.map(fn {_, _, d, _} -> abs(d) end) |> Enum.sum()}
      end)

    h = fold_map(h, turnover)

    # ---- statistics over the journal ----
    deltas = Enum.map(journal, fn {_, _, d, _} -> d end)

    case deltas do
      [] ->
        h = mix(h, 0)
        h

      _ ->
        {mn, mx} = Enum.min_max(deltas)
        mean = div(Enum.sum(deltas), length(deltas))
        h = h |> mix(mn) |> mix(mx) |> mix(mean)
        # variance surrogate (integer): sum of squared deviations
        ss = deltas |> Enum.map(fn d -> (d - mean) * (d - mean) end) |> Enum.sum()
        h = mix(h, ss)
        h
    end
    |> finish(final_ledger, journal, s2)
  end

  defp finish(h, final_ledger, journal, s) do
    # ---- interest compounding pass: accrue 3% (300 bps) on positive balances, rounded down ----
    accrued =
      final_ledger
      |> Enum.map(fn {acct, bal} ->
        interest = if bal > 0, do: div(bal * 300, 10_000), else: 0
        {acct, bal + interest}
      end)
      |> Map.new()

    h = fold_map(h, Map.new(accrued, fn {k, v} -> {Atom.to_string(k), v} end))
    h = mix(h, accrued |> Map.values() |> Enum.sum())

    # ---- audit: canonical fold over sorted account state ----
    audit =
      accrued
      |> Map.to_list()
      |> Enum.sort_by(fn {acct, _} -> Atom.to_string(acct) end)
      |> Enum.reduce(0, fn {acct, bal}, acc ->
        rem(acc * 1_000_003 + abs(bal) + byte_size(Atom.to_string(acct)), @cmod)
      end)

    h = mix(h, audit)

    # richest and poorest account
    {rich_acct, rich_bal} = Enum.max_by(accrued, fn {_, bal} -> bal end)
    {poor_acct, poor_bal} = Enum.min_by(accrued, fn {_, bal} -> bal end)
    h = h |> mix(Atom.to_string(rich_acct)) |> mix(rich_bal)
    h = h |> mix(Atom.to_string(poor_acct)) |> mix(poor_bal)

    # journal seq sum and a running-balance replay checksum
    replay = replay_balances(journal)
    h = fold_list(h, replay)

    h = mix(h, s)
    h
  end

  # ---- account setup ----
  defp open_accounts(accts, s, acc) do
    Enum.reduce(accts, {acc, s}, fn name, {m, sa} ->
      {v, sb} = rng(sa, 100_000)
      {Map.put(m, name, v + 10_000), sb}
    end)
    |> then(fn {m, sf} -> {m, sf} end)
  end

  # ---- transaction generation ----
  defp gen_txns(0, s, acc), do: {Enum.reverse(acc), s}

  defp gen_txns(n, s, acc) do
    {kind_i, s1} = rng(s, 4)
    {amt, s2} = rng(s1, 50_000)
    amt = amt + 1
    {ai, s3} = rng(s2, length(@accounts))
    {bi, s4} = rng(s3, length(@accounts))
    a = Enum.at(@accounts, ai)
    b = Enum.at(@accounts, bi)

    txn =
      case kind_i do
        0 -> {:deposit, a, amt}
        1 -> {:withdraw, a, amt}
        2 -> {:transfer, a, b, amt}
        3 -> {:interest, a, rem(amt, 1000)}
      end

    gen_txns(n - 1, s4, [txn | acc])
  end

  # ---- application engine with invariants enforced by guards ----
  defp apply_all([], ledger, journal, rejects),
    do: {ledger, Enum.reverse(journal), Enum.reverse(rejects)}

  defp apply_all([txn | rest], ledger, journal, rejects) do
    seq = length(journal) + length(rejects)

    case apply_txn(txn, ledger, seq) do
      {:ok, new_ledger, postings} ->
        apply_all(rest, new_ledger, Enum.reverse(postings) ++ journal, rejects)

      {:reject, reason} ->
        apply_all(rest, ledger, journal, [{seq, reason} | rejects])
    end
  end

  defp apply_txn({:deposit, acct, amt}, ledger, seq) when amt > 0 do
    bal = Map.fetch!(ledger, acct)
    {:ok, Map.put(ledger, acct, bal + amt), [{seq, acct, amt, :deposit}]}
  end

  defp apply_txn({:withdraw, acct, amt}, ledger, seq) when amt > 0 do
    bal = Map.fetch!(ledger, acct)

    if bal - amt >= 0 do
      {:ok, Map.put(ledger, acct, bal - amt), [{seq, acct, -amt, :withdraw}]}
    else
      {:reject, :insufficient_funds}
    end
  end

  defp apply_txn({:transfer, from, to, _amt}, _ledger, _seq) when from == to,
    do: {:reject, :self_transfer}

  defp apply_txn({:transfer, from, to, amt}, ledger, seq) when amt > 0 do
    from_bal = Map.fetch!(ledger, from)

    if from_bal - amt >= 0 do
      to_bal = Map.fetch!(ledger, to)

      ledger =
        ledger
        |> Map.put(from, from_bal - amt)
        |> Map.put(to, to_bal + amt)

      {:ok, ledger, [{seq, from, -amt, :transfer}, {seq, to, amt, :transfer}]}
    else
      {:reject, :insufficient_funds}
    end
  end

  defp apply_txn({:interest, acct, rate_bps}, ledger, seq) when rate_bps >= 0 do
    bal = Map.fetch!(ledger, acct)
    interest = div(bal * rate_bps, 10_000)

    if interest > 0 do
      {:ok, Map.put(ledger, acct, bal + interest), [{seq, acct, interest, :interest}]}
    else
      {:reject, :no_interest}
    end
  end

  defp apply_txn(_, _, _), do: {:reject, :malformed}

  # replay: produce a running checksum of cumulative deltas per posting
  defp replay_balances(journal) do
    journal
    |> Enum.scan(0, fn {_seq, _acct, delta, _kind}, acc -> acc + delta end)
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
