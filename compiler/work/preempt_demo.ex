defmodule PreemptDemo do
  # spawn a CPU-bound worker with NO receive; it can only be interrupted by preemption.
  def run(n) do
    me = self()
    spawn(fn -> send(me, {:done, spin(n)}) end)
    receive do {:done, v} -> v end
  end
  def spin(0), do: 7
  def spin(n), do: spin(n - 1)   # n reductions, returns 7 (no overflow)
end
