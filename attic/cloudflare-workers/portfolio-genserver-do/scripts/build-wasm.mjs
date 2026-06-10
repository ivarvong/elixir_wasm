import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, "..");
const repo = resolve(project, "..", "..");
const build = resolve(project, ".build");
const compiler = resolve(repo, "compiler", "beam2wasm.exs");

const source = `
defmodule PortfolioServer do
  use GenServer

  @aapl_price 19_000
  @msft_price 42_000

  def init(cash), do: {:ok, %{cash: cash, aapl: 0, msft: 0}}

  def handle_call({:deposit, amount}, _from, state), do: {:reply, :ok, %{state | cash: state.cash + amount}}

  def handle_call({:withdraw, amount}, _from, state) do
    if state.cash >= amount do
      {:reply, :ok, %{state | cash: state.cash - amount}}
    else
      {:reply, :insufficient_cash, state}
    end
  end

  def handle_call({:buy_aapl, shares}, _from, state), do: buy(state, :aapl, shares, @aapl_price)
  def handle_call({:sell_aapl, shares}, _from, state), do: sell(state, :aapl, shares, @aapl_price)
  def handle_call({:buy_msft, shares}, _from, state), do: buy(state, :msft, shares, @msft_price)
  def handle_call({:sell_msft, shares}, _from, state), do: sell(state, :msft, shares, @msft_price)

  def handle_call(:rebalance, _from, state) do
    total = value(state)
    target_equities = div(total * 80, 100)
    target_aapl = div(target_equities * 60, 100)
    target_msft = target_equities - target_aapl
    aapl = div(target_aapl, @aapl_price)
    msft = div(target_msft, @msft_price)
    cash = total - aapl * @aapl_price - msft * @msft_price
    {:reply, :ok, %{state | cash: cash, aapl: aapl, msft: msft}}
  end

  def value(state), do: state.cash + state.aapl * @aapl_price + state.msft * @msft_price

  defp buy(state, ticker, shares, price) do
    cost = shares * price

    if shares > 0 and state.cash >= cost do
      {:reply, :ok, state |> Map.update!(:cash, &(&1 - cost)) |> Map.update!(ticker, &(&1 + shares))}
    else
      {:reply, :rejected, state}
    end
  end

  defp sell(state, ticker, shares, price) do
    current = Map.fetch!(state, ticker)

    if shares > 0 and current >= shares do
      {:reply, :ok, state |> Map.update!(:cash, &(&1 + shares * price)) |> Map.update!(ticker, &(&1 - shares))}
    else
      {:reply, :rejected, state}
    end
  end
end

defmodule PortfolioAbi do
  def next_cash(cash, aapl, msft, event, amount), do: transition(cash, aapl, msft, event, amount).cash
  def next_aapl(cash, aapl, msft, event, amount), do: transition(cash, aapl, msft, event, amount).aapl
  def next_msft(cash, aapl, msft, event, amount), do: transition(cash, aapl, msft, event, amount).msft
  def value(cash, aapl, msft), do: PortfolioServer.value(%{cash: cash, aapl: aapl, msft: msft})

  defp transition(cash, aapl, msft, event, amount) do
    state = %{cash: cash, aapl: aapl, msft: msft}
    {:reply, _reply, next} = PortfolioServer.handle_call(event(event, amount), nil, state)
    next
  end

  defp event(1, amount), do: {:deposit, amount}
  defp event(2, amount), do: {:withdraw, amount}
  defp event(3, amount), do: {:buy_aapl, amount}
  defp event(4, amount), do: {:sell_aapl, amount}
  defp event(5, amount), do: {:buy_msft, amount}
  defp event(6, amount), do: {:sell_msft, amount}
  defp event(7, _amount), do: :rebalance
end
`;

mkdirSync(build, { recursive: true });
writeFileSync(resolve(build, "portfolio.ex"), source);
execFileSync("elixirc", ["-o", build, resolve(build, "portfolio.ex")], { stdio: "inherit" });

const env = { ...process.env, STUB: "1", EXPORTS: "next_cash:int,int,int,int,int->int;next_aapl:int,int,int,int,int->int;next_msft:int,int,int,int,int->int;value:int,int,int->int" };
const wat = execFileSync("elixir", [compiler, resolve(build, "Elixir.PortfolioAbi.beam"), resolve(build, "Elixir.PortfolioServer.beam")], { env });
writeFileSync(resolve(build, "portfolio.wat"), wat);
execFileSync("wasm-as", [resolve(build, "portfolio.wat"), "-o", resolve(build, "portfolio.wasm"), "-all"], { stdio: "inherit" });

const dest = resolve(project, "src", "portfolio.wasm");
copyFileSync(resolve(build, "portfolio.wasm"), dest);
console.log(`Wrote ${dest}`);
