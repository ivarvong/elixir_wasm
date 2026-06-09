defmodule Server do
  def start(mod, arg), do: spawn(fn -> loop(mod, mod.init(arg)) end)
  def loop(mod, state) do
    receive do
      {:call, from, req} ->
        {:reply, reply, ns} = mod.handle_call(req, from, state)
        send(from, {:reply, reply})
        loop(mod, ns)
      {:cast, req} ->
        {:noreply, ns} = mod.handle_cast(req, state)
        loop(mod, ns)
    end
  end
  def call(pid, req) do
    send(pid, {:call, self(), req})
    receive do {:reply, r} -> r end
  end
  def cast(pid, req), do: send(pid, {:cast, req})
end

defmodule Counter do
  def init(n), do: n
  def handle_call(:get, _from, state), do: {:reply, state, state}
  def handle_call({:add, x}, _from, state), do: {:reply, :ok, state + x}
  def handle_cast({:inc, x}, state), do: {:noreply, state + x}
end

defmodule GenDemo do
  def run(start) do
    s = Server.start(Counter, start)
    Server.cast(s, {:inc, 10})
    Server.call(s, {:add, 5})
    Server.cast(s, {:inc, 3})
    Server.call(s, :get)
  end
end
