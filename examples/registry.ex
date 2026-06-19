defmodule NamedDemo do
  # register a server under a name; interact by name (send-by-name + whereis)
  def named(start) do
    s = spawn(fn -> server(start) end)
    Process.register(s, :counter)
    send(:counter, {:add, 10})
    send(Process.whereis(:counter), {:add, 5})
    send(:counter, {:get, self()})
    receive do {:val, v} -> v end
  end
  def server(n) do
    receive do
      {:add, x} -> server(n + x)
      {:get, from} -> send(from, {:val, n}); server(n)
    end
  end

  # monitor a worker; receive {:DOWN, ...} when it dies
  def monitored(x) do
    w = spawn(fn -> :done end)
    Process.monitor(w)
    receive do
      {:DOWN, _ref, :process, _pid, _reason} -> x * 2
    end
  end
end
