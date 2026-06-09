defmodule Proc do
  def run do
    pid = spawn(fn -> loop(0) end)
    send(pid, {:add, 5})
    send(pid, {:add, 3})
    send(pid, {:get, self()})
    receive do
      {:result, n} -> n
    end
  end

  def loop(acc) do
    receive do
      {:add, x} -> loop(acc + x)
      {:get, from} -> send(from, {:result, acc}); loop(acc)
    end
  end
end
