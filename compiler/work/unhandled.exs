beam = System.argv() |> hd() |> String.to_charlist()
{:beam_file, _m, _e, _a, _i, fns} = :beam_disasm.file(beam)
handled = ~w(move gc_bif test get_map_elements put_map_assoc put_map_exact get_list get_hd get_tl
  put_list put_tuple2 get_tuple_element call call_only call_last call_ext call_ext_only call_ext_last
  return jump select_val select_tuple_arity swap func_info allocate allocate_zero init_yregs trim
  deallocate test_heap line int_code_end badmatch case_end if_end bs_create_bin bs_get_position
  bs_set_position bs_get_tail bs_match make_fun3 call_fun call_fun2)a |> MapSet.new()
ops = for {:function,_,_,_,is} <- fns, i <- is, into: %{} do
  op = if is_tuple(i), do: elem(i,0), else: i
  {op, 1}
end
ops |> Map.keys() |> Enum.reject(&(&1 in handled or &1 == :label)) |> Enum.sort() |> IO.inspect(limit: :infinity)
