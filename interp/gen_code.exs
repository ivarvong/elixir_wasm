# Decode a .beam into a list-based code table and emit it as `Prog.code/0` (a constant term
# the interpreter walks). This is the "load any .beam as data" step — done at build time here,
# but it is just data; nothing about the target is AOT-compiled.
#   elixir gen_code.exs Elixir.Target.beam  > prog.ex
[beam] = System.argv()
{:beam_file, _mod, _exp, _attr, _info, fns} = :beam_disasm.file(String.to_charlist(beam))

skip = ~w(module_info __info__)a

# {:tr, reg, _type} -> reg ; recurse through tuples/lists to drop typed-register annotations
strip = fn s, term ->
  case term do
    {:tr, reg, _t} -> s.(s, reg)
    t when is_tuple(t) -> t |> Tuple.to_list() |> Enum.map(&s.(s, &1)) |> List.to_tuple()
    l when is_list(l) -> Enum.map(l, &s.(s, &1))
    other -> other
  end
end

# split a function's instruction stream into {label, [instr]} blocks
partition = fn instrs ->
  {blocks, cur} =
    Enum.reduce(instrs, {[], nil}, fn
      {:label, l}, {bs, c} -> {if(c, do: [c | bs], else: bs), {l, []}}
      _i, {bs, nil} -> {bs, nil}
      i, {bs, {l, ops}} -> {bs, {l, [i | ops]}}
    end)
  blocks = if cur, do: [cur | blocks], else: blocks
  blocks |> Enum.reverse() |> Enum.map(fn {l, ops} -> {l, Enum.reverse(ops)} end)
end

code =
  for {:function, name, arity, entry, instrs} <- fns,
      name not in skip,
      not String.starts_with?(Atom.to_string(name), "-") do
    stripped = strip.(strip, instrs)
    {name, arity, entry, partition.(stripped)}
  end

IO.puts("defmodule Prog do")
IO.puts("  def code, do: #{inspect(code, limit: :infinity)}")
IO.puts("end")
