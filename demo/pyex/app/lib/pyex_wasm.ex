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
end
