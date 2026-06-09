{:beam_file, _, _, _, _, fns} = :beam_disasm.file(~c"Elixir.Hav.beam")
{:function, :dist, 4, _, code} = Enum.find(fns, &match?({:function, :dist, 4, _, _}, &1))
Enum.each(code, &IO.inspect(&1, limit: :infinity))
