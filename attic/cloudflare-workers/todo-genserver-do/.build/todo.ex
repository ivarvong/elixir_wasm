
defmodule TodoServer do
  use GenServer

  def init(_), do: {:ok, %{next_id: 1, open: 0, done: 0, version: 0}}

  def handle_call(:add, _from, state), do: {:reply, :ok, %{state | next_id: state.next_id + 1, open: state.open + 1, version: state.version + 1}}

  def handle_call({:complete, false}, _from, state), do: {:reply, :ok, %{state | open: state.open - 1, done: state.done + 1, version: state.version + 1}}
  def handle_call({:complete, true}, _from, state), do: {:reply, :noop, state}

  def handle_call({:reopen, true}, _from, state), do: {:reply, :ok, %{state | open: state.open + 1, done: state.done - 1, version: state.version + 1}}
  def handle_call({:reopen, false}, _from, state), do: {:reply, :noop, state}

  def handle_call({:delete, true}, _from, state), do: {:reply, :ok, %{state | done: state.done - 1, version: state.version + 1}}
  def handle_call({:delete, false}, _from, state), do: {:reply, :ok, %{state | open: state.open - 1, version: state.version + 1}}

  def handle_call(:clear_completed, _from, state), do: {:reply, :ok, %{state | done: 0, version: state.version + 1}}
end

defmodule TodoAbi do
  def next_id(next_id, open, done, version, event, was_done), do: transition(next_id, open, done, version, event, was_done).next_id
  def next_open(next_id, open, done, version, event, was_done), do: transition(next_id, open, done, version, event, was_done).open
  def next_done(next_id, open, done, version, event, was_done), do: transition(next_id, open, done, version, event, was_done).done
  def next_version(next_id, open, done, version, event, was_done), do: transition(next_id, open, done, version, event, was_done).version

  def accepted(next_id, open, done, version, event, was_done) do
    state = %{next_id: next_id, open: open, done: done, version: version}
    {:reply, reply, _next} = TodoServer.handle_call(event(event, was_done), nil, state)
    if reply == :ok, do: 1, else: 0
  end

  defp transition(next_id, open, done, version, event, was_done) do
    state = %{next_id: next_id, open: open, done: done, version: version}
    {:reply, _reply, next} = TodoServer.handle_call(event(event, was_done), nil, state)
    next
  end

  defp event(1, _), do: :add
  defp event(2, 0), do: {:complete, false}
  defp event(2, _), do: {:complete, true}
  defp event(3, 0), do: {:reopen, false}
  defp event(3, _), do: {:reopen, true}
  defp event(4, 0), do: {:delete, false}
  defp event(4, _), do: {:delete, true}
  defp event(5, _), do: :clear_completed
end
