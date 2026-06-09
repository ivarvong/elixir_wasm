{:beam_file, _m, _e, _a, _i, fns} = :beam_disasm.file(~c"Elixir.Strix.beam")
for {:function, name, arity, entry, instrs} <- fns, name == :count do
  IO.puts("#{name}/#{arity}  ENTRY=#{entry}")
  for i <- instrs, do: IO.puts("  #{inspect(i)}")
end
