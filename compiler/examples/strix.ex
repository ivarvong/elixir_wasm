defmodule Strix do
  # count occurrences of byte c while walking the binary recursively
  def count(<<c, rest::binary>>, c, acc), do: count(rest, c, acc + 1)
  def count(<<_, rest::binary>>, c, acc), do: count(rest, c, acc)
  def count(<<>>, _c, acc), do: acc

  # uppercase ASCII a-z by rebuilding the binary (construction + integer segment + guard)
  def upcase(<<c, rest::binary>>) when c >= ?a and c <= ?z, do: <<c - 32>> <> upcase(rest)
  def upcase(<<c, rest::binary>>), do: <<c>> <> upcase(rest)
  def upcase(<<>>), do: ""

  # length by recursion (exercises <<>> base case + tail)
  def len(<<_, rest::binary>>, acc), do: len(rest, acc + 1)
  def len(<<>>, acc), do: acc
end
