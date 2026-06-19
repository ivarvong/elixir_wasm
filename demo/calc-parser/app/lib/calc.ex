defmodule Calc do
  @moduledoc """
  A recursive-descent arithmetic expression parser, built on the real unmodified
  `nimble_parsec` combinator library, with operator precedence, parentheses, and
  left-associative AST construction — entirely pure Elixir.

  One `bin -> bin` entry point (`parse/1`) serves the VM, `run.exs`, and a Worker:
  it takes an expression string and returns the AST as JSON.

      "1+2*3"   -> {"ok": ["+", 1, ["*", 2, 3]]}
      "(1+2)*3" -> {"ok": ["*", ["+", 1, 2], 3]}
      "1+"      -> {"error": "expected ..."}

  The grammar is the classic three layers (precedence climbing):
      expr   = term   (("+" | "-") term)*
      term   = factor (("*" | "/") factor)*
      factor = integer | "(" expr ")"
  Recursion is the `parsec(:expr)` self-reference inside `factor`.
  """
  import NimbleParsec

  @doc "Parse an arithmetic expression; return the AST (or error) as JSON. The bin->bin API."
  @spec parse(binary()) :: binary()
  def parse(input) when is_binary(input) do
    case expr(input) do
      {:ok, [ast], "", _, _, _} -> Jason.encode!(%{"ok" => to_json(ast)})
      {:ok, _, rest, _, _, _} -> Jason.encode!(%{"error" => "unexpected trailing input", "at" => rest})
      {:error, msg, _, _, _, _} -> Jason.encode!(%{"error" => msg})
    end
  end

  # AST tuples {op, left, right} -> JSON arrays [op, left, right]; integers stay integers.
  defp to_json({op, l, r}), do: [op, to_json(l), to_json(r)]
  defp to_json(n) when is_integer(n), do: n

  # left-associative fold of a flat [val, op, val, op, val] list into a binary tree.
  def fold([first | rest]), do: do_fold(rest, first)
  defp do_fold([op, val | rest], acc), do: do_fold(rest, {op, acc, val})
  defp do_fold([], acc), do: acc

  defcombinatorp :factor,
    choice([integer(min: 1), ignore(string("(")) |> parsec(:expr) |> ignore(string(")"))])

  defcombinatorp :term,
    parsec(:factor)
    |> repeat(choice([string("*"), string("/")]) |> parsec(:factor))
    |> reduce({Calc, :fold, []})

  defparsec :expr,
    parsec(:term)
    |> repeat(choice([string("+"), string("-")]) |> parsec(:term))
    |> reduce({Calc, :fold, []})
end
