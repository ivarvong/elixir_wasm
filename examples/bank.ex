defmodule Bank do
  # a real GenServer callback module: multi-clause handle_call with guards
  def init(b), do: b
  def handle_call(:balance, _from, b), do: {:reply, b, b}
  def handle_call({:deposit, a}, _from, b), do: {:reply, :ok, b + a}
  def handle_call({:withdraw, a}, _from, b) when a <= b, do: {:reply, :ok, b - a}
  def handle_call({:withdraw, _a}, _from, b), do: {:reply, :insufficient, b}
end

defmodule BankAbi do
  # the DO drives one GenServer step per request; events arrive as int codes
  def handle(state, 0, _amt), do: Bank.handle_call(:balance, nil, state)
  def handle(state, 1, amt), do: Bank.handle_call({:deposit, amt}, nil, state)
  def handle(state, 2, amt), do: Bank.handle_call({:withdraw, amt}, nil, state)
end
