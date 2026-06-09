beam = System.argv() |> hd() |> String.to_charlist()
{:beam_file, mod, _exp, _attr, _info, fns} = :beam_disasm.file(beam)
IO.puts("== #{mod} ==")
for {:function, name, arity, _entry, instrs} <- fns,
    name not in [:module_info, :__info__],
    not String.starts_with?(Atom.to_string(name), "-") do
  IO.puts("  -- #{name}/#{arity} --")
  for i <- instrs, do: IO.puts("    #{inspect(i, limit: :infinity)}")
end
