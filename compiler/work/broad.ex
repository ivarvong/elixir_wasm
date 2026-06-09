defmodule Broad do
  def m(l), do: Enum.map(l, fn x -> x * 2 end)
  def f(l), do: Enum.filter(l, fn x -> rem(x, 2) == 0 end)
  def r(l), do: Enum.reduce(l, 0, fn x, a -> x + a end)
  def s(l), do: Enum.sort(l)
  def u(l), do: Enum.uniq(l)
  def mx(l), do: Enum.max(l)
  def cnt(l), do: Enum.count(l)
  def rev(l), do: Enum.reverse(l)
  def mem(l), do: Enum.member?(l, 3)
  def tk(l), do: Enum.take(l, 3)
end
