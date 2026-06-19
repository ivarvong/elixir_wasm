defmodule Target do
  def fib(0), do: 0
  def fib(1), do: 1
  def fib(n), do: fib(n - 1) + fib(n - 2)
  def sum([]), do: 0
  def sum([h | t]), do: h + sum(t)
  def upto(0), do: []
  def upto(n), do: [n | upto(n - 1)]
end
