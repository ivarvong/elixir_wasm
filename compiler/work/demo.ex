defmodule Demo do
  def fib(n), do: Interp.run(Prog.code(), :fib, 1, [n])
  def sum(list), do: Interp.run(Prog.code(), :sum, 1, [list])
  def upto(n), do: Interp.run(Prog.code(), :upto, 1, [n])
end
