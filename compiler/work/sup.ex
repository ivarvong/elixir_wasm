defmodule Sup do
  def run do
    Process.flag(:trap_exit, true)
    w = spawn_link(fn -> worker() end)
    send(w, :crash)
    receive do
      {:EXIT, _pid, reason} -> reason
    end
  end
  def worker do
    receive do
      :crash -> exit(:boom)
    end
  end
end
