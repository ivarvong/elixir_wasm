defmodule SupRestart do
  # supervise a worker that crashes the first `fail` attempts, then succeeds.
  # returns the worker's eventual result — proving crash detection + restart.
  def run(x) do
    Process.flag(:trap_exit, true)
    loop(x, 0)
  end
  def loop(x, attempt) do
    me = self()
    spawn_link(fn -> worker(me, x, attempt) end)
    receive do
      {:result, v} -> v
      {:EXIT, _pid, :normal} -> loop(x, attempt)        # ignore normal exits
      {:EXIT, _pid, _reason} -> loop(x, attempt + 1)    # crashed -> restart, count it
    end
  end
  def worker(parent, x, attempt) do
    if attempt < 2 do
      exit(:crashed)
    else
      send(parent, {:result, x * 100 + attempt})
    end
  end
end
