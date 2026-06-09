#!/usr/bin/env elixir

# Decimal portfolio rebalancer conformance.
#
# This intentionally uses the real Decimal Hex package and idiomatic Elixir data transformations.
# It models a portfolio rebalance: parse a JSON account snapshot, value positions with Decimal,
# compare current weights to target weights, emit trade notionals, fees, cash drag, and a stable
# integer checksum. BEAM and WasmGC must agree exactly on every scenario.
#
#   elixir conformance/decimal_portfolio.exs

Mix.install([{:jason, "~> 1.4"}, {:decimal, "~> 2.1"}], consolidate_protocols: false)

defmodule DecimalPortfolioConf do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../compiler/beam2wasm.exs")
  @driver Path.join(@here, "driver.mjs")
  @tmp Path.join(@here, "_work_decimal_portfolio")
  @node System.get_env("NODE", "/Users/ivar/.nvm/versions/node/v24.16.0/bin/node")
  @wasmas System.find_executable("wasm-as") || "/opt/homebrew/bin/wasm-as"

  @src """
  defmodule DecimalPortfolioTarget do
    alias Decimal, as: D

    @percent D.new("0.01")
    @basis_point D.new("0.0001")

    def rebalance(json) do
      {:ok, account} = Jason.decode(json)

      positions = Map.fetch!(account, "positions")
      prices = Map.fetch!(account, "prices")
      targets = Map.fetch!(account, "targets")
      cash = dec(Map.fetch!(account, "cash"))
      fee_bps = dec(Map.fetch!(account, "fee_bps"))
      min_trade = dec(Map.fetch!(account, "min_trade"))

      values = position_values(positions, prices)
      gross = values |> Map.values() |> Enum.reduce(cash, fn value, acc -> D.add(acc, value) end)

      trades =
        targets
        |> Enum.map(fn {ticker, target_weight} ->
          current = Map.get(values, ticker, D.new(0))
          target = gross |> D.mult(dec(target_weight)) |> D.mult(@percent)
          delta = D.sub(target, current)
          trade = if D.compare(D.abs(delta), min_trade) == :lt, do: D.new(0), else: delta
          {ticker, trade}
        end)
        |> Enum.reject(fn {_ticker, trade} -> D.equal?(trade, D.new(0)) end)
        |> :lists.sort()

      fees = Enum.reduce(trades, D.new(0), fn {_ticker, trade}, acc ->
        acc |> D.add(D.abs(trade) |> D.mult(fee_bps) |> D.mult(@basis_point))
      end)

      buys = sum_matching(trades, :gt)
      sells = sum_matching(trades, :lt) |> D.abs()
      post_cash = cash |> D.add(sells) |> D.sub(buys) |> D.sub(fees)

      risk = risk_score(values, targets, gross)
      checksum(account, values, trades, gross, fees, post_cash, risk)
    end

    defp position_values(positions, prices) do
      Map.new(positions, fn {ticker, shares} ->
        price = prices |> Map.fetch!(ticker) |> dec()
        {ticker, D.mult(dec(shares), price)}
      end)
    end

    defp sum_matching(trades, direction) do
      Enum.reduce(trades, D.new(0), fn {_ticker, trade}, acc ->
        case {direction, D.compare(trade, D.new(0))} do
          {:gt, :gt} -> D.add(acc, trade)
          {:lt, :lt} -> D.add(acc, trade)
          _ -> acc
        end
      end)
    end

    defp risk_score(values, targets, gross) do
      Enum.reduce(targets, D.new(0), fn {ticker, target_weight}, acc ->
        current = Map.get(values, ticker, D.new(0))
        target = gross |> D.mult(dec(target_weight)) |> D.mult(@percent)
        drift = current |> D.sub(target) |> D.abs()
        D.add(acc, drift)
      end)
    end

    defp checksum(account, values, trades, gross, fees, post_cash, risk) do
      account_id = Map.fetch!(account, "account_id")

      base =
        decimal_score(gross) * 3 + decimal_score(fees) * 5 + decimal_score(post_cash) * 7 + decimal_score(risk) * 11 +
          bytesum(account_id, 0) * 13

      value_score =
        values
        |> Map.to_list()
        |> :lists.sort()
        |> Enum.reduce(17, fn {ticker, value}, acc -> acc * 31 + bytesum(ticker, 0) * 37 + decimal_score(value) end)

      trade_score =
        Enum.reduce(trades, 19, fn {ticker, trade}, acc -> acc * 41 + bytesum(ticker, 0) * 43 + decimal_score(trade) end)

      base + value_score * 47 + trade_score * 53
    end

    defp decimal_score(decimal) do
      sign = Map.fetch!(decimal, :sign)
      coef = Map.fetch!(decimal, :coef)
      exp = Map.fetch!(decimal, :exp)
      sign * (coef * 101 + exp * 103)
    end

    defp dec(value) when is_integer(value), do: D.new(value)
    defp dec(value) when is_binary(value), do: D.new(value)

    defp bytesum(<<>>, acc), do: acc
    defp bytesum(<<c, rest::binary>>, acc), do: bytesum(rest, acc + c)
  end
  """

  @cases [
    ~s({"account_id":"acct_growth_001","cash":"1200.45","fee_bps":"7.5","min_trade":"25.00","positions":{"AAPL":"12.5","MSFT":"7.25","NVDA":"2.0","BND":"40"},"prices":{"AAPL":"189.23","MSFT":"414.11","NVDA":"875.42","BND":"71.08"},"targets":{"AAPL":"25","MSFT":"25","NVDA":"30","BND":"20"}}),
    ~s({"account_id":"acct_income_002","cash":"250.00","fee_bps":"3","min_trade":"10","positions":{"VTI":"33.125","VXUS":"21.75","BND":"85.5","VNQ":"12"},"prices":{"VTI":"252.18","VXUS":"60.04","BND":"71.08","VNQ":"83.12"},"targets":{"VTI":"45","VXUS":"20","BND":"30","VNQ":"5"}}),
    ~s({"account_id":"acct_crypto_proxy_003","cash":"0.99","fee_bps":"12.5","min_trade":"100","positions":{"COIN":"18","MSTR":"3.5","SGOV":"200"},"prices":{"COIN":"236.44","MSTR":"1412.90","SGOV":"100.31"},"targets":{"COIN":"20","MSTR":"30","SGOV":"50"}}),
    ~s({"account_id":"acct_small_004","cash":"19.95","fee_bps":"0","min_trade":"5","positions":{"AAPL":"1","MSFT":"1","BND":"1"},"prices":{"AAPL":"189.23","MSFT":"414.11","BND":"71.08"},"targets":{"AAPL":"33.33","MSFT":"33.33","BND":"33.34"}}),
    ~s({"account_id":"acct_zero_005","cash":"10000.00","fee_bps":"5","min_trade":"50","positions":{},"prices":{"VTI":"252.18","VXUS":"60.04","BND":"71.08"},"targets":{"VTI":"60","VXUS":"25","BND":"15"}}),
    ~s({"account_id":"acct_precision_006","cash":"333.3333","fee_bps":"1.25","min_trade":"0.01","positions":{"AAA":"123.4567","BBB":"0.0001","CCC":"9999.9999"},"prices":{"AAA":"1.2345","BBB":"98765.4321","CCC":"0.0101"},"targets":{"AAA":"40.5","BBB":"10.25","CCC":"49.25"}})
  ]

  def main do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)

    [{mod, beam}] = Code.compile_string(@src)
    target = Path.join(@tmp, "#{mod}.beam")
    File.write!(target, beam)

    ebin = fn module -> Path.dirname(to_string(:code.which(module))) end
    jason_beams = Path.wildcard(Path.join([ebin.(Jason), "*.beam"]))
    decimal_beams = Path.wildcard(Path.join([ebin.(Decimal), "*.beam"]))
    extra_beams = Enum.map([Enum, Map, Access, Keyword, List, String, :lists, :maps], fn m -> to_string(:code.which(m)) end)

    exports = "rebalance:bin->int"
    {wat, 0} = System.cmd("elixir", [@beam2wasm, target] ++ jason_beams ++ decimal_beams ++ extra_beams,
      env: [{"EXPORTS", exports}, {"STUB", "1"}], stderr_to_stdout: false)

    watf = Path.join(@tmp, "DecimalPortfolioTarget.wat")
    wasmf = Path.join(@tmp, "DecimalPortfolioTarget.wasm")
    casesf = Path.join(@tmp, "cases.json")

    File.write!(watf, wat)
    {asm, 0} = System.cmd(@wasmas, [watf, "-o", wasmf, "-all"], stderr_to_stdout: true)
    if asm != "", do: IO.write(asm)

    cases = Enum.map(@cases, fn input ->
      %{"name" => "rebalance", "ret" => "int", "args" => [%{"type" => "bin", "val" => input}]}
    end)
    File.write!(casesf, IO.iodata_to_binary(:json.encode(cases)))

    if System.get_env("BENCH") do
      Code.require_file("_bench.exs", @here)
      Bench.report("decimal-portfolio", mod, :rebalance, @cases, wasmf, casesf)
    end

    {out, 0} = System.cmd(@node, [@driver, wasmf, watf, casesf], stderr_to_stdout: true)
    actual = String.split(String.trim_trailing(out), "\n", trim: false)
    expected = Enum.map(@cases, fn input -> Integer.to_string(apply(mod, :rebalance, [input])) end)
    failures = Enum.zip(@cases, Enum.zip(expected, actual)) |> Enum.filter(fn {_input, {exp, got}} -> exp != got end)

    IO.puts("\n══════════ DECIMAL PORTFOLIO CONFORMANCE: WasmGC vs BEAM ══════════\n")
    if failures == [] do
      IO.puts("✅ decimal-portfolio #{length(@cases)}/#{length(@cases)}")
    else
      IO.puts("⚠️  decimal-portfolio #{length(@cases) - length(failures)}/#{length(@cases)}")
      for {input, {exp, got}} <- failures do
        IO.puts("       ✗ #{inspect(input)}  got #{inspect(got)}  exp #{inspect(exp)}")
      end
    end

    IO.puts("\n──────────────────────────────────────────────────────────────")
    IO.puts("  TOTAL: #{length(@cases) - length(failures)}/#{length(@cases)} cases bit-exact vs the VM")
    IO.puts("──────────────────────────────────────────────────────────────\n")

    if failures != [], do: System.halt(1)
  end
end

DecimalPortfolioConf.main()
