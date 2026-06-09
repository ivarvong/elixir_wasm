defmodule Interp do
  # A tiny BEAM interpreter, written in Elixir, AOT-compiled by beam2wasm and run on the
  # runtime. It executes any function in `code` — data we did NOT AOT-compile. Self-contained:
  # only lists/tuples/recursion/pattern-matching (no Map/stdlib), so it compiles natively.
  #
  # code  : list of {fname, arity, entry_label, blocks}
  # blocks: list of {label, [instr]}
  # regs  : {xs, ys}  — two lists of terms (X and Y registers)

  def run(code, f, a, args) do
    {entry, blocks} = lookup(code, f, a)
    exec(block(blocks, entry), code, blocks, pad(args, 8), zeros(8))
  end

  defp exec([instr | rest], code, blocks, xs, ys) do
    case instr do
      {:move, src, dst} ->
        {xs2, ys2} = setop(dst, getop(src, xs, ys), xs, ys)
        exec(rest, code, blocks, xs2, ys2)

      {:gc_bif, op, _f, _l, [a, b], dst} ->
        {xs2, ys2} = setop(dst, arith(op, getop(a, xs, ys), getop(b, xs, ys)), xs, ys)
        exec(rest, code, blocks, xs2, ys2)

      {:select_val, src, {:f, deflbl}, {:list, pairs}} ->
        exec(block(blocks, select(getop(src, xs, ys), pairs, deflbl)), code, blocks, xs, ys)

      {:test, :is_nonempty_list, {:f, l}, [s]} ->
        if cons?(getop(s, xs, ys)),
          do: exec(rest, code, blocks, xs, ys),
          else: exec(block(blocks, l), code, blocks, xs, ys)

      {:test, :is_nil, {:f, l}, [s]} ->
        if getop(s, xs, ys) == [],
          do: exec(rest, code, blocks, xs, ys),
          else: exec(block(blocks, l), code, blocks, xs, ys)

      {:test, :is_eq_exact, {:f, l}, [a, b]} ->
        if getop(a, xs, ys) === getop(b, xs, ys),
          do: exec(rest, code, blocks, xs, ys),
          else: exec(block(blocks, l), code, blocks, xs, ys)

      {:test, :is_lt, {:f, l}, [a, b]} ->
        if getop(a, xs, ys) < getop(b, xs, ys),
          do: exec(rest, code, blocks, xs, ys),
          else: exec(block(blocks, l), code, blocks, xs, ys)

      {:test, :is_ge, {:f, l}, [a, b]} ->
        if getop(a, xs, ys) >= getop(b, xs, ys),
          do: exec(rest, code, blocks, xs, ys),
          else: exec(block(blocks, l), code, blocks, xs, ys)

      {:get_list, src, h, t} ->
        c = getop(src, xs, ys)
        {xs1, ys1} = setop(h, hdof(c), xs, ys)
        {xs2, ys2} = setop(t, tlof(c), xs1, ys1)
        exec(rest, code, blocks, xs2, ys2)

      {:put_list, h, t, dst} ->
        {xs2, ys2} = setop(dst, [getop(h, xs, ys) | getop(t, xs, ys)], xs, ys)
        exec(rest, code, blocks, xs2, ys2)

      {:call, _, {_, f, a}} ->
        {xs2, ys2} = setop({:x, 0}, run(code, f, a, take(xs, a)), xs, ys)
        exec(rest, code, blocks, xs2, ys2)

      {:call_only, _, {_, f, a}} -> run(code, f, a, take(xs, a))
      {:call_last, _, {_, f, a}, _} -> run(code, f, a, take(xs, a))
      {:jump, {:f, l}} -> exec(block(blocks, l), code, blocks, xs, ys)
      :return -> getop({:x, 0}, xs, ys)
      {:label, _} -> exec(rest, code, blocks, xs, ys)
      _ -> exec(rest, code, blocks, xs, ys)   # allocate/deallocate/init_yregs/test_heap/line: no-ops
    end
  end

  defp exec([], _code, _blocks, xs, _ys), do: getop({:x, 0}, xs, [])

  # ---- operands ----
  defp getop({:x, n}, xs, _ys), do: nth(xs, n)
  defp getop({:y, n}, _xs, ys), do: nth(ys, n)
  defp getop({:integer, n}, _xs, _ys), do: n
  defp getop({:atom, a}, _xs, _ys), do: a
  defp getop({:literal, l}, _xs, _ys), do: l
  defp getop(nil, _xs, _ys), do: []
  defp getop([], _xs, _ys), do: []
  defp getop(n, _xs, _ys) when is_integer(n), do: n

  defp setop({:x, n}, v, xs, ys), do: {setnth(xs, n, v), ys}
  defp setop({:y, n}, v, xs, ys), do: {xs, setnth(ys, n, v)}

  defp arith(:+, a, b), do: a + b
  defp arith(:-, a, b), do: a - b
  defp arith(:*, a, b), do: a * b

  defp select(_v, [], deflbl), do: deflbl
  defp select(v, [{:integer, x}, {:f, l} | rest], deflbl) do
    if v === x, do: l, else: select(v, rest, deflbl)
  end

  # ---- structures ----
  defp lookup([{f, a, entry, blocks} | _rest], f, a), do: {entry, blocks}
  defp lookup([_h | t], f, a), do: lookup(t, f, a)

  defp block([{l, instrs} | _rest], l), do: instrs
  defp block([_h | t], l), do: block(t, l)

  defp cons?([_ | _]), do: true
  defp cons?(_), do: false
  defp hdof([h | _]), do: h
  defp tlof([_ | t]), do: t

  defp nth([h | _], 0), do: h
  defp nth([_ | t], n), do: nth(t, n - 1)
  defp setnth([_ | t], 0, v), do: [v | t]
  defp setnth([h | t], n, v), do: [h | setnth(t, n - 1, v)]

  defp take(_xs, 0), do: []
  defp take([h | t], n), do: [h | take(t, n - 1)]

  defp pad(_xs, 0), do: []
  defp pad([h | t], n), do: [h | pad(t, n - 1)]
  defp pad([], n), do: [0 | pad([], n - 1)]

  defp zeros(0), do: []
  defp zeros(n), do: [0 | zeros(n - 1)]
end
