defmodule Ev2 do
  # idiomatic pipeline: sum of squares of evens
  def sumsq_evens(list) do
    list
    |> Enum.filter(fn x -> rem(x, 2) == 0 end)
    |> Enum.map(fn x -> x * x end)
    |> Enum.reduce(0, fn x, acc -> x + acc end)
  end
  def cnt(list), do: Enum.count(list)
  def rev(list), do: Enum.reverse(list)
  def anybig(list), do: Enum.any?(list, fn x -> x > 100 end)
  def allpos(list), do: Enum.all?(list, fn x -> x > 0 end)
  def mapsum(list), do: Enum.map(list, fn x -> x + 1 end) |> Enum.sum()
end
