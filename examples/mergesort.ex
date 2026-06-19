defmodule Sort do
  def sort([]), do: []
  def sort([x]), do: [x]
  def sort(list) do
    {a, b} = split(list, [], [])
    merge(sort(a), sort(b))
  end

  def split([], a, b), do: {a, b}
  def split([x], a, b), do: {[x | a], b}
  def split([x, y | rest], a, b), do: split(rest, [x | a], [y | b])

  def merge([], ys), do: ys
  def merge(xs, []), do: xs
  def merge([x | xs], [y | ys]) when x <= y, do: [x | merge(xs, [y | ys])]
  def merge([x | xs], [y | ys]), do: [y | merge([x | xs], ys)]
end
