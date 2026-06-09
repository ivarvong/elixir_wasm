defmodule CapPure do
  def adder(n), do: fn x -> x + n end
  def use_adder(n, x), do: adder(n).(x)
  def make_mul(k), do: fn x -> x * k end
  def compose(f, g), do: fn x -> f.(g.(x)) end          # captures two closures
  def add_then_double(n, x), do: compose(make_mul(2), adder(n)).(x)   # (x+n)*2
end
