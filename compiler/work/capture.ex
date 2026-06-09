defmodule Cap do
  def adder(n), do: fn x -> x + n end        # captures n (1 free var, 1 arg)
  def use_adder(n, x), do: adder(n).(x)
  def scale_all(list, k), do: Enum.map(list, fn x -> x * k end)  # captures k
end
