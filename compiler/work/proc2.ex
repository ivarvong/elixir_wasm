defmodule Proc2 do
  # worker pool: spawn one process per i in 1..n, each replies with i*i; parent sums.
  # exercises spawned closures that CAPTURE free vars (me, i), concurrent replies.
  def sumsq_to(n) do
    me = self()
    spawn_range(1, n, me)
    collect(n, 0)
  end
  def spawn_range(i, n, _me) when i > n, do: :ok
  def spawn_range(i, n, me) do
    spawn(fn -> send(me, {:sq, i * i}) end)
    spawn_range(i + 1, n, me)
  end
  def collect(0, acc), do: acc
  def collect(n, acc) do
    receive do
      {:sq, v} -> collect(n - 1, acc + v)
    end
  end

  # stateful counter server, multiple ordered requests from one client
  def counter do
    s = spawn(fn -> server(0) end)
    send(s, {:add, 10})
    send(s, {:add, 5})
    send(s, {:sub, 3})
    send(s, {:get, self()})
    receive do
      {:val, v} -> v
    end
  end
  def server(n) do
    receive do
      {:add, x} -> server(n + x)
      {:sub, x} -> server(n - x)
      {:get, from} -> send(from, {:val, n}); server(n)
    end
  end

  # nested spawn + multi-hop messaging
  def nested(x) do
    me = self()
    spawn(fn ->
      inner = self()
      spawn(fn -> send(inner, {:r, x * 10}) end)
      receive do
        {:r, v} -> send(me, {:final, v + 1})
      end
    end)
    receive do
      {:final, v} -> v
    end
  end
end
