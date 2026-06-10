defmodule PyexWasm do
  # The WasmGC surface for the pyex Python interpreter: source in, a deterministic
  # transcript out — captured print() output plus the repr of the final value.
  def eval(source) when is_binary(source) do
    case Pyex.run(source, []) do
      {:ok, result, ctx} ->
        out = Pyex.output(ctx)
        "ok\n" <> out <> "\n=> " <> Pyex.Builtins.py_repr_quoted(result)
      {:error, %Pyex.Error{kind: kind, message: msg}} ->
        "error(" <> Atom.to_string(kind) <> ")\n" <> msg
    end
  rescue
    e -> "raise\n" <> Exception.message(e)
  end

  @doc """
  The terms-across-the-boundary surface: returns `{:ok, value, stdout}` or
  `{:error, kind, message}` as a TERM — the host walks the live WasmGC graph with the
  introspection exports (imports.mjs termToJs) and renders JSON at the last inch.
  pyex-specific shapes are normalized HERE, in compiled (differentially testable) Elixir.
  """
  def eval_value(source) when is_binary(source) do
    case Pyex.run(source, []) do
      {:ok, result, ctx} -> {:ok, normalize(result), Pyex.output(ctx)}
      {:error, %Pyex.Error{kind: kind, message: msg}} -> {:error, kind, msg}
    end
  rescue
    # wasm-safe crash path: no Exception.message/Inspect machinery in the closed world
    e -> {:error, :crash, Atom.to_string(e.__struct__)}
  end

  defp normalize(v) when is_number(v) or is_binary(v) or is_boolean(v) or is_nil(v), do: v
  defp normalize({:tuple, l}) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize({:set, %MapSet{} = ms}), do: ms |> MapSet.to_list() |> Enum.map(&normalize/1) |> Enum.sort()
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(m) when is_map(m) and not is_struct(m) do
    Map.new(m, fn {k, v} -> {normalize_key(k), normalize(v)} end)
  end
  defp normalize(other), do: Pyex.Builtins.py_repr_quoted(other)

  defp normalize_key(k) when is_binary(k), do: k
  defp normalize_key(k) when is_integer(k) or is_float(k) or is_boolean(k), do: k
  defp normalize_key(k), do: Pyex.Builtins.py_repr_quoted(k)
end
