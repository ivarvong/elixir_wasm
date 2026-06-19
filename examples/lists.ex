defmodule Lists do
  @compile [:no_type_opt, :no_line_info]
  def upto(0), do: []
  def upto(n), do: [n | upto(n - 1)]
  def sum([]), do: 0
  def sum([h | t]), do: h + sum(t)
  def sumto(n), do: sum(upto(n))
end
