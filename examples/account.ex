defmodule Account do
  # state = %{balance: int, status: :open | :frozen}; events drive transitions.
  def new(initial), do: %{balance: initial, status: :open}

  def step(%{status: :open, balance: b} = s, {:deposit, amt}) when amt > 0 do
    %{s | balance: b + amt}
  end
  def step(%{status: :open, balance: b} = s, {:withdraw, amt}) when amt > 0 and amt <= b do
    %{s | balance: b - amt}
  end
  def step(%{status: :open} = s, :freeze), do: %{s | status: :frozen}
  def step(%{status: :frozen} = s, :unfreeze), do: %{s | status: :open}
  def step(s, _event), do: s

  def balance(%{balance: b}), do: b

  # Drive a sequence of events; demo(x) = x + 15 (deposits/withdrawals net +15),
  # IF the status + funds guards hold (the frozen deposit/withdraw and the
  # overdraw are all ignored). Otherwise the number differs.
  def demo(x) do
    s = new(x)
    s = step(s, {:deposit, 50})
    s = step(s, {:withdraw, 30})
    s = step(s, :freeze)
    s = step(s, {:deposit, 100})
    s = step(s, {:withdraw, 5})
    s = step(s, :unfreeze)
    s = step(s, {:withdraw, 999})
    s = step(s, {:withdraw, 5})
    balance(s)
  end
end

defmodule AccountAbi do
  # Integer-in/integer-out ABI so a Durable Object host can drive transitions.
  # status: 0=open, 1=frozen.  event: 0=deposit,1=withdraw,2=freeze,3=unfreeze.
  # The state machine itself (Account.step/2, with all guards) runs unchanged.
  defp restore(b, 0), do: %{balance: b, status: :open}
  defp restore(b, 1), do: %{balance: b, status: :frozen}

  defp event(0, amt), do: {:deposit, amt}
  defp event(1, amt), do: {:withdraw, amt}
  defp event(2, _), do: :freeze
  defp event(3, _), do: :unfreeze

  defp code(%{status: :open}), do: 0
  defp code(%{status: :frozen}), do: 1

  def transition_balance(b, sc, ec, amt) do
    Account.balance(Account.step(restore(b, sc), event(ec, amt)))
  end
  def transition_status(b, sc, ec, amt) do
    code(Account.step(restore(b, sc), event(ec, amt)))
  end
end
