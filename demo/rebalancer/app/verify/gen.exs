# Structured case generator for `mix wasm.verify --gen verify/gen.exs`.
# Evaluates to %{"rebalance" => fn index -> [json_request] end}; the task seeds :rand from
# {seed, index} before each call, so every case regenerates standalone from its index.
#
# Mix of shapes: ~90% well-formed portfolios (1-20 positions, prices from pennies to 7 figures,
# cash from zero through bignum-tier dollar amounts, tolerances 0..5%), ~10% deliberate hits on
# every validation branch plus malformed JSON.
gen_sym = fn ->
  for _ <- 1..(:rand.uniform(4)), into: "", do: <<Enum.random(?A..?Z)>>
end

gen_syms = fn n ->
  Stream.repeatedly(gen_sym) |> Enum.take(n * 3) |> Enum.uniq() |> Enum.take(n)
end

gen_price = fn ->
  # pennies to 7 figures, biased low like real tickers
  mag = :rand.uniform(7) - 2
  Float.round(:rand.uniform() * :math.pow(10.0, mag) + 0.01, :rand.uniform(4))
end

gen_cash = fn ->
  case :rand.uniform(10) do
    1 -> 0
    # bignum-tier account values cross the i31/i64 boundaries inside the math
    2 -> :rand.uniform(10_000_000_000_000)
    n when n <= 6 -> Float.round(:rand.uniform() * 100_000.0, 2)
    _ -> :rand.uniform(50_000)
  end
end

well_formed = fn ->
  n = :rand.uniform(20)
  syms = gen_syms.(n)

  positions =
    Enum.map(syms, fn s ->
      %{"symbol" => s, "shares" => :rand.uniform(10_001) - 1, "price" => gen_price.()}
    end)

  k = :rand.uniform(length(syms))
  weights = Enum.map(1..k, fn _ -> :rand.uniform() + 0.001 end)
  wsum = Enum.sum(weights)

  targets =
    Enum.zip(Enum.take(syms, k), weights)
    |> Map.new(fn {s, w} -> {s, w / wsum} end)

  req = %{
    "cash" => gen_cash.(),
    "targets" => targets,
    "positions" => positions
  }

  case :rand.uniform(4) do
    1 -> req
    2 -> Map.put(req, "tolerance", Float.round(:rand.uniform() * 0.05, 4))
    3 -> Map.put(req, "tolerance", Enum.random([0, 0.0025, 0.01]))
    4 -> Map.put(req, "tolerance", 0.001 * :rand.uniform(50))
  end
end

broken = fn req ->
  case :rand.uniform(8) do
    # every validation branch, deliberately
    1 -> Map.update!(req, "targets", &Map.put(&1, "ZZZZ9", 0.0))
    2 -> Map.update!(req, "targets", &Map.new(&1, fn {s, w} -> {s, w * 1.5} end))
    3 -> Map.update!(req, "positions", fn [p | rest] -> [Map.put(p, "shares", -3) | rest] end)
    4 -> Map.update!(req, "positions", fn [p | rest] -> [Map.put(p, "price", 0) | rest] end)
    5 -> Map.update!(req, "positions", fn [p | rest] -> [p, p | rest] end)
    6 -> Map.put(req, "cash", -100)
    7 -> Map.delete(req, "targets")
    8 -> Map.put(req, "positions", "not a list")
  end
end

%{
  "rebalance" => fn _i ->
    json =
      case :rand.uniform(100) do
        m when m <= 3 ->
          Enum.random(["{", "[1,2,", "", "nope", ~s({"targets":), <<0xFF, 0xFE, ?{>>])

        m when m <= 6 ->
          Jason.encode!(Enum.random([[1, 2, 3], 42, "str", true]))

        m when m <= 13 ->
          Jason.encode!(broken.(well_formed.()))

        _ ->
          Jason.encode!(well_formed.())
      end

    [json]
  end
}
