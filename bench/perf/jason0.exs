# Minimal JSON (encode + decode) shared by the perf harnesses — avoids a dep.
defmodule Jason0 do
  def encode(v), do: enc(v)
  defp enc(i) when is_integer(i), do: Integer.to_string(i)
  defp enc(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 6)
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(nil), do: "null"
  defp enc(s) when is_binary(s), do: ~s(") <> String.replace(s, ~s("), ~s(\\")) <> ~s(")
  defp enc(a) when is_atom(a), do: enc(Atom.to_string(a))
  defp enc(l) when is_list(l), do: "[" <> Enum.map_join(l, ",", &enc/1) <> "]"
  defp enc(m) when is_map(m), do: "{" <> Enum.map_join(m, ",", fn {k, v} -> enc(to_string(k)) <> ":" <> enc(v) end) <> "}"

  def decode(s), do: elem(val(skip(s)), 0)
  defp skip(<<c, r::binary>>) when c in [?\s, ?\n, ?\t, ?\r], do: skip(r)
  defp skip(s), do: s
  defp val(<<"true", r::binary>>), do: {true, r}
  defp val(<<"false", r::binary>>), do: {false, r}
  defp val(<<"null", r::binary>>), do: {nil, r}
  defp val(<<?", r::binary>>), do: str(r, "")
  defp val(<<?[, r::binary>>), do: arr(skip(r), [])
  defp val(<<?{, r::binary>>), do: obj(skip(r), %{})
  defp val(s), do: num(s, "")
  defp str(<<?\\, c, r::binary>>, acc), do: str(r, acc <> <<c>>)
  defp str(<<?", r::binary>>, acc), do: {acc, r}
  defp str(<<c, r::binary>>, acc), do: str(r, acc <> <<c>>)
  defp num(<<c, r::binary>>, acc) when c in ?0..?9 or c in [?-, ?+, ?., ?e, ?E], do: num(r, acc <> <<c>>)
  defp num(s, acc) do
    n = if String.contains?(acc, [".", "e", "E"]), do: String.to_float(acc), else: String.to_integer(acc)
    {n, s}
  end
  defp arr(<<?], r::binary>>, acc), do: {Enum.reverse(acc), r}
  defp arr(s, acc) do
    {v, r} = val(s)
    case skip(r) do
      <<?,, r2::binary>> -> arr(skip(r2), [v | acc])
      <<?], r2::binary>> -> {Enum.reverse([v | acc]), r2}
    end
  end
  defp obj(<<?}, r::binary>>, acc), do: {acc, r}
  defp obj(s, acc) do
    {k, r} = val(s)
    <<?:, r2::binary>> = skip(r)
    {v, r3} = val(skip(r2))
    case skip(r3) do
      <<?,, r4::binary>> -> obj(skip(r4), Map.put(acc, k, v))
      <<?}, r4::binary>> -> {Map.put(acc, k, v), r4}
    end
  end
end

