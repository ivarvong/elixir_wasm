defmodule Smoke do
  # compile to plain (non-typed) registers so our from-scratch decoder handles it
  @compile [:no_type_opt, :no_line_info]

  def add(a, b), do: a + b
  def dbl(x), do: x * 2

  def fact(0), do: 1
  def fact(n) when n > 0, do: n * fact(n - 1)

  def fib(0), do: 0
  def fib(1), do: 1
  def fib(n) when n > 1, do: fib(n - 1) + fib(n - 2)
end
