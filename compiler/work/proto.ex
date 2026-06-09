defmodule Proto do
  def rsum(n), do: Enum.sum(1..n)          # Range -> Enumerable protocol dispatch
  def rmap_sum(n), do: 1..n |> Enum.map(fn x -> x * x end) |> Enum.sum()
end
