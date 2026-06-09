defmodule SeedEnum do
  def a(l), do: Enum.map(l, fn x -> x+1 end)
  def b(l), do: Enum.reduce(l, 0, &+/2)
  def c(t), do: String.split(t)
end
