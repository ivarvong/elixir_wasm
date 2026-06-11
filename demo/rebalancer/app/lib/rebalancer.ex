defmodule Rebalancer do
  @moduledoc """
  A portfolio rebalancer as a JSON API, written as ordinary pure Elixir on the real
  unmodified Jason dep. One bin->bin entry point so the same function serves the VM,
  `mix wasm.verify`, and the Cloudflare Worker.

  Request:

      {
        "cash": 5000.0,
        "tolerance": 0.0025,                       // optional drift band, fraction of total
        "targets": {"VTI": 0.6, "VXUS": 0.3, "BND": 0.1},
        "positions": [{"symbol": "VTI", "shares": 120, "price": 262.41}, ...]
      }

  Response: total value, per-position weight/target/drift, the whole-share trade list
  (sells first — they fund the buys), cash after, and the residual drift. Invalid input
  returns {"error": reason} rather than raising — the error path is part of the API.
  """

  def rebalance(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, req} when is_map(req) -> req |> plan() |> Jason.encode!()
      {:ok, _} -> Jason.encode!(%{"error" => "request must be a JSON object"})
      {:error, _} -> Jason.encode!(%{"error" => "invalid JSON"})
    end
  end

  defp plan(req) do
    with {:ok, cash} <- num(Map.get(req, "cash", 0), "cash"),
         {:ok, tol} <- num(Map.get(req, "tolerance", 0), "tolerance"),
         {:ok, targets} <- targets(Map.get(req, "targets")),
         {:ok, positions} <- positions(Map.get(req, "positions")) do
      held = Map.new(positions, fn p -> {p.symbol, p} end)

      case Enum.find(Map.keys(targets), fn s -> not Map.has_key?(held, s) end) do
        nil -> compute(cash, tol, targets, positions)
        sym -> %{"error" => "no position (price) for target symbol " <> sym}
      end
    else
      {:error, msg} -> %{"error" => msg}
    end
  end

  defp compute(cash, tol, targets, positions) do
    total = Enum.reduce(positions, cash * 1.0, fn p, acc -> acc + p.shares * p.price end)

    rows =
      Enum.map(positions, fn p ->
        value = p.shares * p.price
        target = Map.get(targets, p.symbol, 0) * 1.0
        weight = if total > 0, do: value / total, else: 0.0
        delta = target * total - value

        traded =
          if total > 0 and abs(delta) / total > tol, do: trunc(delta / p.price), else: 0

        %{p: p, value: value, weight: weight, target: target, traded: traded}
      end)

    trades =
      rows
      |> Enum.filter(fn r -> r.traded != 0 end)
      |> Enum.map(fn r ->
        action = if r.traded > 0, do: "buy", else: "sell"
        shares = abs(r.traded)

        %{
          "symbol" => r.p.symbol,
          "action" => action,
          "shares" => shares,
          "amount" => round2(shares * r.p.price)
        }
      end)
      |> Enum.sort_by(fn t -> {t["action"] == "buy", t["symbol"]} end)

    cash_after =
      Enum.reduce(rows, cash * 1.0, fn r, acc -> acc - r.traded * r.p.price end)

    max_drift =
      rows
      |> Enum.map(fn r ->
        value = (r.p.shares + r.traded) * r.p.price
        weight = if total > 0, do: value / total, else: 0.0
        abs(weight - r.target)
      end)
      |> Enum.reduce(0.0, fn d, acc -> max(d, acc) end)

    %{
      "total_value" => round2(total),
      "positions" =>
        rows
        |> Enum.sort_by(fn r -> r.p.symbol end)
        |> Enum.map(fn r ->
          %{
            "symbol" => r.p.symbol,
            "shares" => r.p.shares,
            "price" => r.p.price,
            "value" => round2(r.value),
            "weight" => round6(r.weight),
            "target" => round6(r.target),
            "drift" => round6(r.weight - r.target)
          }
        end),
      "trades" => trades,
      "cash_after" => round2(cash_after),
      "max_drift_after" => round6(max_drift)
    }
  end

  # ── input validation ──

  defp targets(t) when is_map(t) and map_size(t) > 0 do
    if Enum.all?(t, fn {k, v} -> is_binary(k) and is_number(v) and v >= 0 end) do
      sum = Enum.reduce(t, 0.0, fn {_, v}, acc -> acc + v end)

      if abs(sum - 1.0) < 1.0e-6,
        do: {:ok, t},
        else: {:error, "targets must sum to 1.0"}
    else
      {:error, "targets must map symbol to a non-negative weight"}
    end
  end

  defp targets(_), do: {:error, "targets is required"}

  defp positions(l) when is_list(l) do
    parsed =
      Enum.map(l, fn
        %{"symbol" => s, "shares" => n, "price" => p}
        when is_binary(s) and is_integer(n) and n >= 0 and is_number(p) and p > 0 ->
          %{symbol: s, shares: n, price: p * 1.0}

        _ ->
          :bad
      end)

    syms = Enum.map(parsed, fn p -> if p == :bad, do: :bad, else: p.symbol end)

    cond do
      Enum.member?(parsed, :bad) ->
        {:error, "each position needs symbol, integer shares >= 0, and price > 0"}

      length(Enum.uniq(syms)) != length(syms) ->
        {:error, "duplicate position symbol"}

      true ->
        {:ok, parsed}
    end
  end

  defp positions(_), do: {:error, "positions is required"}

  defp num(v, _name) when is_number(v) and v >= 0, do: {:ok, v}
  defp num(_, name), do: {:error, name <> " must be a non-negative number"}

  defp round2(x), do: Float.round(x * 1.0, 2)
  defp round6(x), do: Float.round(x * 1.0, 6)
end
