# extra: Integer
# A calendar / scheduling engine computed entirely from integer day-numbers (NO Date/DateTime modules):
# leap-year test, days-in-month, Zeller day-of-week, date<->day-number conversion, add/diff days, a
# generated schedule of recurring events from the seed, conflict detection, grouping by weekday, and a
# business-day counter. Heavy integer arithmetic, recursion, Map, Enum, tuples, guards. Pure & deterministic.
defmodule Gap16 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @weekdays {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    h = 14_695_981
    h = mix(h, s0)

    # ---- leap-year survey over a seed-derived span ----
    {y0, s1} = rng(s0, 200)
    base_year = 1900 + y0
    years = base_year..(base_year + 40)
    leaps = years |> Enum.filter(&leap?/1)
    h = mix(h, length(leaps))
    h = fold_list(h, Enum.to_list(leaps))
    # days in each year
    ydays = years |> Enum.map(&days_in_year/1)
    h = fold_list(h, ydays)
    h = mix(h, Enum.sum(ydays))

    # ---- days-in-month table across the span ----
    month_days =
      for y <- base_year..(base_year + 3), m <- 1..12, do: days_in_month(y, m)
    h = fold_list(h, month_days)
    h = mix(h, Enum.sum(month_days))

    # ---- date <-> day-number round trips ----
    {dates, s2} = gen_dates(40, s1, base_year, [])
    daynums = Enum.map(dates, fn {y, m, d} -> to_daynum(y, m, d) end)
    h = fold_list(h, daynums)
    # round-trip each daynum back to a date and verify
    {h, rterr} =
      Enum.reduce(Enum.zip(dates, daynums), {h, 0}, fn {dt, dn}, {acc, errs} ->
        back = from_daynum(dn)
        acc = acc |> mix_date(back)
        {acc, errs + if(back == dt, do: 0, else: 1)}
      end)
    h = mix(h, rterr)

    # ---- day-of-week via Zeller, fold and group ----
    dows = Enum.map(dates, fn {y, m, d} -> zeller(y, m, d) end)
    h = fold_list(h, dows)
    by_weekday = Enum.group_by(dates, fn {y, m, d} -> elem(@weekdays, zeller(y, m, d)) end)
    counts = Map.new(by_weekday, fn {k, vs} -> {k, length(vs)} end)
    h = fold_map(h, counts)
    # cross-check: day-of-week from daynum should agree with Zeller
    dow_agree =
      Enum.zip(dates, daynums)
      |> Enum.count(fn {{y, m, d}, dn} -> dow_from_daynum(dn) == zeller(y, m, d) end)
    h = mix(h, dow_agree)

    # ---- add/diff days arithmetic ----
    {deltas, s3} = gen_ints(40, s2, 4000, [])
    shifted =
      Enum.zip(daynums, deltas)
      |> Enum.map(fn {dn, k} -> from_daynum(dn + k - 2000) end)
    h = Enum.reduce(shifted, h, fn dt, acc -> mix_date(acc, dt) end)
    # pairwise diffs between consecutive dates
    diffs =
      daynums
      |> Enum.zip(Enum.drop(daynums, 1))
      |> Enum.map(fn {a, b} -> abs(b - a) end)
    h = fold_list(h, diffs)
    h = mix(h, Enum.sum(diffs))

    # ---- generate a schedule of recurring events ----
    {events, s4} = gen_events(12, s3, base_year, [])
    # expand each recurring event into occurrences (start daynum + k*period, count times)
    occurrences =
      events
      |> Enum.flat_map(fn {start_dn, period, count, dur, label} ->
        for k <- 0..(count - 1) do
          s = start_dn + k * period
          {s, s + dur, label}
        end
      end)
    h = mix(h, length(occurrences))
    occ_sorted = Enum.sort_by(occurrences, fn {s, e, l} -> {s, e, l} end)
    h =
      Enum.reduce(occ_sorted, h, fn {s, e, l}, acc ->
        acc |> mix(s) |> mix(e) |> mix(l)
      end)

    # ---- conflict detection: overlapping intervals ----
    conflicts = count_conflicts(occ_sorted)
    h = mix(h, conflicts)
    # total scheduled days (union length surrogate: sum of durations)
    total_dur = occ_sorted |> Enum.map(fn {s, e, _} -> e - s end) |> Enum.sum()
    h = mix(h, total_dur)

    # ---- group occurrences by weekday of their start ----
    occ_by_dow =
      Enum.group_by(occ_sorted, fn {s, _e, _l} -> dow_from_daynum(s) end)
    occ_counts = Map.new(occ_by_dow, fn {k, vs} -> {k, length(vs)} end)
    h = fold_map(h, occ_counts)

    # ---- business-day counts over generated ranges ----
    {ranges, _s5} = gen_ranges(16, s4, daynums, [])
    bdays =
      Enum.map(ranges, fn {a, b} ->
        {lo, hi} = if a <= b, do: {a, b}, else: {b, a}
        business_days(lo, hi)
      end)
    h = fold_list(h, bdays)
    h = mix(h, Enum.sum(bdays))

    # ---- quarter & week-of-year classification ----
    h =
      Enum.reduce(dates, h, fn {y, m, d}, acc ->
        q = div(m - 1, 3) + 1
        doy = day_of_year(y, m, d)
        woy = div(doy - 1, 7) + 1
        acc |> mix(q) |> mix(doy) |> mix(woy)
      end)
    h
  end

  # ---- calendar core (proleptic Gregorian) ----
  defp leap?(y) when rem(y, 400) == 0, do: true
  defp leap?(y) when rem(y, 100) == 0, do: false
  defp leap?(y) when rem(y, 4) == 0, do: true
  defp leap?(_y), do: false

  defp days_in_year(y), do: if(leap?(y), do: 366, else: 365)

  defp days_in_month(y, 2), do: if(leap?(y), do: 29, else: 28)
  defp days_in_month(_y, m) when m in [4, 6, 9, 11], do: 30
  defp days_in_month(_y, _m), do: 31

  defp day_of_year(y, m, d), do: month_offset(y, m, 1, 0) + d
  defp month_offset(_y, m, cur, acc) when cur >= m, do: acc
  defp month_offset(y, m, cur, acc), do: month_offset(y, m, cur + 1, acc + days_in_month(y, cur))

  # days since 0000-03-01 (Howard Hinnant's algorithm), giving a clean integer day-number
  defp to_daynum(y, m, d) do
    y2 = if m <= 2, do: y - 1, else: y
    era = div(if(y2 >= 0, do: y2, else: y2 - 399), 400)
    yoe = y2 - era * 400
    mp = rem(m + 9, 12)
    doy = div(153 * mp + 2, 5) + d - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    era * 146_097 + doe - 719_468
  end

  defp from_daynum(z) do
    z = z + 719_468
    era = div(if(z >= 0, do: z, else: z - 146_096), 146_097)
    doe = z - era * 146_097
    yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146_096), 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = if mp < 10, do: mp + 3, else: mp - 9
    {if(m <= 2, do: y + 1, else: y), m, d}
  end

  # Zeller's congruence -> 0=Mon .. 6=Sun
  defp zeller(y, m, d) do
    {m2, y2} = if m < 3, do: {m + 12, y - 1}, else: {m, y}
    k = rem(y2, 100)
    j = div(y2, 100)
    hh = rem(d + div(13 * (m2 + 1), 5) + k + div(k, 4) + div(j, 4) + 5 * j, 7)
    # Zeller: 0=Sat..6=Fri ; convert to 0=Mon..6=Sun
    rem(hh + 5, 7)
  end

  # day-of-week from day-number; daynum 0 == 0000-03-01.
  defp dow_from_daynum(dn) do
    # 1970-01-01 is daynum (to_daynum 1970 1 1) and is a Thursday (=3 in 0=Mon scheme)
    epoch = 719_468 - 719_468
    _ = epoch
    rem(rem(dn + 3, 7) + 7, 7)
  end

  defp business_days(lo, hi) do
    Enum.count(lo..hi, fn dn -> dow_from_daynum(dn) < 5 end)
  end

  defp count_conflicts(sorted) do
    sorted
    |> pairs()
    |> Enum.count(fn {{s1, e1, _}, {s2, e2, _}} -> s1 < e2 and s2 < e1 end)
  end

  defp pairs([]), do: []
  defp pairs([_]), do: []
  defp pairs([x | rest]), do: Enum.map(rest, &{x, &1}) ++ pairs(rest)

  # ---- generators ----
  defp gen_dates(0, s, _by, acc), do: {Enum.reverse(acc), s}
  defp gen_dates(k, s, by, acc) do
    {yo, s1} = rng(s, 30)
    {mo, s2} = rng(s1, 12)
    y = by + yo
    m = mo + 1
    {dd, s3} = rng(s2, days_in_month(y, m))
    gen_dates(k - 1, s3, by, [{y, m, dd + 1} | acc])
  end

  defp gen_ints(0, s, _max, acc), do: {Enum.reverse(acc), s}
  defp gen_ints(k, s, max, acc) do
    {v, s1} = rng(s, max)
    gen_ints(k - 1, s1, max, [v | acc])
  end

  defp gen_events(0, s, _by, acc), do: {Enum.reverse(acc), s}
  defp gen_events(k, s, by, acc) do
    {yo, s1} = rng(s, 10)
    {mo, s2} = rng(s1, 12)
    {p, s3} = rng(s2, 30)
    {c, s4} = rng(s3, 8)
    {dur, s5} = rng(s4, 5)
    {lbl, s6} = rng(s5, 6)
    start = to_daynum(by + yo, mo + 1, 1)
    period = p + 1
    count = c + 1
    label = elem({:standup, :review, :deploy, :sync, :retro, :planning}, lbl)
    gen_events(k - 1, s6, by, [{start, period, count, dur, label} | acc])
  end

  defp gen_ranges(0, s, _dns, acc), do: {Enum.reverse(acc), s}
  defp gen_ranges(k, s, dns, acc) do
    n = length(dns)
    {i, s1} = rng(s, n)
    {span, s2} = rng(s1, 60)
    a = Enum.at(dns, i)
    gen_ranges(k - 1, s2, dns, [{a, a + span} | acc])
  end

  defp mix_date(h, {y, m, d}), do: h |> mix(y) |> mix(m) |> mix(d)

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
