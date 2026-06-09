defmodule Exc do
  # value-class throw caught
  def catch_throw(x) do
    try do
      if x > 0, do: throw(x * 10), else: x
    catch
      v -> v + 1
    end
  end

  # catch dispatching on the exception class (throw vs error)
  def cclass(x) do
    try do
      cond do
        x == 1 -> throw(7)
        x == 2 -> :erlang.error(9)
        true -> 0
      end
    catch
      :throw, v -> 1000 + v
      :error, v -> 2000 + v
    end
  end

  # nested try: inner catches only :error, so a :throw propagates to the outer catch
  def nested(x) do
    try do
      try do
        throw(x)
      catch
        :error, _ -> 1
      end
    catch
      :throw, v -> v * 2
    end
  end
end
