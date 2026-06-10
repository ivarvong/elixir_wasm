defmodule Probe do
  # Staged differential probe into Earmark's pipeline: checksum each stage's data on the VM and
  # on Wasm to localize the first divergence (the LineScanner output structs feed Parser._parse).
  @md "# Why WasmGC\n\nBEAM terms are a *graph* of heap cells.\n\n- cons cells\n- tuples\n"

  def p_lines(_), do: chk(String.split(@md, ~r{\r\n?|\n}))
  def p_scan(_) do
    lines = String.split(@md, ~r{\r\n?|\n})
    opts = struct(Earmark.Parser.Options, [])
    chk(Earmark.Parser.LineScanner.scan_lines(["" | lines ++ [""]], opts, false))
  end
  def p_parse(_) do
    lines = String.split(@md, ~r{\r\n?|\n})
    opts = struct(Earmark.Parser.Options, [])
    {blocks, _links, _fn, _o} = Earmark.Parser.Parser.parse(lines, opts, false)
    chk(blocks)
  end
  def p_min(n) do
    md = case n do
      0 -> ""
      1 -> "plain text"
      2 -> "# Heading"
      3 -> "- item"
      4 -> "*emph* text"
      5 -> "text\n\nmore"
      _ -> "# H\n\ntext"
    end
    opts = struct(Earmark.Parser.Options, [])
    {blocks, _l, _f, _o} = Earmark.Parser.Parser.parse(String.split(md, ~r{\r\n?|\n}), opts, false)
    chk(blocks)
  end
  def p_ast(_) do
    {:ok, ast, _} = Earmark.Parser.as_ast(@md)
    chk(ast)
  end

  def chk(x), do: ch(x, 17)
  defp ch(x, a) when is_integer(x), do: rem(a * 131 + rem(x, 1_000_000_007) + 1_000_000_007, 1_000_000_007)
  defp ch(x, a) when is_float(x), do: ch(trunc(x * 1_000_000), a + 3)
  defp ch(true, a), do: a + 11
  defp ch(false, a), do: a + 13
  defp ch(nil, a), do: a + 19
  defp ch(x, a) when is_atom(x), do: bs(:erlang.atom_to_binary(x), a + 5)
  defp ch(x, a) when is_binary(x), do: bs(x, a + 7)
  defp ch(x, a) when is_list(x), do: Enum.reduce(x, a + 23, fn e, acc -> ch(e, acc) end)
  defp ch(x, a) when is_tuple(x), do: ch(Tuple.to_list(x), a + 29)
  defp ch(x, a) when is_map(x), do: Enum.reduce(Enum.sort_by(Map.to_list(x), fn {k, _} -> ikey(k) end), a + 31, fn {k, v}, acc -> ch(v, ch(k, acc)) end)
  defp ch(_, a), do: a + 997
  defp bs(<<>>, a), do: a
  defp bs(<<c, r::binary>>, a), do: bs(r, rem(a * 131 + c, 1_000_000_007))
  defp ikey(k) when is_integer(k), do: {0, k, ""}
  defp ikey(k) when is_atom(k), do: {1, 0, :erlang.atom_to_binary(k)}
  defp ikey(k) when is_binary(k), do: {2, 0, k}
  defp ikey(_), do: {3, 0, ""}
end
