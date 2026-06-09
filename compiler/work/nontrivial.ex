# (A) Higher-order functions with closures — self-contained, no stdlib
defmodule Hof do
  def map([], _f), do: []
  def map([h | t], f), do: [f.(h) | map(t, f)]
  def reduce([], acc, _f), do: acc
  def reduce([h | t], acc, f), do: reduce(t, f.(acc, h), f)
  def double(list), do: map(list, fn x -> x * 2 end)
  def sum(list), do: reduce(list, 0, fn a, b -> a + b end)
  def apply_twice(f, x), do: f.(f.(x))
end

# (B) Idiomatic Elixir leaning on the stdlib
defmodule Idiom do
  def double(list), do: Enum.map(list, fn x -> x * 2 end)
  def total(list), do: Enum.reduce(list, 0, &+/2)
  def words(text), do: text |> String.split() |> Enum.count()
end
