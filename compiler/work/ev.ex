defmodule Ev do
  def double(list), do: Enum.map(list, fn x -> x * 2 end)
  def total(list), do: Enum.reduce(list, 0, fn x, acc -> acc + x end)
  def evens(list), do: Enum.filter(list, fn x -> rem(x, 2) == 0 end)
end
