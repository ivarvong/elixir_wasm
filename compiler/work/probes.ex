defmodule Arith do
  import Bitwise
  def idiv(a, b), do: div(a, b)
  def irem(a, b), do: rem(a, b)
  def band2(a, b), do: a &&& b
  def bor2(a, b), do: a ||| b
  def bxor2(a, b), do: bxor(a, b)
  def shl(a, b), do: a <<< b
  def shr(a, b), do: a >>> b
  def neg(a), do: -a
end

defmodule Guards do
  def t(x) when is_integer(x), do: :int
  def t(x) when is_atom(x), do: :atom
  def t(x) when is_list(x), do: :list
  def t(x) when is_binary(x), do: :binary
  def t(x) when is_tuple(x), do: :tuple
  def t(x) when is_map(x), do: :map
  def t(_), do: :other
end

defmodule Str do
  def greet(name), do: "Hello, " <> name <> "!"
  def sz(b), do: byte_size(b)
end

defmodule BinMatch do
  def first_byte(<<b, _rest::binary>>), do: b
  def starts_ok(<<"ok", _::binary>>), do: true
  def starts_ok(_), do: false
end
