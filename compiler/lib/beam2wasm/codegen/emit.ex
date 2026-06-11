# Beam2Wasm.Codegen.Emit — the per-function BEAM->WAT emit path: compile_fun/2 (the opcode case), value/operand
# renderers, arith/comparison/bitstring/map/const helpers, and instruction pre-processing. Extracted from
# beam2wasm.ex (defp -> def); imports Beam2Wasm.Codegen.Common. Independent of the WAT runtime library.
defmodule Beam2Wasm.Codegen.Emit do
  @moduledoc false

  import Beam2Wasm.Codegen.Common

  def stub_function(mod, name, arity) do
    Process.put(:stubs, (Process.get(:stubs) || 0) + 1)
    cl = Process.get(:closures, %{}) |> Map.get({mod, name, arity})

    if cl && not cl.dual do
      n = cl.n
      ps = if n == 0, do: "", else: " " <> Enum.map_join(0..(n - 1), " ", &"(param $x#{&1} (ref null eq))")

      "  (func #{fq(mod, name, arity)} (type $clos#{n}) (param $self (ref null eq))#{ps} (result (ref null eq)) (unreachable)) ;; STUB fn"
    else
      ps =
        if arity == 0,
          do: "",
          else: " " <> Enum.map_join(0..(arity - 1), " ", &"(param $x#{&1} (ref null eq))")

      "  (func #{fq(mod, name, arity)}#{ps} (result (ref null eq)) (unreachable)) ;; STUB fn"
    end
  end

  # ---- per-function compilation ----
  def compile_fun(mod, {:function, name, arity, entry, instrs}) do
    blocks = partition(instrs) |> Enum.map(fn {l, ops} -> {l, resolve_trims(ops)} end)
    # ── TRMC (tail recursion modulo cons): `[H | rec(T)]` self-recursion becomes a loop that
    # allocates the cons with a HOLE for the tail and patches it next iteration — bounded stack
    # for the list-building recursion that dominates real programs (lists:map, Enum list paths,
    # lexers). The brief tail mutation is never observable: each hole is patched exactly once
    # before the list escapes. Self TAIL calls in a TRMC function re-enter the dispatch loop
    # (the chain lives in locals); cross-function tail calls are demoted to call+epilogue so
    # the patch always runs (see demote_tails).
    {blocks, trmc?} = trmc_rewrite(blocks, {mod, name, arity})
    blocks = if Process.get(:bignum) and Process.get(:fuse, true), do: i64fuse_blocks(blocks), else: blocks
    fimax = i64fused_max_node(blocks)
    idx = blocks |> Enum.with_index() |> Map.new(fn {{l, _}, i} -> {l, i} end)
    entry_idx = Map.fetch!(idx, entry)
    n = length(blocks)
    {maxx0, maxy} = max_regs(Enum.flat_map(blocks, fn {_l, o} -> o end), arity)
    # A function containing try/try_case lowers onto a Wasm `try_table` wrapping its
    # whole dispatch loop. The catch handler stages class/reason/trace into x0/x1/x2,
    # so those three registers must exist even when arity < 3.
    has_try =
      Enum.any?(blocks, fn {_l, ops} ->
        Enum.any?(ops, fn op ->
          match?({:try, _, _}, op) or match?({:try_case, _}, op) or
            match?({:catch, _, _}, op) or match?({:catch_end, _}, op)
        end)
      end)

    # Calls land their result implicitly in x0; a 0-arity function whose only use of x0 is as a
    # call result (e.g. `def f, do: g() |> h()`) never names {:x,0} as an operand, so max_regs
    # misses it. Ensure x0 exists whenever the body makes any call (for arity>0, x0 is a param).
    has_call? =
      Enum.any?(blocks, fn {_l, ops} ->
        Enum.any?(ops, fn op ->
          match?({:call, _, _}, op) or match?({:call_only, _, _}, op) or
            match?({:call_last, _, _, _}, op) or match?({:call_ext, _, _}, op) or
            match?({:call_ext_only, _, _}, op) or match?({:call_ext_last, _, _, _}, op) or
            match?({:call_fun, _}, op) or match?({:call_fun2, _, _, _}, op) or
            match?({:apply, _}, op) or match?({:apply_last, _, _}, op)
        end)
      end)

    maxx0 = if arity == 0 and has_call?, do: max(maxx0, 0), else: maxx0
    maxx = if has_try, do: max(maxx0, 2), else: maxx0
    # f64 float registers ($fr0..$frN): highest {:fr, n} referenced anywhere in the function.
    maxfr =
      blocks
      |> Enum.flat_map(fn {_l, o} -> o end)
      |> Enum.flat_map(&fr_indices/1)
      |> Enum.max(fn -> -1 end)

    fn_name = fq(mod, name, arity)

    blk = fn l -> Map.fetch!(idx, l) end
    jump = fn l -> "(local.set $blk (i32.const #{blk.(l)})) (br $dispatch)" end
    # reduction accounting for loop re-entries that bypass the function header (TRMC)
    reds_check = fn ->
      case Process.get(:reds) do
        nil ->
          []

        b ->
          [
            "(global.set $reds (i32.sub (global.get $reds) (i32.const 1)))",
            "(if (i32.le_s (global.get $reds) (i32.const 0)) (then (call $yield) (global.set $reds (i32.const #{b}))))"
          ]
      end
    end

    _ = reds_check
    val = &operand/1
    i32v = &i32val/1
    set = fn {t, k}, e -> "(local.set $#{t}#{k} #{e})" end
    cargs = fn a -> if a == 0, do: "", else: Enum.map_join(0..(a - 1), " ", &"(local.get $x#{&1})") end
    # a float-register read (f64)
    frval = fn {:fr, k} -> "(local.get $fr#{k})" end
    # spawn_opt/{4,5}: M/F/A/Opts at x[o..o+3] (o=1 skips Node for /5). link/monitor from Opts.
    spawn_opt_expr = fn ar ->
      o = if ar == 4, do: 0, else: 1
      opts = "(local.get $x#{o + 3})"

      "(block (result (ref null eq)) (local.set $midx (call $spawn_opt_raw (local.get $x#{o}) (local.get $x#{o + 1}) (local.get $x#{o + 2}) (call $list_has_atom #{opts} (global.get $atom_link)))) (if (result (ref null eq)) (call $list_has_atom #{opts} (global.get $atom_monitor)) (then (array.new_fixed $tuple 2 (struct.new $pid (local.get $midx)) (struct.new $ref (call $monitor_raw (local.get $midx)) (i32.const 0)))) (else (struct.new $pid (local.get $midx)))))"
    end

    emit = fn op ->
      case op do
        {:move, s, d} ->
          {[set.(d, val.(s))], false}

        {:gc_bif, o, _f, _l, [a1, a2], d} ->
          ab = if o in [:+, :-, :*], do: arith_bounds(o, a1, a2), else: nil

          e =
            cond do
              # SPECIALIZED: result provably fits i31 -> inline i32, no helper call / no box (i31 immediate).
              ab != nil and fits_i31?(ab) ->
                "(ref.i31 (i32.#{wasmop(o)} #{i32val(a1)} #{i32val(a2)}))"

              # SPECIALIZED: both operands proven integer (not float) -> the int helper directly, skipping
              # the float-capable $num_ path's runtime float test.
              Process.get(:bignum) and o in [:+, :-, :*] and int_typed?(a1) and int_typed?(a2) ->
                "(call $int_#{bif(o)} #{val.(a1)} #{val.(a2)})"

              Process.get(:float) and o in [:+, :-, :*] ->
                "(call $num_#{bif(o)} #{val.(a1)} #{val.(a2)})"

              Process.get(:bignum) and o in [:+, :-, :*, :div, :rem] ->
                "(call $int_#{bif(o)} #{val.(a1)} #{val.(a2)})"

              # bitwise: in bignum mode route through the tiered helper (i31 fast path + arbitrary-
              # precision host fallback), so boxed operands don't `illegal cast` and results don't
              # silently truncate at 31 bits (e.g. `1 bsl 40`). Otherwise the i64 fast path.
              Process.get(:bignum) and o in [:band, :bor, :bxor, :bsl, :bsr] ->
                "(call $int_#{o} #{val.(a1)} #{val.(a2)})"

              o in [:band, :bor, :bxor, :bsl, :bsr] ->
                "(ref.i31 (i32.wrap_i64 (i64.#{wasmop(o)} #{i64val(a1)} #{i64val(a2)})))"

              true ->
                "(ref.i31 (i32.#{wasmop(o)} #{i32v.(a1)} #{i32v.(a2)}))"
            end

          {[set.(d, e)], false}

        {:gc_bif, :-, _f, _l, [a], d} ->
          # unary minus must stay float-capable in float mode (dynamic code negates floats:
          # an interpreter's USub on -118.4085 reaches here with a $float operand)
          e =
            cond do
              Process.get(:float) -> "(call $num_sub (ref.i31 (i32.const 0)) #{val.(a)})"
              Process.get(:bignum) -> "(call $int_sub (ref.i31 (i32.const 0)) #{val.(a)})"
              true -> "(ref.i31 (i32.sub (i32.const 0) #{i32v.(a)}))"
            end

          {[set.(d, e)], false}

        {:gc_bif, :+, _f, _l, [a], d} ->
          {[set.(d, val.(a))], false}

        # comparison bifs used as VALUES (not tests) -> the atom true/false
        {:bif, op, _f, [a, b], d} when op in [:"=:=", :==, :"=/=", :"/=", :<, :>, :>=, :"=<"] ->
          {[
             set.(
               d,
               "(if (result (ref null eq)) #{bool_cmp(op, a, b)} (then (global.get $atom_true)) (else (global.get $atom_false)))"
             )
           ], false}

        {:gc_bif, :length, _f, _l, [a], d} ->
          {[set.(d, "(ref.i31 (call $list_len #{val.(a)}))")], false}

        # abs / min / max — integer fast path (general term ordering is a TODO)
        {gop, :abs, _f, _l, [a], d} when gop in [:gc_bif, :bif] ->
          x = i32v.(a)

          e =
            cond do
              # float mode: dynamic code calls abs/1 on floats — the tier-aware helper
              Process.get(:float) ->
                "(call $num_abs #{val.(a)})"

              Process.get(:bignum) ->
                "(if (result (ref null eq)) (i32.lt_s (call $int_cmp #{val.(a)} (ref.i31 (i32.const 0))) (i32.const 0)) (then (call $int_sub (ref.i31 (i32.const 0)) #{val.(a)})) (else #{val.(a)}))"

              true ->
                "(ref.i31 (select (i32.sub (i32.const 0) #{x}) #{x} (i32.lt_s #{x} (i32.const 0))))"
            end

          {[set.(d, e)], false}

        {:bif, :abs, _f, [a], d} ->
          x = i32v.(a)

          e =
            cond do
              Process.get(:float) ->
                "(call $num_abs #{val.(a)})"

              Process.get(:bignum) ->
                "(if (result (ref null eq)) (i32.lt_s (call $int_cmp #{val.(a)} (ref.i31 (i32.const 0))) (i32.const 0)) (then (call $int_sub (ref.i31 (i32.const 0)) #{val.(a)})) (else #{val.(a)}))"

              true ->
                "(ref.i31 (select (i32.sub (i32.const 0) #{x}) #{x} (i32.lt_s #{x} (i32.const 0))))"
            end

          {[set.(d, e)], false}

        {gop, mm, _f, _l, [a, b], d} when gop in [:gc_bif, :bif] and mm in [:min, :max] ->
          x = i32v.(a)
          y = i32v.(b)
          c = if mm == :min, do: "i32.lt_s", else: "i32.gt_s"

          e =
            if Process.get(:bignum),
              do:
                "(if (result (ref null eq)) (#{if mm == :min, do: "i32.lt_s", else: "i32.gt_s"} (call $int_cmp #{val.(a)} #{val.(b)}) (i32.const 0)) (then #{val.(a)}) (else #{val.(b)}))",
              else: "(ref.i31 (select #{x} #{y} (#{c} #{x} #{y})))"

          {[set.(d, e)], false}

        {:bif, mm, _f, [a, b], d} when mm in [:min, :max] ->
          x = i32v.(a)
          y = i32v.(b)
          c = if mm == :min, do: "i32.lt_s", else: "i32.gt_s"

          e =
            if Process.get(:bignum),
              do:
                "(if (result (ref null eq)) (#{if mm == :min, do: "i32.lt_s", else: "i32.gt_s"} (call $int_cmp #{val.(a)} #{val.(b)}) (i32.const 0)) (then #{val.(a)}) (else #{val.(b)}))",
              else: "(ref.i31 (select #{x} #{y} (#{c} #{x} #{y})))"

          {[set.(d, e)], false}

        {:gc_bif, :hd, _f, _l, [a], d} ->
          {[set.(d, "(struct.get $cons 0 (ref.cast (ref $cons) #{val.(a)}))")], false}

        {:gc_bif, :tl, _f, _l, [a], d} ->
          {[set.(d, "(struct.get $cons 1 (ref.cast (ref $cons) #{val.(a)}))")], false}

        {:bif, :hd, _f, [a], d} ->
          {[set.(d, "(struct.get $cons 0 (ref.cast (ref $cons) #{val.(a)}))")], false}

        {:bif, :tl, _f, [a], d} ->
          {[set.(d, "(struct.get $cons 1 (ref.cast (ref $cons) #{val.(a)}))")], false}

        {:gc_bif, :map_size, _f, _l, [a], d} ->
          {[set.(d, "(ref.i31 (call $map_size #{val.(a)}))")], false}

        {:bif, :map_get, {:f, f}, [key, m], d} when f != 0 ->
          # GUARD context (e.g. `rescue ArithmeticError` testing map_get(:__struct__, reason) on an
          # atom reason): a non-map subject or missing key FAILS the guard — it must never trap.
          {[
             "(if (i32.eqz (ref.test (ref $map) #{val.(m)})) (then #{jump.(f)}))",
             "(local.set $mn (call $map_get #{val.(m)} #{val.(key)}))",
             "(if (ref.is_null (local.get $mn)) (then #{jump.(f)}))",
             set.(d, "(struct.get $mnode 1 (ref.as_non_null (local.get $mn)))")
           ], false}

        {:bif, :map_get, _f, [key, m], d} ->
          {[
             "(local.set $mn (call $map_get #{val.(m)} #{val.(key)}))",
             set.(d, "(struct.get $mnode 1 (ref.as_non_null (local.get $mn)))")
           ], false}

        {:bif, :is_map_key, _f, [key, m], d} ->
          {[
             set.(
               d,
               "(if (result (ref null eq)) (call $map_has #{val.(m)} #{val.(key)}) (then (global.get $atom_true)) (else (global.get $atom_false)))"
             )
           ], false}

        {:gc_bif, :byte_size, _f, _l, [a], d} ->
          # byte_size works on a binary OR a match context (remaining bytes = total - position/8).
          {[
             set.(
               d,
               "(ref.i31 (if (result i32) (ref.test (ref $mctx) #{val.(a)}) " <>
                 "(then (i32.sub (i32.div_u (struct.get $mctx 2 (ref.cast (ref $mctx) #{val.(a)})) (i32.const 8)) (i32.div_u (struct.get $mctx 1 (ref.cast (ref $mctx) #{val.(a)})) (i32.const 8)))) " <>
                 "(else (if (result i32) (ref.test (ref $bitstr) #{val.(a)}) " <>
                 "(then (i32.div_u (i32.add (struct.get $bitstr 1 (ref.cast (ref $bitstr) #{val.(a)})) (i32.const 7)) (i32.const 8))) " <>
                 "(else (array.len (struct.get $binary 0 (ref.cast (ref $binary) #{val.(a)}))))))))"
             )
           ], false}

        {:gc_bif, :bit_size, _f, _l, [a], d} ->
          # works on a binary, a $bitstr, OR a match context (remaining bits = end - position)
          {[
             set.(
               d,
               "(ref.i31 (if (result i32) (ref.test (ref $mctx) #{val.(a)}) " <>
                 "(then (i32.sub (struct.get $mctx 2 (ref.cast (ref $mctx) #{val.(a)})) (struct.get $mctx 1 (ref.cast (ref $mctx) #{val.(a)})))) " <>
                 "(else (if (result i32) (ref.test (ref $bitstr) #{val.(a)}) " <>
                 "(then (struct.get $bitstr 1 (ref.cast (ref $bitstr) #{val.(a)}))) " <>
                 "(else (i32.shl (array.len (struct.get $binary 0 (ref.cast (ref $binary) #{val.(a)}))) (i32.const 3)))))))"
             )
           ], false}

        {:test, eq, {:f, f}, [a, b]} when eq in [:is_eq_exact, :is_eq] ->
          {["(if (i32.eqz #{term_eq(val.(a), val.(b))}) (then #{jump.(f)}))"], false}

        {:test, ne, {:f, f}, [a, b]} when ne in [:is_ne_exact, :is_ne] ->
          {["(if #{term_eq(val.(a), val.(b))} (then #{jump.(f)}))"], false}

        # ordering tests use the real Erlang term order ($term_compare), not integer-only compare
        {:test, :is_lt, {:f, f}, [a, b]} ->
          {["(if (i32.ge_s #{cmp3(a, b)} (i32.const 0)) (then #{jump.(f)}))"], false}

        {:test, :is_ge, {:f, f}, [a, b]} ->
          {["(if (i32.lt_s #{cmp3(a, b)} (i32.const 0)) (then #{jump.(f)}))"], false}

        {:test, :is_le, {:f, f}, [a, b]} ->
          {["(if (i32.gt_s #{cmp3(a, b)} (i32.const 0)) (then #{jump.(f)}))"], false}

        {:test, :is_gt, {:f, f}, [a, b]} ->
          {["(if (i32.le_s #{cmp3(a, b)} (i32.const 0)) (then #{jump.(f)}))"], false}

        {:test, :is_nonempty_list, {:f, f}, [s]} ->
          {["(if (i32.eqz (ref.test (ref $cons) #{val.(s)})) (then #{jump.(f)}))"], false}

        {:test, :is_nil, {:f, f}, [s]} ->
          {["(if (i32.eqz (ref.is_null #{val.(s)})) (then #{jump.(f)}))"], false}

        {:test, :is_tuple, {:f, f}, [s]} ->
          {["(if (i32.eqz (ref.test (ref $tuple) #{val.(s)})) (then #{jump.(f)}))"], false}

        {:test, :test_arity, {:f, f}, [s, n2]} ->
          {[
             "(if (i32.ne (array.len (ref.cast (ref $tuple) #{val.(s)})) (i32.const #{n2})) (then #{jump.(f)}))"
           ], false}

        {:test, :is_map, {:f, f}, [s]} ->
          {["(if (i32.eqz (ref.test (ref $map) #{val.(s)})) (then #{jump.(f)}))"], false}

        {:test, :is_atom, {:f, f}, [s]} ->
          {["(if (i32.eqz (ref.test (ref $atom) #{val.(s)})) (then #{jump.(f)}))"], false}

        {:test, :is_binary, {:f, f}, [s]} ->
          {["(if (i32.eqz (ref.test (ref $binary) #{val.(s)})) (then #{jump.(f)}))"], false}

        {:test, :is_bitstring, {:f, f}, [s]} ->
          {[
             "(if (i32.eqz (i32.or (ref.test (ref $binary) #{val.(s)}) (ref.test (ref $bitstr) #{val.(s)}))) (then #{jump.(f)}))"
           ], false}

        {:test, :is_boolean, {:f, f}, [s]} ->
          {[
             "(if (i32.and (i32.eqz (ref.eq #{val.(s)} (global.get $atom_true))) (i32.eqz (ref.eq #{val.(s)} (global.get $atom_false)))) (then #{jump.(f)}))"
           ], false}

        {:test, :is_function, {:f, f}, [s]} ->
          {["(if (i32.eqz (ref.test (ref $fun) #{val.(s)})) (then #{jump.(f)}))"], false}

        {:test, :is_function2, {:f, f}, [s, _arity]} ->
          {["(if (i32.eqz (ref.test (ref $fun) #{val.(s)})) (then #{jump.(f)}))"], false}

        {:test, :is_list, {:f, f}, [s]} ->
          {[
             "(if (i32.and (i32.eqz (ref.is_null #{val.(s)})) (i32.eqz (ref.test (ref $cons) #{val.(s)}))) (then #{jump.(f)}))"
           ], false}

        {:test, :is_integer, {:f, f}, [s]} ->
          test =
            if Process.get(:bignum),
              do:
                "(i32.and (i32.and (i32.eqz (ref.test (ref i31) #{val.(s)})) (i32.eqz (ref.test (ref $i64) #{val.(s)}))) (i32.eqz (ref.test (ref $big) #{val.(s)})))",
              else: "(i32.eqz (ref.test (ref i31) #{val.(s)}))"

          {["(if #{test} (then #{jump.(f)}))"], false}

        {:test, :is_float, {:f, f}, [s]} ->
          test = if Process.get(:float), do: "(ref.test (ref $float) #{val.(s)})", else: "(i32.const 0)"
          {["(if (i32.eqz #{test}) (then #{jump.(f)}))"], false}

        # is_number = integer (any tier) OR float
        {:test, :is_number, {:f, f}, [s]} ->
          {[
             "(if (i32.eqz (i32.or #{type_test_i32(:is_integer, val.(s))} #{type_test_i32(:is_float, val.(s))})) (then #{jump.(f)}))"
           ], false}

        {:test, :is_bitstr, {:f, f}, [s]} ->
          {["(if (i32.eqz (ref.test (ref $binary) #{val.(s)})) (then #{jump.(f)}))"], false}

        # floor/1 (and ceil) -> integer floor of a number. Needs the f64 path when floats are present.
        {:gc_bif, fc, _f, _l, [a], d} when fc in [:floor, :ceil] ->
          if Process.get(:float),
            do: {[set.(d, f64_to_int("(f64.#{fc} (call $to_f64 #{val.(a)}))"))], false},
            else: {[set.(d, val.(a))], false}

        # float/1 -> the float value of a number (int converts, float is identity).
        {gop, :float, _f, _l, [a], d} when gop in [:gc_bif, :bif] ->
          if Process.get(:float),
            do: {[set.(d, "(struct.new $float (call $to_f64 #{val.(a)}))")], false},
            else: {[set.(d, val.(a))], false}

        # trunc/1 (toward zero) and round/1 (half away from zero, like Erlang) -> an INTEGER. An
        # already-integer arg is returned unchanged (so bignums survive); a float is converted.
        {gop, tr, _f, _l, [a], d} when gop in [:gc_bif, :bif] and tr in [:trunc, :round] ->
          if Process.get(:float) do
            fx = "(struct.get $float 0 (ref.cast (ref $float) #{val.(a)}))"
            inner = if tr == :trunc, do: fx, else: "(f64.add #{fx} (f64.copysign (f64.const 0.5) #{fx}))"

            {[
               set.(
                 d,
                 "(if (result (ref null eq)) (ref.test (ref $float) #{val.(a)}) (then #{f64_to_int(inner)}) (else #{val.(a)}))"
               )
             ], false}
          else
            {[set.(d, val.(a))], false}
          end

        # boolean not/xor (value form): operands are the atoms true/false.
        {:bif, :not, _f, [a], d} ->
          {[
             set.(
               d,
               "(if (result (ref null eq)) (ref.eq #{val.(a)} (global.get $atom_true)) (then (global.get $atom_false)) (else (global.get $atom_true)))"
             )
           ], false}

        {:bif, :xor, _f, [a, b], d} ->
          {[
             set.(
               d,
               "(if (result (ref null eq)) (i32.ne (ref.eq #{val.(a)} (global.get $atom_true)) (ref.eq #{val.(b)} (global.get $atom_true))) (then (global.get $atom_true)) (else (global.get $atom_false)))"
             )
           ], false}

        {:bif, bop, _f, [a, b], d} when bop in [:and, :or] ->
          op = if bop == :and, do: "i32.and", else: "i32.or"

          {[
             set.(
               d,
               "(if (result (ref null eq)) (#{op} (ref.eq #{val.(a)} (global.get $atom_true)) (ref.eq #{val.(b)} (global.get $atom_true))) (then (global.get $atom_true)) (else (global.get $atom_false)))"
             )
           ], false}

        # type-test BIFs as VALUES (the atom true/false). The same predicates as the `test` forms.
        {:bif, tb, _f, [a], d}
        when tb in [
               :is_atom,
               :is_binary,
               :is_bitstring,
               :is_tuple,
               :is_map,
               :is_pid,
               :is_reference,
               :is_function,
               :is_float,
               :is_port,
               :is_integer,
               :is_list,
               :is_boolean
             ] ->
          t =
            case tb do
              :is_atom ->
                "(ref.test (ref $atom) #{val.(a)})"

              :is_binary ->
                "(ref.test (ref $binary) #{val.(a)})"

              :is_bitstring ->
                "(i32.or (ref.test (ref $binary) #{val.(a)}) (ref.test (ref $bitstr) #{val.(a)}))"

              :is_tuple ->
                "(ref.test (ref $tuple) #{val.(a)})"

              :is_map ->
                "(ref.test (ref $map) #{val.(a)})"

              :is_pid ->
                "(ref.test (ref $pid) #{val.(a)})"

              :is_reference ->
                "(ref.test (ref $ref) #{val.(a)})"

              :is_function ->
                "(ref.test (ref $fun) #{val.(a)})"

              :is_float ->
                if(Process.get(:float), do: "(ref.test (ref $float) #{val.(a)})", else: "(i32.const 0)")

              :is_port ->
                "(i32.const 0)"

              :is_integer ->
                if(Process.get(:bignum),
                  do:
                    "(i32.or (i32.or (ref.test (ref i31) #{val.(a)}) (ref.test (ref $i64) #{val.(a)})) (ref.test (ref $big) #{val.(a)}))",
                  else: "(ref.test (ref i31) #{val.(a)})"
                )

              :is_list ->
                "(i32.or (ref.is_null #{val.(a)}) (ref.test (ref $cons) #{val.(a)}))"

              :is_boolean ->
                "(i32.or (ref.eq #{val.(a)} (global.get $atom_true)) (ref.eq #{val.(a)} (global.get $atom_false)))"
            end

          {[
             set.(
               d,
               "(if (result (ref null eq)) #{t} (then (global.get $atom_true)) (else (global.get $atom_false)))"
             )
           ], false}

        {:test, :has_map_fields, {:f, fail}, src, {:list, keys}} ->
          {Enum.map(keys, fn key ->
             "(if (i32.eqz (call $map_has #{val.(src)} #{val.(key)})) (then #{jump.(fail)}))"
           end), false}

        {:get_map_elements, {:f, fail}, src, {:list, pairs}} ->
          # BEAM treats this as ONE instruction: every key is fetched from the ORIGINAL map even
          # when a destination register aliases the source (e.g. dst1 == src — Earmark's _parse/4
          # does exactly that). Stash the map in $tmp first so later keys never read a clobbered src.
          lines =
            ["(local.set $tmp #{val.(src)})"] ++
              (pairs
               |> Enum.chunk_every(2)
               |> Enum.flat_map(fn [key, dst] ->
                 [
                   "(local.set $mn (call $map_get (local.get $tmp) #{val.(key)}))",
                   "(if (ref.is_null (local.get $mn)) (then #{jump.(fail)}))",
                   set.(dst, "(struct.get $mnode 1 (ref.as_non_null (local.get $mn)))")
                 ]
               end))

          {lines, false}

        {:put_map_assoc, _f, src, dst, _l, {:list, kvs}} ->
          {[set.(dst, build_map(src, kvs, val))], false}

        {:put_map_exact, _f, src, dst, _l, {:list, kvs}} ->
          {[set.(dst, build_map(src, kvs, val))], false}

        {:get_list, s, h, t} ->
          {[
             "(local.set $tmpc (ref.cast (ref $cons) #{val.(s)}))",
             set.(h, "(struct.get $cons 0 (local.get $tmpc))"),
             set.(t, "(struct.get $cons 1 (local.get $tmpc))")
           ], false}

        {:get_hd, s, d} ->
          {[set.(d, "(struct.get $cons 0 (ref.cast (ref $cons) #{val.(s)}))")], false}

        {:get_tl, s, d} ->
          {[set.(d, "(struct.get $cons 1 (ref.cast (ref $cons) #{val.(s)}))")], false}

        {:bs_create_bin, _f, _heap, _live, _unit, dst, {:list, flat}} ->
          segs = Enum.chunk_every(flat, 6)
          {lines, expr} = create_bin_lines(segs, val)
          {lines ++ [set.(dst, expr)], false}

        # --- binary matching (modern OTP bs_match family) ---
        {:test, :bs_start_match3, {:f, fail}, _live, [src], dst} ->
          # src is EITHER the original binary (start at bit 0) OR an existing match
          # context threaded through a recursive call (reuse it, keep its position).
          {[
             "(if (ref.test (ref $mctx) #{val.(src)})",
             "  (then #{set.(dst, val.(src))})",
             "  (else",
             "    (if (i32.eqz (ref.test (ref $binary) #{val.(src)})) (then #{jump.(fail)}))",
             "    #{set.(dst, "(if (result (ref $mctx)) (ref.test (ref $bitstr) #{val.(src)}) (then (struct.new $mctx (struct.get $bitstr 0 (ref.cast (ref $bitstr) #{val.(src)})) (i32.const 0) (struct.get $bitstr 1 (ref.cast (ref $bitstr) #{val.(src)})))) (else (struct.new $mctx (struct.get $binary 0 (ref.cast (ref $binary) #{val.(src)})) (i32.const 0) (i32.shl (array.len (struct.get $binary 0 (ref.cast (ref $binary) #{val.(src)}))) (i32.const 3)))))")}))"
           ], false}

        # bs_start_match4: same as match3 but `fail` may be :no_fail/:resume (src provably matchable).
        {:bs_start_match4, fail, _live, src, dst} ->
          failbr =
            case fail do
              {:f, l} ->
                [
                  "(if (i32.eqz (i32.or (ref.test (ref $mctx) #{val.(src)}) (ref.test (ref $binary) #{val.(src)}))) (then #{jump.(l)}))"
                ]

              _ ->
                []
            end

          {failbr ++
             [
               "(if (ref.test (ref $mctx) #{val.(src)})",
               "  (then #{set.(dst, val.(src))})",
               "  (else #{set.(dst, "(if (result (ref $mctx)) (ref.test (ref $bitstr) #{val.(src)}) (then (struct.new $mctx (struct.get $bitstr 0 (ref.cast (ref $bitstr) #{val.(src)})) (i32.const 0) (struct.get $bitstr 1 (ref.cast (ref $bitstr) #{val.(src)})))) (else (struct.new $mctx (struct.get $binary 0 (ref.cast (ref $binary) #{val.(src)})) (i32.const 0) (i32.shl (array.len (struct.get $binary 0 (ref.cast (ref $binary) #{val.(src)}))) (i32.const 3)))))")}))"
             ], false}

        # binary_part(Subject, Start, Length) -> a sub-binary (Subject may be a binary or match ctx).
        {:gc_bif, :binary_part, _f, _l, [src, start, len], d} ->
          {[set.(d, "(call $binary_part #{val.(src)} #{i32v.(start)} #{i32v.(len)})")], false}

        # bs_get_utf8: decode one UTF-8 codepoint from the ctx (advancing it); fail on invalid/short.
        {:test, :bs_get_utf8, {:f, fail}, [ctx, _live, _flags, dst]} ->
          {[
             "(local.set $midx (call $mctx_get_utf8 #{val.(ctx)}))",
             "(if (i32.lt_s (local.get $midx) (i32.const 0)) (then #{jump.(fail)}))",
             set.(dst, "(ref.i31 (local.get $midx))")
           ], false}

        # bs_skip_utf8: same, but discard the codepoint (just advance).
        {:test, :bs_skip_utf8, {:f, fail}, [ctx, _live, _flags]} ->
          {["(if (i32.lt_s (call $mctx_get_utf8 #{val.(ctx)}) (i32.const 0)) (then #{jump.(fail)}))"], false}

        {:test, :bs_match_string, {:f, fail}, [ctx, bits, {:string, s}]} ->
          checks =
            bit_chunks(s, bits)
            |> Enum.map(fn {off, n, v} ->
              "(if (i32.ne (call $bits_read (local.get $bsrc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{off})) (i32.const #{n})) (i32.const #{i32_const(v)})) (then #{jump.(fail)}))"
            end)

          {[
             "(local.set $mc (ref.cast (ref $mctx) #{val.(ctx)}))",
             "(if (i32.lt_s (i32.sub (struct.get $mctx 2 (local.get $mc)) (struct.get $mctx 1 (local.get $mc))) (i32.const #{bits})) (then #{jump.(fail)}))",
             "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))"
           ] ++
             checks ++
             [
               "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{bits})))"
             ], false}

        # bs_get_binary2 (older form): extract `size` units (unit bits each) as a sub-binary, advancing
        # the ctx. Byte-aligned in practice (unit=8). size=:all (or {:atom,:all}) takes the rest.
        {:test, :bs_get_binary2, {:f, fail}, _live, [ctx, size, unit, _flags], dst} ->
          rest? = size == :all or match?({:atom, :all}, size)

          setup = [
            "(local.set $mc (ref.cast (ref $mctx) #{val.(ctx)}))",
            "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
            "(local.set $boff (i32.div_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8)))"
          ]

          tail =
            if rest? do
              [
                "(local.set $blen (i32.sub (i32.div_u (struct.get $mctx 2 (local.get $mc)) (i32.const 8)) (local.get $boff)))",
                "(struct.set $mctx 1 (local.get $mc) (struct.get $mctx 2 (local.get $mc)))"
              ]
            else
              nbits = "(i32.mul #{i32v.(size)} (i32.const #{unit}))"

              [
                "(if (i32.lt_s (i32.sub (struct.get $mctx 2 (local.get $mc)) (struct.get $mctx 1 (local.get $mc))) #{nbits}) (then #{jump.(fail)}))",
                "(local.set $blen (i32.div_u #{nbits} (i32.const 8)))",
                "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) #{nbits}))"
              ]
            end

          {setup ++
             tail ++
             [
               "(local.set $bdst (array.new_default $bytes (local.get $blen)))",
               "(array.copy $bytes $bytes (local.get $bdst) (i32.const 0) (local.get $bsrc) (local.get $boff) (local.get $blen))",
               set.(dst, "(struct.new $binary (ref.as_non_null (local.get $bdst)))")
             ], false}

        # bs_get_float2 (older form): read a `bits`-wide big-endian IEEE float (default flags), advancing.
        {:test, :bs_get_float2, {:f, fail}, _live, [ctx, sz, _unit, _flags], dst} ->
          bits =
            case sz do
              {:integer, n} -> n
              {:tr, {:integer, n}, _} -> n
              _ -> 64
            end

          if Process.get(:float) do
            {[
               "(local.set $mc (ref.cast (ref $mctx) #{val.(ctx)}))",
               "(if (i32.lt_s (i32.sub (struct.get $mctx 2 (local.get $mc)) (struct.get $mctx 1 (local.get $mc))) (i32.const #{bits})) (then #{jump.(fail)}))",
               "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
               "(local.set $boff (i32.div_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8)))",
               set.(
                 dst,
                 "(struct.new $float (call $read_f64_be (ref.as_non_null (local.get $bsrc)) (local.get $boff)))"
               ),
               "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{bits})))"
             ], false}
          else
            Process.put(:stubs, (Process.get(:stubs) || 0) + 1)
            {["(unreachable) ;; STUB test.bs_get_float2"], true}
          end

        # bs_init_writable: start an empty growable binary (the result lands in x0). Subsequent
        # `<<acc::binary, …>>` appends compile to bs_create_bin with a :private_append segment, which we
        # already lower by copying — so a plain empty $binary is a correct seed.
        op0 when op0 == :bs_init_writable ->
          {[set.({:x, 0}, "(struct.new $binary (array.new_default $bytes (i32.const 0)))")], false}

        {:bs_init_writable} ->
          {[set.({:x, 0}, "(struct.new $binary (array.new_default $bytes (i32.const 0)))")], false}

        {:bs_get_position, ctx, dst, _live} ->
          {[set.(dst, "(ref.i31 (struct.get $mctx 1 (ref.cast (ref $mctx) #{val.(ctx)})))")], false}

        {:bs_set_position, ctx, pos} ->
          {["(struct.set $mctx 1 (ref.cast (ref $mctx) #{val.(ctx)}) #{i32v.(pos)})"], false}

        {:bs_get_tail, ctx, dst, _live} ->
          {[
             "(local.set $mc (ref.cast (ref $mctx) #{val.(ctx)}))",
             "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
             "(local.set $boff (i32.div_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8)))",
             "(local.set $blen (i32.sub (i32.div_u (struct.get $mctx 2 (local.get $mc)) (i32.const 8)) (local.get $boff)))",
             "(local.set $bdst (array.new_default $bytes (local.get $blen)))",
             "(array.copy $bytes $bytes (local.get $bdst) (i32.const 0) (local.get $bsrc) (local.get $boff) (local.get $blen))",
             set.(dst, "(struct.new $binary (ref.as_non_null (local.get $bdst)))")
           ], false}

        {:bs_match, {:f, fail}, ctx, {:commands, cmds}} ->
          setup = ["(local.set $mc (ref.cast (ref $mctx) #{val.(ctx)}))"]

          lines =
            Enum.flat_map(cmds, fn
              {:ensure_at_least, bits, _unit} ->
                [
                  "(if (i32.lt_s (i32.sub (struct.get $mctx 2 (local.get $mc)) (struct.get $mctx 1 (local.get $mc))) (i32.const #{bits})) (then #{jump.(fail)}))"
                ]

              {:ensure_exactly, bits} ->
                [
                  "(if (i32.ne (i32.sub (struct.get $mctx 2 (local.get $mc)) (struct.get $mctx 1 (local.get $mc))) (i32.const #{bits})) (then #{jump.(fail)}))"
                ]

              {:skip, bits} ->
                [
                  "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{bits})))"
                ]

              {:integer, _live, flags, size, unit, dst} ->
                nbits = size * unit
                little? = match?({:literal, fl} when is_list(fl), flags) and :little in elem(flags, 1)
                # > 30 bits can't live in an i31: read as i64 and narrow into the exact tier
                # (i31/$i64/$big). <= 30 bits keep the original i32 fast path (byte-identical output).
                reader = if little?, do: "$bits_read64_le", else: "$bits_read64"

                read =
                  cond do
                    little? and rem(nbits, 8) != 0 ->
                      raise "little-endian non-byte-multiple integer segment (#{nbits} bits) in #{mod}.#{name}/#{arity}"

                    nbits <= 30 and not little? ->
                      "(ref.i31 (call $bits_read (local.get $bsrc) (struct.get $mctx 1 (local.get $mc)) (i32.const #{nbits})))"

                    nbits <= 30 ->
                      "(ref.i31 (i32.wrap_i64 (call #{reader} (local.get $bsrc) (struct.get $mctx 1 (local.get $mc)) (i32.const #{nbits}))))"

                    Process.get(:bignum) ->
                      "(call $narrow (call #{reader} (local.get $bsrc) (struct.get $mctx 1 (local.get $mc)) (i32.const #{nbits})))"

                    true ->
                      "(ref.i31 (i32.wrap_i64 (call #{reader} (local.get $bsrc) (struct.get $mctx 1 (local.get $mc)) (i32.const #{nbits}))))"
                  end

                [
                  "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
                  set.(dst, read),
                  "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{nbits})))"
                ]

              # f64 extraction (<<f::float>> match): read the 64 bits and reinterpret.
              {:float, _live, _flags, size, unit, dst} when size * unit == 64 ->
                [
                  "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
                  set.(
                    dst,
                    "(struct.new $float (f64.reinterpret_i64 (call $bits_read64 (local.get $bsrc) (struct.get $mctx 1 (local.get $mc)) (i32.const 64))))"
                  ),
                  "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const 64)))"
                ]

              {:binary, _live, _flags, size, unit, dst} ->
                nbits = size * unit
                nbytes = div(nbits, 8)

                extract =
                  if rem(nbits, 8) == 0 do
                    # byte-sized: keep the fast array.copy when the position is byte-aligned at runtime
                    "(if (result (ref null eq)) (i32.rem_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8)) " <>
                      "(then (call $bits_extract (ref.as_non_null (local.get $bsrc)) (struct.get $mctx 1 (local.get $mc)) (i32.const #{nbits}))) " <>
                      "(else (local.set $boff (i32.div_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8))) " <>
                      "(local.set $bdst (array.new_default $bytes (i32.const #{nbytes}))) " <>
                      "(array.copy $bytes $bytes (local.get $bdst) (i32.const 0) (local.get $bsrc) (local.get $boff) (i32.const #{nbytes})) " <>
                      "(struct.new $binary (ref.as_non_null (local.get $bdst)))))"
                  else
                    # sub-byte width: a real bitstring value
                    "(call $bits_extract (ref.as_non_null (local.get $bsrc)) (struct.get $mctx 1 (local.get $mc)) (i32.const #{nbits}))"
                  end

                [
                  "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
                  set.(dst, extract),
                  "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{nbits})))"
                ]

              {:"=:=", _, bits, value} ->
                [
                  "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
                  "(if (i32.ne (call $bits_read (local.get $bsrc) (struct.get $mctx 1 (local.get $mc)) (i32.const #{bits})) (i32.const #{i32_const(value)})) (then #{jump.(fail)}))",
                  "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{bits})))"
                ]

              {:get_tail, _live, _unit, dst} ->
                [
                  "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
                  set.(
                    dst,
                    "(if (result (ref null eq)) (i32.or (i32.rem_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8)) (i32.rem_u (struct.get $mctx 2 (local.get $mc)) (i32.const 8))) " <>
                      "(then (call $bits_extract (ref.as_non_null (local.get $bsrc)) (struct.get $mctx 1 (local.get $mc)) (i32.sub (struct.get $mctx 2 (local.get $mc)) (struct.get $mctx 1 (local.get $mc))))) " <>
                      "(else (local.set $boff (i32.div_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8))) " <>
                      "(local.set $blen (i32.sub (i32.div_u (struct.get $mctx 2 (local.get $mc)) (i32.const 8)) (local.get $boff))) " <>
                      "(local.set $bdst (array.new_default $bytes (local.get $blen))) " <>
                      "(array.copy $bytes $bytes (local.get $bdst) (i32.const 0) (local.get $bsrc) (local.get $boff) (local.get $blen)) " <>
                      "(struct.new $binary (ref.as_non_null (local.get $bdst)))))"
                  )
                ]

              other ->
                raise "bs_match cmd in #{mod}.#{name}/#{arity}: #{inspect(other)} (unsupported bitstring match; set STUB=1 to compile this to a trap and continue)"
            end)

          {setup ++ lines, false}

        {:badmatch, _} ->
          {["(unreachable)"], true}

        {:case_end, _} ->
          {["(unreachable)"], true}

        :if_end ->
          {["(unreachable)"], true}

        {:put_list, h, t, d} ->
          {[set.(d, "(struct.new $cons #{val.(h)} #{val.(t)})")], false}

        {:put_tuple2, d, {:list, elems}} ->
          {[set.(d, "(array.new_fixed $tuple #{length(elems)} #{Enum.map_join(elems, " ", val)})")], false}

        # update_record (OTP 27): a new Size-element tuple = source tuple with the listed 1-indexed fields
        # overwritten. Tuples are immutable, so build it in one array.new_fixed (indices are constants).
        {:update_record, _hint, size, src, dst, {:list, updates}} ->
          upd = updates |> Enum.chunk_every(2) |> Map.new(fn [idx, v] -> {idx - 1, val.(v)} end)

          elems =
            Enum.map_join(0..(size - 1), " ", fn i ->
              Map.get(upd, i, "(array.get $tuple (ref.cast (ref $tuple) #{val.(src)}) (i32.const #{i}))")
            end)

          {[set.(dst, "(array.new_fixed $tuple #{size} #{elems})")], false}

        # no try-clause matched (error path)
        {:try_case_end, _} ->
          {["(unreachable)"], true}

        {:get_tuple_element, s, i, d} ->
          {[set.(d, "(array.get $tuple (ref.cast (ref $tuple) #{val.(s)}) (i32.const #{i}))")], false}

        # element(N, Tuple) — 1-indexed tuple access (BIF form)
        # element/2 in GUARD context (real fail label): a non-tuple subject or out-of-range index is a
        # guard FAILURE (jump to f), never a trap — :lists.keydelete/keytake walk lists whose elements
        # may not be tuples at all.
        {:bif, :element, {:f, f}, [{:integer, n}, src], d} when f != 0 ->
          {[
             "(if (i32.eqz (ref.test (ref $tuple) #{val.(src)})) (then #{jump.(f)}))",
             "(if (i32.gt_s (i32.const #{n}) (array.len (ref.cast (ref $tuple) #{val.(src)}))) (then #{jump.(f)}))",
             set.(d, "(array.get $tuple (ref.cast (ref $tuple) #{val.(src)}) (i32.const #{n - 1}))")
           ], false}

        {:bif, :element, {:f, f}, [idx, src], d} when f != 0 ->
          {[
             "(if (i32.eqz (ref.test (ref $tuple) #{val.(src)})) (then #{jump.(f)}))",
             "(if (i32.or (i32.lt_s #{i32v.(idx)} (i32.const 1)) (i32.gt_s #{i32v.(idx)} (array.len (ref.cast (ref $tuple) #{val.(src)})))) (then #{jump.(f)}))",
             set.(
               d,
               "(array.get $tuple (ref.cast (ref $tuple) #{val.(src)}) (i32.sub #{i32v.(idx)} (i32.const 1)))"
             )
           ], false}

        {:bif, :element, _f, [{:integer, n}, src], d} ->
          {[set.(d, "(array.get $tuple (ref.cast (ref $tuple) #{val.(src)}) (i32.const #{n - 1}))")], false}

        {:bif, :element, _f, [idx, src], d} ->
          {[
             set.(
               d,
               "(array.get $tuple (ref.cast (ref $tuple) #{val.(src)}) (i32.sub #{i32v.(idx)} (i32.const 1)))"
             )
           ], false}

        {:bif, :tuple_size, _f, [src], d} ->
          {[set.(d, "(ref.i31 (array.len (ref.cast (ref $tuple) #{val.(src)})))")], false}

        # --- closures ---
        {:make_fun3, {m, fun, far}, _idx, _hash, dst, {:list, free}} ->
          %{idx: cidx} = Map.fetch!(Process.get(:closures), {m, fun, far})
          fvs = if free == [], do: "", else: " " <> Enum.map_join(free, " ", val)

          {[
             set.(
               dst,
               "(struct.new $fun (i32.const #{cidx}) (array.new_fixed $freevars #{length(free)}#{fvs}))"
             )
           ], false}

        {:call_fun, nn} ->
          funref = "(local.get $x#{nn})"
          args = if nn == 0, do: "", else: " " <> Enum.map_join(0..(nn - 1), " ", &"(local.get $x#{&1})")

          {[
             set.(
               {:x, 0},
               "(call_indirect $ftab (type $clos#{nn}) #{funref}#{args} (struct.get $fun 0 (ref.cast (ref $fun) #{funref})))"
             )
           ], false}

        {:call_fun2, _tag, nn, funreg} ->
          funref = val.(funreg)
          args = if nn == 0, do: "", else: " " <> Enum.map_join(0..(nn - 1), " ", &"(local.get $x#{&1})")

          {[
             set.(
               {:x, 0},
               "(call_indirect $ftab (type $clos#{nn}) #{funref}#{args} (struct.get $fun 0 (ref.cast (ref $fun) #{funref})))"
             )
           ], false}

        # --- processes (spawn/send/self/receive) --- (incl. tail-call variants)
        {:call_ext, _ar, {:extfunc, :erlang, :spawn, 1}} ->
          {["(local.set $x0 (struct.new $pid (call $spawn_raw (local.get $x0))))"], false}

        {ce, _ar, {:extfunc, :erlang, :spawn, 1}} when ce in [:call_ext_only] ->
          {["(return (struct.new $pid (call $spawn_raw (local.get $x0))))"], true}

        {:call_ext_last, _ar, {:extfunc, :erlang, :spawn, 1}, _d} ->
          {["(return (struct.new $pid (call $spawn_raw (local.get $x0))))"], true}

        {:call_ext, _ar, {:extfunc, :erlang, :send, 2}} ->
          {["(local.set $x0 (call $send_raw (call $resolve_dest (local.get $x0)) (local.get $x1)))"], false}

        # send(Dest, Msg, Opts) -> like send/2 (options like noconnect/nosuspend are no-ops here); returns ok.
        {:call_ext, _ar, {:extfunc, :erlang, :send, 3}} ->
          {[
             "(call $send_raw (call $resolve_dest (local.get $x0)) (local.get $x1))",
             set.({:x, 0}, "(global.get $atom_ok)")
           ], false}

        {:call_ext_only, _ar, {:extfunc, :erlang, :send, 2}} ->
          {["(return_call $send_raw (call $resolve_dest (local.get $x0)) (local.get $x1))"], true}

        {:call_ext_last, _ar, {:extfunc, :erlang, :send, 2}, _d} ->
          {["(return_call $send_raw (call $resolve_dest (local.get $x0)) (local.get $x1))"], true}

        # registry + monitors. Process.register(pid, name): x0=pid, x1=name (note arg order).
        # Process.whereis(name): x0=name. :erlang.monitor(:process, pid): x0=:process, x1=pid.
        {:call_ext, _ar, {:extfunc, Process, :register, 2}} ->
          {[
             "(call $register_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x1))) (struct.get $pid 0 (ref.cast (ref $pid) (local.get $x0))))",
             set.({:x, 0}, "(global.get $atom_true)")
           ], false}

        # erlang:register(Name, Pid) -> register a name (note: (Name, Pid) order, unlike Process.register).
        {:call_ext, _ar, {:extfunc, :erlang, :register, 2}} ->
          {[
             "(call $register_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0))) (struct.get $pid 0 (ref.cast (ref $pid) (local.get $x1))))",
             set.({:x, 0}, "(global.get $atom_true)")
           ], false}

        {:call_ext, _ar, {:extfunc, Process, :whereis, 1}} ->
          {[
             "(local.set $x0 (struct.new $pid (call $whereis_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0))))))"
           ], false}

        # erlang:whereis(Name) -> the registered pid, or the atom `undefined` (pid id 0 = not found).
        {ce, _ar, {:extfunc, :erlang, :whereis, 1}} when ce in [:call_ext, :call_ext_only] ->
          e =
            "(if (result (ref null eq)) (i32.eqz (call $whereis_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0))))) (then (global.get $atom_undefined)) (else (struct.new $pid (call $whereis_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0)))))))"

          if ce == :call_ext, do: {[set.({:x, 0}, e)], false}, else: {["(return #{e})"], true}

        {:call_ext_last, _ar, {:extfunc, :erlang, :whereis, 1}, _} ->
          {[
             "(return (if (result (ref null eq)) (i32.eqz (call $whereis_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0))))) (then (global.get $atom_undefined)) (else (struct.new $pid (call $whereis_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0))))))))"
           ], true}

        {ce, _ar, {:extfunc, :erlang, :monitor, ma}} when ce in [:call_ext] and ma in [2, 3] ->
          {[
             "(local.set $x0 (struct.new $ref (call $monitor_raw (struct.get $pid 0 (ref.cast (ref $pid) (local.get $x1)))) (i32.const 0)))"
           ], false}

        # demonitor(Ref[, Opts]) -> drop the monitor (and flush a pending DOWN); returns true.
        {ce, _ar, {:extfunc, :erlang, :demonitor, _da}} when ce in [:call_ext, :call_ext_only, :call_ext_last] ->
          {[
             "(call $demonitor_raw (struct.get $ref 0 (ref.cast (ref $ref) (local.get $x0))))",
             set.({:x, 0}, "(global.get $atom_true)")
           ], false}

        # spawn_opt(M, F, Args, Opts) -> a process running apply(M,F,Args). `link` bidir-links; `monitor`
        # makes the result `{Pid, MonRef}` (and sets up the monitor) instead of a bare Pid — proc_lib
        # relies on this. spawn_opt/5 (Node, M, F, Args, Opts) ignores Node. All call forms incl. tails.
        {ce, _ar, {:extfunc, :erlang, :spawn_opt, ar}} when ce in [:call_ext, :call_ext_only] and ar in [4, 5] ->
          e = spawn_opt_expr.(ar)
          if ce == :call_ext, do: {[set.({:x, 0}, e)], false}, else: {["(return #{e})"], true}

        {:call_ext_last, _ar, {:extfunc, :erlang, :spawn_opt, ar}, _} when ar in [4, 5] ->
          {["(return #{spawn_opt_expr.(ar)})"], true}

        # make_fun(M, F, Arity) -> a fun whose table slot is the arity-A trampoline (base+A), capturing M,F.
        {:call_ext, _ar, {:extfunc, :erlang, :make_fun, 3}} ->
          {[
             set.(
               {:x, 0},
               "(struct.new $fun (i32.add (i32.const #{Process.get(:tramp_base)}) (i31.get_s (ref.cast (ref i31) (local.get $x2)))) (array.new_fixed $freevars 2 (local.get $x0) (local.get $x1)))"
             )
           ], false}

        # hibernate(M, F, A): suspend the process; on the next message, resume via apply(M,F,A).
        {_ce, _ar, {:extfunc, :erlang, :hibernate, 3}} ->
          {[
             "(local.set $hmod (local.get $x0))",
             "(local.set $hfun (local.get $x1))",
             "(local.set $hargs (local.get $x2))",
             "(call $recv_wait)",
             "(return_call $erlang_apply_3 (local.get $hmod) (local.get $hfun) (local.get $hargs))"
           ], true}

        {:call_ext_last, _ar, {:extfunc, :erlang, :hibernate, 3}, _} ->
          {[
             "(local.set $hmod (local.get $x0))",
             "(local.set $hfun (local.get $x1))",
             "(local.set $hargs (local.get $x2))",
             "(call $recv_wait)",
             "(return_call $erlang_apply_3 (local.get $hmod) (local.get $hfun) (local.get $hargs))"
           ], true}

        # apply(M, F, ArgsList): dispatch on list length to apply_N (the generic apply helper).
        {ce, _ar, {:extfunc, :erlang, :apply, 3}} when ce in [:call_ext, :call_ext_only] ->
          if ce == :call_ext,
            do:
              {[set.({:x, 0}, "(call $erlang_apply_3 (local.get $x0) (local.get $x1) (local.get $x2))")],
               false},
            else: {["(return_call $erlang_apply_3 (local.get $x0) (local.get $x1) (local.get $x2))"], true}

        {:call_ext_last, _ar, {:extfunc, :erlang, :apply, 3}, _} ->
          {["(return_call $erlang_apply_3 (local.get $x0) (local.get $x1) (local.get $x2))"], true}

        {:call_ext, _ar, {:extfunc, :erlang, :spawn_link, 1}} ->
          {["(local.set $x0 (struct.new $pid (call $spawn_link_raw (local.get $x0))))"], false}

        {:call_ext_only, _ar, {:extfunc, :erlang, :spawn_link, 1}} ->
          {["(return (struct.new $pid (call $spawn_link_raw (local.get $x0))))"], true}

        # exit/1: route to the scheduler's $exit_raw in proc mode; outside proc mode there is no process
        # to unwind, so it's an unrecoverable error path -> trap (never reached on a non-faulting run).
        {ce, _ar, {:extfunc, :erlang, :exit, 1}} when ce in [:call_ext, :call_ext_only] ->
          {if(Process.get(:proc),
             do: ["(call $exit_raw (local.get $x0))", "(unreachable)"],
             else: ["(unreachable)"]
           ), true}

        {:call_ext_last, _ar, {:extfunc, :erlang, :exit, 1}, _d} ->
          {if(Process.get(:proc),
             do: ["(call $exit_raw (local.get $x0))", "(unreachable)"],
             else: ["(unreachable)"]
           ), true}

        # exit/2 (Process.exit(pid, reason)): signal another process — the host unwinds a parked target
        # (kill-by-unwind) or, if it traps_exit, delivers {:EXIT, from, reason}. Returns true (unlike
        # exit/1, this one returns; tail forms return the value).
        {ce, _ar, {:extfunc, :erlang, :exit, 2}} when ce in [:call_ext, :call_ext_only] ->
          call = "(call $exit2_raw (struct.get $pid 0 (ref.cast (ref $pid) (local.get $x0))) (local.get $x1))"

          if ce == :call_ext,
            do: {[call, "(local.set $x0 (global.get $atom_true))"], false},
            else: {[call, "(return (global.get $atom_true))"], true}

        {:call_ext_last, _ar, {:extfunc, :erlang, :exit, 2}, _d} ->
          {[
             "(call $exit2_raw (struct.get $pid 0 (ref.cast (ref $pid) (local.get $x0))) (local.get $x1))",
             "(return (global.get $atom_true))"
           ], true}

        # process_flag(:trap_exit, v) — only flag we support; returns old value (assume false)
        {:call_ext, _ar, {:extfunc, :erlang, :process_flag, 2}} ->
          {[
             "(call $set_trap_exit (ref.eq (local.get $x1) (global.get $atom_true)))",
             set.({:x, 0}, "(global.get $atom_false)")
           ], false}

        {:bif, :self, _f, [], d} ->
          {[set.(d, "(struct.new $pid (call $self_raw))")], false}

        # the `send` opcode (Pid ! Msg): dest in x0, message in x1; result (the message) -> x0.
        :send ->
          {["(local.set $x0 (call $send_raw (call $resolve_dest (local.get $x0)) (local.get $x1)))"], false}

        # process dictionary: get(K) (absent -> the atom `undefined`), put(K,V) (returns old or undefined),
        # erase(K) (not yet — falls through). Keys are interned atoms => stable identity in the host Map.
        {:bif, :get, _f, [k], d} ->
          {[
             "(local.set $tmp (call $pdict_get #{val.(k)}))",
             set.(
               d,
               "(if (result (ref null eq)) (ref.is_null (local.get $tmp)) (then (global.get $atom_undefined)) (else (local.get $tmp)))"
             )
           ], false}

        {ce, _ar, {:extfunc, :erlang, :get, 1}} when ce in [:call_ext] ->
          {[
             "(local.set $x0 (call $pdict_get (local.get $x0)))",
             set.(
               {:x, 0},
               "(if (result (ref null eq)) (ref.is_null (local.get $x0)) (then (global.get $atom_undefined)) (else (local.get $x0)))"
             )
           ], false}

        {ce, _ar, {:extfunc, :erlang, :put, 2}} when ce in [:call_ext] ->
          {[
             "(local.set $x0 (call $pdict_put (local.get $x0) (local.get $x1)))",
             set.(
               {:x, 0},
               "(if (result (ref null eq)) (ref.is_null (local.get $x0)) (then (global.get $atom_undefined)) (else (local.get $x0)))"
             )
           ], false}

        # monotonic_time([Unit]) -> a monotonically increasing integer (a counter; the supervisor only
        # uses it to compare restart times within a window, so the source just needs to be monotonic).
        {ce, _ar, {:extfunc, :erlang, mt, _n}}
        when ce in [:call_ext, :call_ext_only] and mt in [:monotonic_time, :system_time, :unique_integer] ->
          e =
            "(block (result (ref null eq)) (global.set $monotime (i32.add (global.get $monotime) (i32.const 1))) (ref.i31 (global.get $monotime)))"

          if ce == :call_ext, do: {[set.({:x, 0}, e)], false}, else: {["(return #{e})"], true}

        {:call_ext_last, _ar, {:extfunc, :erlang, mt, _n}, _}
        when mt in [:monotonic_time, :system_time, :unique_integer] ->
          {[
             "(return (block (result (ref null eq)) (global.set $monotime (i32.add (global.get $monotime) (i32.const 1))) (ref.i31 (global.get $monotime))))"
           ], true}

        # node()/node(_) -> the single node we run on. (No distribution.)
        {gop, :node, _f, _l, _args, d} when gop in [:gc_bif, :bif] ->
          {[set.(d, "(global.get $atom_#{sanitize(:nonode@nohost)})")], false}

        {:bif, :node, _f, _args, d} ->
          {[set.(d, "(global.get $atom_#{sanitize(:nonode@nohost)})")], false}

        {ce, _ar, {:extfunc, :erlang, :node, n}} when ce in [:call_ext] and n in [0, 1] ->
          {[set.({:x, 0}, "(global.get $atom_#{sanitize(:nonode@nohost)})")], false}

        # pids and references are distinct boxed types
        {:test, :is_pid, {:f, f}, [s]} ->
          {["(if (i32.eqz (ref.test (ref $pid) #{val.(s)})) (then #{jump.(f)}))"], false}

        {:test, :is_reference, {:f, f}, [s]} ->
          {["(if (i32.eqz (ref.test (ref $ref) #{val.(s)})) (then #{jump.(f)}))"], false}

        {:test, :is_port, {:f, f}, [_s]} ->
          {[jump.(f)], true}

        {gop, :make_ref, _f, _l, [], d} when gop in [:gc_bif, :bif] ->
          {[
             "(global.set $refctr (i32.add (global.get $refctr) (i32.const 1)))",
             set.(d, "(struct.new $ref (global.get $refctr) (i32.const 0))")
           ], false}

        {:bif, :make_ref, _f, [], d} ->
          {[
             "(global.set $refctr (i32.add (global.get $refctr) (i32.const 1)))",
             set.(d, "(struct.new $ref (global.get $refctr) (i32.const 0))")
           ], false}

        {:call_ext, _ar, {:extfunc, :erlang, :make_ref, 0}} ->
          {[
             "(global.set $refctr (i32.add (global.get $refctr) (i32.const 1)))",
             set.({:x, 0}, "(struct.new $ref (global.get $refctr) (i32.const 0))")
           ], false}

        # --- exceptions ---  ($htgt = active handler's block index; -1 = disarmed)
        # Nesting is handled via a handler "stack" threaded through BEAM's per-try Y register:
        # `try` saves the parent handler into Y and arms its own; `try_end` (success path) and
        # `try_case` (exception-landing path) both restore the parent. So a throw inside a catch
        # body unwinds to the enclosing try, exactly like BEAM's catch stack.
        {:try, {:y, k}, {:f, l}} ->
          {["(local.set $y#{k} (ref.i31 (local.get $htgt)))", "(local.set $htgt (i32.const #{blk.(l)}))"],
           false}

        {:try_end, {:y, k}} ->
          {["(local.set $htgt (i31.get_s (ref.cast (ref i31) (local.get $y#{k}))))"], false}

        # first op of the handler block; x0/x1/x2 already = class/reason/trace
        {:try_case, {:y, k}} ->
          {[
             "(local.set $excf (i32.const 0))",
             "(local.set $htgt (i31.get_s (ref.cast (ref i31) (local.get $y#{k}))))"
           ], false}

        # old-style `catch Expr`: like try, but catch_end runs on BOTH the normal and exception paths.
        # $excf (set by the footer) tells catch_end which; on exception it transforms (class,reason,trace)
        # into the catch value (throw→reason, exit→{'EXIT',reason}, error→{'EXIT',{reason,trace}}).
        {:catch, {:y, k}, {:f, l}} ->
          {["(local.set $y#{k} (ref.i31 (local.get $htgt)))", "(local.set $htgt (i32.const #{blk.(l)}))"],
           false}

        {:catch_end, {:y, k}} ->
          {[
             "(if (local.get $excf) (then (local.set $excf (i32.const 0)) (local.set $x0 " <>
               "(if (result (ref null eq)) (ref.eq (local.get $x0) (global.get $atom_throw)) (then (local.get $x1)) " <>
               "(else (if (result (ref null eq)) (ref.eq (local.get $x0) (global.get $atom_exit)) " <>
               "(then (array.new_fixed $tuple 2 (global.get $atom_EXIT) (local.get $x1))) " <>
               "(else (array.new_fixed $tuple 2 (global.get $atom_EXIT) (array.new_fixed $tuple 2 (local.get $x1) (local.get $x2))))))))))",
             "(local.set $htgt (i31.get_s (ref.cast (ref i31) (local.get $y#{k}))))"
           ], false}

        {ce, _ar, {:extfunc, :erlang, :throw, 1}} when ce in [:call_ext, :call_ext_only] ->
          {["(throw $exc (global.get $atom_throw) (local.get $x0) (ref.null none))"], true}

        {:call_ext_last, _ar, {:extfunc, :erlang, :throw, 1}, _} ->
          {["(throw $exc (global.get $atom_throw) (local.get $x0) (ref.null none))"], true}

        {ce, _ar, {:extfunc, :erlang, :error, _ea}} when ce in [:call_ext, :call_ext_only] ->
          {["(throw $exc (global.get $atom_error) (local.get $x0) (ref.null none))"], true}

        {:call_ext_last, _ar, {:extfunc, :erlang, :error, _ea}, _} ->
          {["(throw $exc (global.get $atom_error) (local.get $x0) (ref.null none))"], true}

        # re-raise the caught exception (x0/x1/x2)
        {:bif, :raise, _f, _args, _d} ->
          {["(throw $exc (local.get $x0) (local.get $x1) (local.get $x2))"], true}

        # build_stacktrace: materialize the stacktrace into x0. We don't track stacktraces, so [] (a
        # valid empty stacktrace). raw_raise: re-raise class/reason/stacktrace (x0/x1/x2) as $exc.
        :build_stacktrace ->
          {[set.({:x, 0}, "(ref.null none)")], false}

        :raw_raise ->
          {["(throw $exc (local.get $x0) (local.get $x1) (local.get $x2))"], true}

        # --- floats: f64 register file ($fr0..), boxed as a $float term in x/y registers ---
        {:fconv, src, {:fr, n}} ->
          {["(local.set $fr#{n} (call $to_f64 #{val.(src)}))"], false}

        {:fmove, {:float, lit}, {:fr, n}} ->
          {["(local.set $fr#{n} (f64.const #{float_lit(lit)}))"], false}

        {:fmove, {:fr, a}, {:fr, b}} ->
          {["(local.set $fr#{b} #{frval.({:fr, a})})"], false}

        {:fmove, {:fr, n}, dst} ->
          {[set.(dst, "(struct.new $float #{frval.({:fr, n})})")], false}

        {:fmove, src, {:fr, n}} ->
          {["(local.set $fr#{n} (call $to_f64 #{val.(src)}))"], false}

        {:bif, fop, _f, [a, b], {:fr, n}} when fop in [:fadd, :fsub, :fmul, :fdiv] ->
          o =
            case fop do
              :fadd -> "add"
              :fsub -> "sub"
              :fmul -> "mul"
              :fdiv -> "div"
            end

          {["(local.set $fr#{n} (f64.#{o} #{frval.(a)} #{frval.(b)}))"], false}

        {:loop_rec, {:f, e}, dst} ->
          {["(if (i32.eqz (call $recv_has)) (then #{jump.(e)}))", set.(dst, "(call $recv_cur)")], false}

        :remove_message ->
          {["(call $recv_remove)"], false}

        {:loop_rec_end, {:f, l}} ->
          {["(call $recv_advance)", jump.(l)], true}

        {:wait, {:f, l}} ->
          {["(call $recv_wait)", jump.(l)], true}

        # receive…after N (finite literal): park up to N ms. recv_wait_timeout returns 1 if a message
        # arrived (jump back to the receive scan at l) or 0 if the timer fired (fall through to the
        # `timeout` opcode + the after-body). `after :infinity` lowers to :wait, and `after 0` emits no
        # wait at all, so this clause only sees finite non-zero timeouts.
        {:wait_timeout, {:f, l}, {:integer, ms}} ->
          {["(if (call $recv_wait_timeout (i32.const #{ms})) (then #{jump.(l)}))"], false}

        # variable/non-literal timeout: block (re-scan on any message). A finite runtime timeout value
        # is not honored — a documented limitation; literal `after N` (the common form) is.
        {:wait_timeout, {:f, l}, _timeout} ->
          {["(call $recv_wait)", jump.(l)], true}

        # timeout-fired landing (unreached while we always block)
        :timeout ->
          {[], false}

        {:timeout, _} ->
          {[], false}

        # selective-receive markers (OTP 26+ optimization): no-ops for our linear mailbox scan.
        {:recv_marker_reserve, _} ->
          {[], false}

        {:recv_marker_bind, _, _} ->
          {[], false}

        {:recv_marker_use, _} ->
          {[], false}

        {:recv_marker_clear, _} ->
          {[], false}

        {:test, :is_tagged_tuple, {:f, f}, [s, ar, {:atom, tag}]} ->
          {[
             "(if (i32.eqz (ref.test (ref $tuple) #{val.(s)})) (then #{jump.(f)}))",
             "(if (i32.ne (array.len (ref.cast (ref $tuple) #{val.(s)})) (i32.const #{ar})) (then #{jump.(f)}))",
             "(if (i32.eqz (ref.eq (array.get $tuple (ref.cast (ref $tuple) #{val.(s)}) (i32.const 0)) (global.get $atom_#{sanitize(tag)}))) (then #{jump.(f)}))"
           ], false}

        # tail calls -> real Wasm `return_call` (NOT `(return (call …))`, which grows the stack).
        # Load-bearing: deep tail recursion (and the ~5KB JSPI process-stack floor) depend on it.
        # dynamic dispatch: mod.fun(args) -> apply_last/apply. args x0..x[N-1], mod x[N], fun x[N+1].
        # Routed through a generated $apply_N that switches on (mod, fun) over closed-world functions.
        {:apply, n} ->
          {["(local.set $x0 (call $apply_#{n} #{Enum.map_join(0..(n + 1), " ", &"(local.get $x#{&1})")}))"],
           false}

        {:apply_last, n, _d} ->
          {["(return_call $apply_#{n} #{Enum.map_join(0..(n + 1), " ", &"(local.get $x#{&1})")})"], true}

        {:call, _ar, {m, f, a}} ->
          {["(local.set $x0 (call #{fq(m, f, a)} #{cargs.(a)}))"], false}

        {:call_only, _ar, {m, f, a}} ->
          {["(return_call #{fq(m, f, a)} #{cargs.(a)})"], true}

        {:call_last, _ar, {m, f, a}, _d} ->
          {["(return_call #{fq(m, f, a)} #{cargs.(a)})"], true}

        {:call_ext, _ar, {:extfunc, m, f, a}} ->
          {["(local.set $x0 (call #{fq(m, f, a)} #{cargs.(a)}))"], false}

        {:call_ext_only, _ar, {:extfunc, m, f, a}} ->
          {["(return_call #{fq(m, f, a)} #{cargs.(a)})"], true}

        {:call_ext_last, _ar, {:extfunc, m, f, a}, _d} ->
          {["(return_call #{fq(m, f, a)} #{cargs.(a)})"], true}

        {:i64fused, plan} ->
          {emit_i64fused(plan), false}

        {:trmc_cons, h} ->
          {[
             "(local.set $tmpc (struct.new $cons #{val.(h)} (ref.null none)))",
             "(if (ref.is_null (local.get $trmc_tail)) (then (local.set $trmc_head (local.get $tmpc))) (else (struct.set $cons 1 (ref.as_non_null (local.get $trmc_tail)) (local.get $tmpc))))",
             "(local.set $trmc_tail (local.get $tmpc))"
           ] ++
             reds_check.() ++
             ["(local.set $blk (i32.const #{entry_idx})) (br $dispatch)"], true}

        {:trmc_self_tail} ->
          {reds_check.() ++ ["(local.set $blk (i32.const #{entry_idx})) (br $dispatch)"], true}

        :return when trmc? ->
          {trmc_epilogue(), true}

        :return ->
          {["(return (local.get $x0))"], true}

        {:jump, {:f, f}} ->
          {[jump.(f)], true}

        {:select_val, src, {:f, fail}, {:list, pairs}} ->
          chunks = Enum.chunk_every(pairs, 2)
          sb = int_bounds(src)
          # SPECIALIZE: integer src with bounded i31 range + all-integer cases (e.g. Jason's per-byte
          # switch) -> a direct i32.eq chain (src cast ONCE into $midx). No term_eq/term_compare storm.
          sel =
            if sb && fits_i31?(sb) && Enum.all?(chunks, fn [v, _] -> match?({:integer, _}, v) end) do
              ["(local.set $midx #{i32v.(src)})"] ++
                Enum.map(chunks, fn [{:integer, n}, {:f, l}] ->
                  "(if (i32.eq (local.get $midx) (i32.const #{n})) (then #{jump.(l)}))"
                end)
            else
              Enum.map(chunks, fn [v, {:f, l}] -> "(if #{term_eq(val.(src), val.(v))} (then #{jump.(l)}))" end)
            end

          {sel ++ [jump.(fail)], true}

        {:select_tuple_arity, src, {:f, fail}, {:list, pairs}} ->
          sel =
            pairs
            |> Enum.chunk_every(2)
            |> Enum.map(fn [ar, {:f, l}] ->
              "(if (if (result i32) (ref.test (ref $tuple) #{val.(src)}) (then (i32.eq (array.len (ref.cast (ref $tuple) #{val.(src)})) (i32.const #{ar}))) (else (i32.const 0))) (then #{jump.(l)}))"
            end)

          {sel ++ [jump.(fail)], true}

        {:swap, a, b} ->
          {["(local.set $tmp #{val.(a)})", set.(a, val.(b)), set.(b, "(local.get $tmp)")], false}

        {:func_info, _, _, _} ->
          {["(unreachable)"], true}

        {:allocate, _, _} ->
          {[], false}

        {:allocate_zero, _, _} ->
          {[], false}

        {:allocate_heap, _, _, _} ->
          {[], false}

        {:init_yregs, _} ->
          {[], false}

        {:trim, _, _} ->
          {[], false}

        {:deallocate, _} ->
          {[], false}

        {:test_heap, _, _} ->
          {[], false}

        {:line, _} ->
          {[], false}

        :int_code_end ->
          {[], false}

        other ->
          # STUB mode: lower an unsupported opcode to a trap so the whole module still
          # compiles. Only unexercised paths (non-list Enum fns, try/apply/float) hit it.
          if Process.get(:stub) do
            tag =
              case other do
                {t, op, _, _, _, _} when t in [:gc_bif] -> "#{t}.#{op}"
                {t, op, _, _, _} when t in [:bif] -> "#{t}.#{op}"
                {:test, op, _, _} -> "test.#{op}"
                {:test, op, _, _, _} -> "test.#{op}"
                {:test, op, _, _, _, _} -> "test.#{op}"
                t when is_tuple(t) -> elem(t, 0)
                t -> t
              end

            Process.put(:stubs, (Process.get(:stubs) || 0) + 1)
            {["(unreachable) ;; STUB #{tag}"], true}
          else
            raise "unhandled opcode in #{mod}.#{name}/#{arity}: #{inspect(other)} (set STUB=1 to compile this to a trap and continue)"
          end
      end
    end

    # A closure target takes (self, call-args…); free vars travel in `self` and are
    # copied into the high registers x[N..] by the prologue. A normal function takes its
    # args directly. call_arity N = total arity - num free vars.
    # Only a pure lambda (captured, never called directly) uses the (self, args…) form
    # with a free-var prologue. A dual target keeps its normal signature + a wrapper.
    cl = Process.get(:closures, %{}) |> Map.get({mod, name, arity})
    clos = if cl && not cl.dual, do: cl, else: nil
    call_arity = if clos, do: clos.n, else: arity
    xstart = call_arity

    func_decl =
      if clos do
        ps =
          if call_arity > 0,
            do: Enum.map_join(0..(call_arity - 1), "", &" (param $x#{&1} (ref null eq))"),
            else: ""

        "  (func #{fn_name} (type $clos#{call_arity}) (param $self (ref null eq))#{ps} (result (ref null eq))"
      else
        params =
          if arity == 0,
            do: "",
            else: " " <> Enum.map_join(0..(arity - 1), " ", &"(param $x#{&1} (ref null eq))")

        "  (func #{fn_name}#{params} (result (ref null eq))"
      end

    prologue =
      if clos && clos.f > 0 do
        Enum.map(0..(clos.f - 1), fn i ->
          "    (local.set $x#{call_arity + i} (array.get $freevars (struct.get $fun 1 (ref.cast (ref $fun) (local.get $self))) (i32.const #{i})))"
        end)
      else
        []
      end

    nexts = tl(blocks) ++ [nil]
    # try-mode: wrap the dispatch loop in `(loop $reenter (block $caught (try_table …)))`.
    # An armed `try` sets $htgt to its catch block index; a thrown $exc lands in $caught,
    # which stages (class,reason,trace)→(x0,x1,x2) and either re-dispatches to $htgt or re-throws.
    loop_open =
      if has_try do
        [
          "    (loop $reenter",
          "      (block $caught (result (ref null eq) (ref null eq) (ref null eq))",
          "      (try_table (catch $exc $caught)",
          "    (loop $dispatch",
          "      (block $b_default"
        ]
      else
        ["    (loop $dispatch", "      (block $b_default"]
      end

    header =
      [func_decl] ++
        if(maxx >= xstart, do: Enum.map(xstart..maxx, &"    (local $x#{&1} (ref null eq))"), else: []) ++
        if(maxy >= 0, do: Enum.map(0..maxy, &"    (local $y#{&1} (ref null eq))"), else: []) ++
        if(trmc?,
          do: ["    (local $trmc_head (ref null $cons)) (local $trmc_tail (ref null $cons))"],
          else: []
        ) ++
        if(fimax >= 0, do: [Enum.map_join(0..fimax, " ", &"    (local $fi#{&1} i64)")], else: []) ++
        [
          "    (local $blk i32) (local $tmpc (ref null $cons)) (local $tmp (ref null eq)) (local $midx i32) (local $mn (ref null $mnode))",
          "    (local $boff i32) (local $blen i32) (local $bdst (ref null $bytes)) (local $bsrc (ref null $bytes)) (local $mc (ref null $mctx))",
          "    (local $tmptup (ref null $tuple)) (local $hmod (ref null eq)) (local $hfun (ref null eq)) (local $hargs (ref null eq))"
        ] ++
        if(has_try, do: ["    (local $htgt i32) (local $excf i32)"], else: []) ++
        if(maxfr >= 0, do: Enum.map(0..maxfr, &"    (local $fr#{&1} f64)"), else: []) ++
        case Process.get(:reds) do
          nil ->
            []

          b ->
            [
              "    (global.set $reds (i32.sub (global.get $reds) (i32.const 1)))",
              "    (if (i32.le_s (global.get $reds) (i32.const 0)) (then (call $yield) (global.set $reds (i32.const #{b}))))"
            ]
        end ++
        prologue ++
        if(has_try, do: ["    (local.set $htgt (i32.const -1))"], else: []) ++
        ["    (local.set $blk (i32.const #{entry_idx}))"] ++
        loop_open ++
        Enum.map((n - 1)..0, &"      (block $b#{&1}") ++
        [
          "        (br_table " <>
            Enum.map_join(0..(n - 1), " ", &"$b#{&1}") <> " $b_default (local.get $blk)))"
        ]

    body =
      Enum.zip([blocks, nexts, 0..(n - 1)])
      |> Enum.flat_map(fn {{label, ops}, next, bi} ->
        {lines, term} =
          Enum.reduce_while(ops, {[], false}, fn op, {acc, _} ->
            {ls, t} = emit.(op)
            # in a TRMC function every exit must run the hole-patch epilogue: demote any
            # cross-function tail call to call+epilogue (self tail calls already re-enter
            # the dispatch loop via {:trmc_self_tail}).
            ls = if trmc?, do: demote_tails(ls), else: ls
            if t, do: {:halt, {acc ++ ls, true}}, else: {:cont, {acc ++ ls, false}}
          end)

        lines = if term, do: lines, else: lines ++ [if(next, do: jump.(elem(next, 0)), else: "(unreachable)")]
        ["      ;; --- block #{bi} (label #{label}) ---"] ++ Enum.map(lines, &("      " <> &1)) ++ ["      )"]
      end)

    footer =
      if has_try do
        # default-block body (dead)
        [
          "      (unreachable)",
          # close (loop $dispatch
          "    )",
          # close (try_table
          "      )",
          # try body never falls through; satisfies $caught result
          "      (unreachable)",
          # close (block $caught — lands here on a thrown $exc
          "      )",
          # trace, reason, class (stack top→down)
          "      (local.set $x2) (local.set $x1) (local.set $x0)",
          "      (if (i32.ge_s (local.get $htgt) (i32.const 0))",
          # mark exception; try_case/catch_end consume $excf
          "        (then (local.set $excf (i32.const 1)) (local.set $blk (local.get $htgt)) (br $reenter))",
          "        (else (throw $exc (local.get $x0) (local.get $x1) (local.get $x2))))",
          # close (loop $reenter
          "    )",
          # close (func
          "    (unreachable))"
        ]
      else
        ["      (unreachable)", "    )", "    (unreachable))"]
      end

    (header ++ body ++ footer) |> Enum.join("\n")
  end

  # operand -> term-valued WAT
  def operand({:tr, reg, _}), do: operand(reg)
  def operand({:x, n}), do: "(local.get $x#{n})"
  def operand({:y, n}), do: "(local.get $y#{n})"
  def operand({:integer, n}), do: int_literal(n)
  # a bare float literal used as a VALUE (function arg, list/tuple element) → a boxed $float. (Float
  # literals in arithmetic go through fconv/fmove + float registers; this is the non-register path.)
  def operand({:float, f}), do: "(struct.new $float (f64.const #{float_lit(f)}))"
  # bare nil operand = the empty list []
  def operand(nil), do: "(ref.null none)"
  # the atom nil (Elixir's nil) — distinct
  def operand({:atom, nil}), do: "(global.get $atom_nil)"
  def operand({:atom, a}), do: "(global.get $atom_#{sanitize(a)})"
  def operand({:literal, term}), do: materialize(term)

  def operand(o) do
    if Process.get(:stub) do
      # Unknown operand SHAPE under STUB mode: emit a trap and COUNT it, exactly like an
      # opcode-level stub. Never emit a usable nil (the old "(ref.null none)") — that would
      # flow on as a silent wrong value, turning a miscompile into a lie instead of an honest
      # trap (and it would not increment the STUBS meter, so it'd hide as "0 stubs"). The
      # block comment is inert; a ;; line comment would swallow the enclosing expression.
      Process.put(:stubs, (Process.get(:stubs) || 0) + 1)
      "(unreachable) (; STUB operand ;)"
    else
      raise "operand: #{inspect(o)} — unsupported operand shape (set STUB=1 to trap+count instead)"
    end
  end

  # ── type-driven specialization, from beam_disasm's typed registers ──
  # `{:tr, reg, {:t_integer, {lo,hi}}}` is a bounded integer; `{:integer, n}` a literal (point bound);
  # `{:t_integer, :any}` an unbounded integer; `{:t_number, _}` could be a float (NOT specializable).
  @i31_lo -1_073_741_824
  @i31_hi 1_073_741_823
  def int_bounds({:integer, n}), do: {n, n}
  def int_bounds({:tr, _, {:t_integer, {lo, hi}}}) when is_integer(lo) and is_integer(hi), do: {lo, hi}
  def int_bounds(_), do: nil
  def int_typed?({:integer, _}), do: true
  def int_typed?({:tr, _, {:t_integer, _}}), do: true
  def int_typed?(_), do: false
  # result interval of +/-/* on two integer intervals; nil unless BOTH operands are bounded.
  def arith_bounds(o, a1, a2) do
    case {int_bounds(a1), int_bounds(a2)} do
      {{lo1, hi1}, {lo2, hi2}} ->
        case o do
          :+ ->
            {lo1 + lo2, hi1 + hi2}

          :- ->
            {lo1 - hi2, hi1 - lo2}

          :* ->
            ps = for x <- [lo1, hi1], y <- [lo2, hi2], do: x * y
            {Enum.min(ps), Enum.max(ps)}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  # provably representable as a bare i31 immediate (so the op can be inline i32, no helper, no box).
  def fits_i31?({lo, hi}), do: lo >= @i31_lo and hi <= @i31_hi
  def fits_i31?(_), do: false

  def i32val({:integer, n}), do: "(i32.const #{n})"
  def i32val({:tr, reg, _}), do: i32val(reg)
  def i32val(reg), do: "(i31.get_s (ref.cast (ref i31) #{operand(reg)}))"

  # i64-valued operand: integer literals (which may exceed 32 bits) as i64.const; a register
  # is an i31 term sign-extended to i64. For bitwise ops that need >32-bit width.
  def i64val({:integer, n}), do: "(i64.const #{n})"
  def i64val({:tr, reg, _}), do: i64val(reg)
  def i64val(reg), do: "(i64.extend_i32_s (i31.get_s (ref.cast (ref i31) #{operand(reg)})))"

  # f64 expression -> integer term. In bignum mode the $f64_to_int helper covers ALL tiers
  # (i64-fitting in Wasm, finite >2^63 -> exact host bignum, NaN/inf -> honest trap), matching
  # the VM (trunc(Float.max_finite()) is a bignum). Otherwise the i32 fast path.
  def f64_to_int(fexpr) do
    if Process.get(:bignum),
      do: "(call $f64_to_int #{fexpr})",
      else: "(ref.i31 (i32.trunc_f64_s #{fexpr}))"
  end

  def bif(:+), do: "add"
  def bif(:-), do: "sub"
  def bif(:*), do: "mul"
  def bif(:div), do: "div"
  def bif(:rem), do: "rem"
  def bif(o), do: raise("bif #{o}")

  # comparison op -> an i32 (1/0) expression, for the boolean-valued bif form
  # type-specialized 3-way compare (<0/0/>0). Bounded small ints -> inline i32 sign (no call);
  # proven integers -> $int_cmp; otherwise the generic $term_compare. Hot: byte/guard comparisons.
  def cmp3(a, b) do
    ba = int_bounds(a)
    bb = int_bounds(b)

    cond do
      ba && bb && fits_i31?(ba) && fits_i31?(bb) ->
        "(i32.sub (i32.gt_s #{i32val(a)} #{i32val(b)}) (i32.lt_s #{i32val(a)} #{i32val(b)}))"

      int_typed?(a) and int_typed?(b) ->
        "(call $int_cmp #{operand(a)} #{operand(b)})"

      true ->
        "(call $term_compare #{operand(a)} #{operand(b)})"
    end
  end

  def bool_cmp(op, a, b) do
    eq = term_eq(operand(a), operand(b))

    case op do
      o when o in [:"=:=", :==] -> eq
      o when o in [:"=/=", :"/="] -> "(i32.eqz #{eq})"
      :< -> "(i32.lt_s #{cmp3(a, b)} (i32.const 0))"
      :> -> "(i32.gt_s #{cmp3(a, b)} (i32.const 0))"
      :>= -> "(i32.ge_s #{cmp3(a, b)} (i32.const 0))"
      :"=<" -> "(i32.le_s #{cmp3(a, b)} (i32.const 0))"
    end
  end

  # full WAT i32 instruction suffix for each gc_bif arithmetic/bitwise op
  def wasmop(:+), do: "add"
  def wasmop(:-), do: "sub"
  def wasmop(:*), do: "mul"
  def wasmop(:div), do: "div_s"
  def wasmop(:rem), do: "rem_s"
  def wasmop(:band), do: "and"
  def wasmop(:bor), do: "or"
  def wasmop(:bxor), do: "xor"
  def wasmop(:bsl), do: "shl"
  def wasmop(:bsr), do: "shr_s"
  def wasmop(o), do: raise("wasmop #{o}")

  def partition(instrs) do
    {blocks, last} =
      Enum.reduce(instrs, {[], nil}, fn
        {:label, l}, {bs, cur} -> {push(bs, cur), {l, []}}
        _i, {bs, nil} -> {bs, nil}
        i, {bs, {l, ops}} -> {bs, {l, [i | ops]}}
      end)

    push(blocks, last) |> Enum.reverse() |> Enum.map(fn {l, ops} -> {l, Enum.reverse(ops)} end)
  end

  def push(bs, nil), do: bs
  def push(bs, b), do: [b | bs]

  def max_regs(instrs, arity) do
    regs = Enum.flat_map(instrs, &regs_in/1)

    {Enum.reduce(regs, arity - 1, fn
       {:x, n}, m -> max(m, n)
       _, m -> m
     end),
     Enum.reduce(regs, -1, fn
       {:y, n}, m -> max(m, n)
       _, m -> m
     end)}
  end

  # trim N renumbers Y registers (logical yK becomes physical y(K+shift)). Resolve
  # statically per block: drop each trim, shift subsequent Y references down.
  def resolve_trims(ops) do
    {rev, _} =
      Enum.reduce(ops, {[], 0}, fn
        {:trim, k, _}, {acc, shift} -> {acc, shift + k}
        op, {acc, 0} -> {[op | acc], 0}
        op, {acc, shift} -> {[shift_y(op, shift) | acc], shift}
      end)

    Enum.reverse(rev)
  end

  # ── TRMC machinery ──
  # Detect `call self; (test_heap)?; put_list H, x0, x0; (deallocate)?; return` and replace the
  # window with {:trmc_cons, H}. When any site exists, self TAIL calls become {:trmc_self_tail}
  # (loop re-entry keeps the chain locals alive).
  def trmc_rewrite(blocks, {_m, _f, _a} = self) do
    rewritten = Enum.map(blocks, fn {l, ops} -> {l, trmc_scan(ops, self)} end)

    if rewritten == blocks do
      {blocks, false}
    else
      {Enum.map(rewritten, fn {l, ops} ->
         {l,
          Enum.map(ops, fn
            {:call_only, _, ^self} -> {:trmc_self_tail}
            {:call_last, _, ^self, _} -> {:trmc_self_tail}
            op -> op
          end)}
       end), true}
    end
  end

  defp trmc_scan([{:call, _, self} = op | rest], self) do
    case trmc_window(rest) do
      {:ok, h, rest2} -> [{:trmc_cons, h} | trmc_scan(rest2, self)]
      :no -> [op | trmc_scan(rest, self)]
    end
  end

  defp trmc_scan([op | rest], self), do: [op | trmc_scan(rest, self)]
  defp trmc_scan([], _), do: []

  defp trmc_window(ops) do
    ops = Enum.drop_while(ops, &match?({:line, _}, &1))

    ops =
      case ops do
        [{:test_heap, _, _} | r] -> r
        _ -> ops
      end

    ops = Enum.drop_while(ops, &match?({:line, _}, &1))

    case ops do
      [{:put_list, h, {:x, 0}, {:x, 0}} | r] when h != {:x, 0} ->
        r = Enum.drop_while(r, &match?({:line, _}, &1))

        r =
          case r do
            [{:deallocate, _} | r2] -> r2
            _ -> r
          end

        r = Enum.drop_while(r, &match?({:line, _}, &1))

        case r do
          [:return | r2] -> {:ok, h, r2}
          _ -> :no
        end

      _ ->
        :no
    end
  end

  # every return path of a TRMC function patches the pending hole with x0 and returns the chain
  def trmc_epilogue do
    [
      "(if (ref.is_null (local.get $trmc_tail)) (then (return (local.get $x0))))",
      "(struct.set $cons 1 (ref.as_non_null (local.get $trmc_tail)) (local.get $x0))",
      "(return (ref.as_non_null (local.get $trmc_head)))"
    ]
  end

  # rewrite emitted lines: a tail call becomes a plain call whose result flows through the
  # epilogue; a plain return is replaced by the epilogue. Lines are single-expression strings.
  def demote_tails(lines) do
    Enum.flat_map(lines, fn line ->
      cond do
        String.starts_with?(line, "(return_call ") ->
          ["(local.set $x0 (call " <> String.trim_leading(line, "(return_call ") <> ")"] ++ trmc_epilogue()

        line == "(return (local.get $x0))" ->
          trmc_epilogue()

        true ->
          [line]
      end
    end)
  end

  # ── cross-op unboxing: i64 chain fusion ──
  # Fuse runs of integer gc_bifs into raw-i64 arithmetic in shadow locals, boxing only the
  # values that survive the run. Soundness is a small domain lattice per SSA node:
  #   {:s64, {lo,hi}}  true value, bounds proven ⊆ signed i64 (runtime tier is i31/$i64)
  #   :u64raw          congruence-class mod 2^64 only (may exceed 64 bits in truth); may flow
  #                    ONLY through {+,*,band,bor,bxor,bsl} until canonicalized
  #   :u64             canonical: true value == unsigned 64-bit pattern (after `rem 2^64` or a
  #                    low-bit mask) — then shr_u / rem_u / bxor read the bits directly
  # Anything unprovable aborts the run prefix conservatively. Bignum mode only; operands must
  # carry beam_disasm integer type bounds. (The mod-2^64 PRNG/hash shape — the ledger's host-
  # BigInt tax — fuses to pure wrapping i64 with ONE box at the end.)
  @fuse_arith [:+, :-, :*, :band, :bor, :bxor, :bsl, :bsr, :rem]
  @congruence [:+, :*, :band, :bor, :bxor]
  @pow64 18_446_744_073_709_551_616
  @s64_lo -9_223_372_036_854_775_808
  @s64_hi 9_223_372_036_854_775_807

  def i64fuse_blocks(blocks), do: Enum.map(blocks, fn {l, ops} -> {l, i64fuse_scan(ops)} end)

  defp i64fuse_scan(ops) do
    case take_run(ops) do
      {run, rest} when length(run) >= 2 ->
        case plan_run(run, rest) do
          # the plan may cover only a PREFIX of the run: the dropped tail ops MUST be re-emitted
          # (deleting them was the gen_15/gen_19 miscompile genfuzz caught)
          {:ok, plan, leftover} -> [{:i64fused, plan} | leftover] ++ i64fuse_scan(rest)
          :no -> emit_unfused(run) ++ i64fuse_scan(rest)
        end

      {run, rest} ->
        emit_unfused(run) ++ if rest == [], do: [], else: [hd(rest) | i64fuse_scan(tl(rest))]
    end
  end

  defp emit_unfused(run), do: run

  # a run: maximal consecutive fusable gc_bifs ({:line,_} dropped inside)
  defp take_run([{:gc_bif, o, {:f, 0}, _, [_, _], _} = op | rest]) when o in @fuse_arith do
    {more, rest2} = take_run(Enum.drop_while(rest, &match?({:line, _}, &1)))
    {[op | more], rest2}
  end

  defp take_run(ops), do: {[], ops}

  # plan a run; shrink from the tail until every live-out is materializable. Returns
  # {:ok, plan, dropped_tail_ops} so the scan re-emits what the plan does not cover, and
  # liveness for a prefix is judged against the DROPPED ops first (they may read prefix dsts).
  defp plan_run(run, rest), do: try_plan(run, [], rest)

  defp try_plan(run, _dropped, _rest) when length(run) < 2, do: :no

  defp try_plan(run, dropped, rest) do
    case build_plan(run, dead_regs_after(dropped ++ rest)) do
      {:ok, plan} -> {:ok, plan, dropped}
      :no -> try_plan(Enum.drop(run, -1), [List.last(run) | dropped], rest)
    end
  end

  # regs provably dead after the run: the next op's Live count (gc_bif/test_heap) kills x>=Live
  defp dead_regs_after([{:test_heap, _, live} | _]), do: {:xdead_from, live}
  defp dead_regs_after([{:gc_bif, _, _, live, _, _} | _]), do: {:xdead_from, live}
  defp dead_regs_after(_), do: :none

  defp dead?({:x, i}, {:xdead_from, live}) when i >= live, do: true
  defp dead?(_, _), do: false

  defp build_plan(run, dead) do
    init = %{nodes: [], n: 0, regs: %{}}

    case Enum.reduce_while(run, {:ok, init}, fn {:gc_bif, o, _, _, [a, b], dst}, {:ok, st} ->
           case fuse_op(o, a, b, dst, st) do
             {:ok, st2} -> {:cont, {:ok, st2}}
             :no -> {:halt, :no}
           end
         end) do
      :no ->
        :no

      {:ok, st} ->
        outs =
          st.regs
          |> Enum.reject(fn {reg, _} -> dead?(reg, dead) end)
          |> Enum.map(fn {reg, id} -> {reg, id, node_dom(st, id)} end)

        if Enum.any?(outs, fn {_, _, d} -> d == :u64raw end) or st.n > 14,
          do: :no,
          else: {:ok, %{nodes: Enum.reverse(st.nodes), outs: outs}}
    end
  end

  defp node_dom(st, id), do: st.nodes |> Enum.find(fn {i, _, _} -> i == id end) |> elem(1)

  defp add_node(st, dom, src), do: {st.n, %{st | nodes: [{st.n, dom, src} | st.nodes], n: st.n + 1}}

  # resolve an operand to a node (existing chain node, fresh term input, or literal)
  defp opnode({:integer, v}, st) when v >= @s64_lo and v <= @s64_hi,
    do: {:ok, add_node(st, {:s64, {v, v}}, {:lit, v})}

  defp opnode({:integer, _}, _), do: :no
  defp opnode({:tr, reg, t}, st), do: opnode_reg(reg, t, st)
  defp opnode(reg, st) when elem(reg, 0) in [:x, :y], do: opnode_reg(reg, :notype, st)
  defp opnode(_, _), do: :no

  defp opnode_reg(reg, t, st) do
    case Map.fetch(st.regs, reg) do
      {:ok, id} ->
        {:ok, {id, st}}

      :error ->
        case t do
          {:t_integer, {lo, hi}} when is_integer(lo) and is_integer(hi) and lo >= @s64_lo and hi <= @s64_hi ->
            {:ok, add_node(st, {:s64, {lo, hi}}, {:in_s64, reg})}

          {:t_integer, {lo, _}} when is_integer(lo) and lo >= 0 ->
            {:ok, add_node(st, :u64raw, {:in_u64, reg})}

          _ ->
            :no
        end
    end
  end

  # `x rem 2^64` short-circuits BEFORE divisor resolution (2^64 doesn't fit s64 as a node;
  # it isn't a value here, it's the canonicalizer)
  defp fuse_op(:rem, a, {:integer, @pow64}, dst, st) do
    with {:ok, {na, st}} <- opnode(a, st),
         d when d == :u64raw or d == :u64 or (elem(d, 0) == :s64 and elem(elem(d, 1), 0) >= 0) <-
           node_dom(st, na) do
      {id, st} = add_node(st, :u64, {:nop, na, na})
      {:ok, %{st | regs: Map.put(st.regs, dst, id)}}
    else
      bad ->
        if System.get_env("FUSEDBG"), do: IO.inspect({:rem_pow64, a, bad}, label: "FUSE MISS", limit: 12)
        :no
    end
  end

  defp fuse_op(o, a, b, dst, st) do
    with {:ok, {na, st}} <- opnode(a, st),
         {:ok, {nb, st}} <- opnode(b, st),
         {:ok, dom, wop} <- transition(o, node_dom(st, na), node_dom(st, nb), b) do
      {id, st} = add_node(st, dom, {wop, na, nb})
      {:ok, %{st | regs: Map.put(st.regs, dst, id)}}
    else
      bad ->
        if System.get_env("FUSEDBG"),
          do: IO.inspect({o, a, b, bad}, label: "FUSE MISS", limit: 12, width: 140)

        :no
    end
  end

  # ── the lattice ──
  defp transition(:rem, da, _db, {:integer, @pow64}) do
    # `x rem 2^64` canonicalizes a nonneg congruence class: identity on the bits
    case da do
      {:s64, {lo, _}} when lo >= 0 -> {:ok, :u64, :nop}
      :u64raw -> {:ok, :u64, :nop}
      :u64 -> {:ok, :u64, :nop}
      _ -> :no
    end
  end

  defp transition(:rem, da, db, _b) do
    # unsigned rem by a positive divisor; dividend must have nonneg true value
    with true <- nonneg?(da),
         {:s64, {lo, hi}} when lo >= 1 <- db do
      {:ok, {:s64, {0, hi - 1}}, :rem_u}
    else
      _ -> :no
    end
  end

  defp transition(:bsr, da, {:s64, {k, k}}, _b) when k >= 0 do
    case da do
      {:s64, {lo, hi}} when lo >= 0 -> {:ok, {:s64, {Bitwise.bsr(lo, k), Bitwise.bsr(hi, k)}}, :shr_u}
      :u64 when k >= 1 -> {:ok, {:s64, {0, Bitwise.bsr(@pow64 - 1, k)}}, :shr_u}
      :u64 -> {:ok, :u64, :nop}
      _ -> :no
    end
  end

  defp transition(:band, da, {:s64, {m, m}}, _b) when m >= 0 do
    # low-bit mask reads only low bits: sound even on a congruence class
    if low_mask?(m) and (match?({:s64, {lo, _}} when lo >= 0, da) or da in [:u64raw, :u64]),
      do: {:ok, {:s64, {0, m}}, :and},
      else: band_bounded(da, m)
  end

  defp transition(:bsl, da, {:s64, {lo, hi}}, _b) when lo >= 0 and hi <= 63 do
    # const-bounded shift: stay exact if bounds allow, else congruence (count proven < 64)
    case da do
      {:s64, ba} ->
        case s64_bounds(:bsl_range, ba, {lo, hi}) do
          {l2, h2} when l2 >= @s64_lo and h2 <= @s64_hi -> {:ok, {:s64, {l2, h2}}, :shl}
          _ -> if nonneg_b?(ba), do: {:ok, :u64raw, :shl}, else: :no
        end

      d when d in [:u64raw, :u64] ->
        {:ok, :u64raw, :shl}

      _ ->
        :no
    end
  end

  defp transition(:bsl, _, _, _), do: :no

  defp transition(o, {:s64, ba}, {:s64, bb}, _b) when o in [:+, :-, :*, :band, :bor, :bxor] do
    case s64_bounds(o, ba, bb) do
      {lo, hi} when lo >= @s64_lo and hi <= @s64_hi ->
        {:ok, {:s64, {lo, hi}}, s64op(o)}

      _ ->
        # overflows signed 64: keep as congruence class when both sides are nonneg
        if o in @congruence and nonneg_b?(ba) and nonneg_b?(bb), do: {:ok, :u64raw, s64op(o)}, else: :no
    end
  end

  defp transition(o, da, db, _b) when o in [:+, :*, :band, :bor, :bxor] do
    # mixed/raw congruence arithmetic: stays a congruence class
    if (da in [:u64raw, :u64] or nonneg?(da)) and (db in [:u64raw, :u64] or nonneg?(db)) do
      dom = if o == :bxor and canonical?(da) and canonical?(db), do: :u64, else: :u64raw
      {:ok, dom, s64op(o)}
    else
      :no
    end
  end

  defp transition(_, _, _, _), do: :no

  defp band_bounded({:s64, {lo, hi}}, m) when lo >= 0, do: {:ok, {:s64, {0, min(hi, m)}}, :and}
  defp band_bounded(_, _), do: :no

  defp canonical?(:u64), do: true
  defp canonical?({:s64, {lo, _}}) when lo >= 0, do: true
  defp canonical?(_), do: false
  defp nonneg?({:s64, {lo, _}}) when lo >= 0, do: true
  defp nonneg?(:u64), do: true
  defp nonneg?(_), do: false
  defp nonneg_b?({lo, _}), do: lo >= 0
  defp low_mask?(m), do: m > 0 and Bitwise.band(m, m + 1) == 0

  defp s64_bounds(:+, {a, b}, {c, d}), do: {a + c, b + d}
  defp s64_bounds(:-, {a, b}, {c, d}), do: {a - d, b - c}

  defp s64_bounds(:*, {a, b}, {c, d}) do
    ps = for x <- [a, b], y <- [c, d], do: x * y
    {Enum.min(ps), Enum.max(ps)}
  end

  defp s64_bounds(:band, {a, b}, {c, d}) when a >= 0 and c >= 0, do: {0, min(b, d)}
  defp s64_bounds(:bor, {a, b}, {c, d}) when a >= 0 and c >= 0, do: {0, 2 * max(b, d) + 1}
  defp s64_bounds(:bxor, {a, b}, {c, d}) when a >= 0 and c >= 0, do: {0, 2 * max(b, d) + 1}

  defp s64_bounds(:bsl_range, {a, b}, {c, d}) when c >= 0 and d <= 63 do
    vals = for x <- [a, b], k <- [c, d], do: x * Bitwise.bsl(1, k)
    {Enum.min(vals), Enum.max(vals)}
  end

  defp s64_bounds(_, _, _), do: {@s64_lo - 1, @s64_hi + 1}

  defp s64op(:+), do: :add
  defp s64op(:-), do: :sub
  defp s64op(:*), do: :mul
  defp s64op(:band), do: :and
  defp s64op(:bor), do: :or
  defp s64op(:bxor), do: :xor
  defp s64op(:bsl), do: :shl

  # WAT for a fused plan: load inputs into $fiN shadow locals, run raw i64 ops, box live-outs
  def emit_i64fused(plan) do
    loads =
      Enum.flat_map(plan.nodes, fn
        {id, _, {:lit, v}} ->
          ["(local.set $fi#{id} (i64.const #{v}))"]

        {id, _, {:in_s64, reg}} ->
          ["(local.set $fi#{id} (call $as_i64 #{operand(reg)}))"]

        {id, _, {:in_u64, reg}} ->
          ["(local.set $fi#{id} (call $term_u64bits #{operand(reg)}))"]

        {id, _, {:nop, n1, _}} ->
          ["(local.set $fi#{id} (local.get $fi#{n1}))"]

        {id, _, {wop, n1, n2}} ->
          ["(local.set $fi#{id} (i64.#{wop} (local.get $fi#{n1}) (local.get $fi#{n2})))"]
      end)

    stores =
      Enum.map(plan.outs, fn
        {reg, id, {:s64, bounds}} ->
          if fits_i31?(bounds),
            do: "(local.set $#{rname(reg)} (ref.i31 (i32.wrap_i64 (local.get $fi#{id}))))",
            else: "(local.set $#{rname(reg)} (call $narrow (local.get $fi#{id})))"

        {reg, id, :u64} ->
          "(local.set $#{rname(reg)} (call $narrow_u64 (local.get $fi#{id})))"
      end)

    loads ++ stores
  end

  defp rname({:x, n}), do: "x#{n}"
  defp rname({:y, n}), do: "y#{n}"

  def i64fused_max_node(blocks) do
    blocks
    |> Enum.flat_map(fn {_l, ops} -> ops end)
    |> Enum.flat_map(fn
      {:i64fused, plan} -> Enum.map(plan.nodes, &elem(&1, 0))
      _ -> []
    end)
    |> Enum.max(fn -> -1 end)
  end

  def shift_y({:y, k}, s), do: {:y, k + s}
  def shift_y({:literal, _} = l, _), do: l
  def shift_y(t, s) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&shift_y(&1, s)) |> List.to_tuple()
  def shift_y(l, s) when is_list(l), do: Enum.map(l, &shift_y(&1, s))
  def shift_y(x, _), do: x
  # f64 literal -> a WAT-valid float token (shortest round-trippable; e-notation is fine in WAT)
  def float_lit(x) when is_float(x), do: Float.to_string(x)
  def float_lit(x) when is_integer(x), do: Float.to_string(x * 1.0)

  def regs_in({:literal, _}), do: []
  def regs_in({:x, _} = r), do: [r]
  def regs_in({:y, _} = r), do: [r]
  def regs_in(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&regs_in/1)
  def regs_in(l) when is_list(l), do: Enum.flat_map(l, &regs_in/1)
  def regs_in(_), do: []

  # collect distinct atoms referenced anywhere (instruction operands + inside literals)
  # all float-register indices {:fr, n} referenced anywhere in an op (operands and dests)
  def fr_indices({:fr, n}), do: [n]
  def fr_indices(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&fr_indices/1)
  def fr_indices(l) when is_list(l), do: Enum.flat_map(l, &fr_indices/1)
  def fr_indices(_), do: []

  def i32_const(n) when n >= 0x8000_0000, do: n - 0x1_0000_0000
  def i32_const(n), do: n

  def bit_chunks(s, bits) do
    bytes = :binary.bin_to_list(IO.iodata_to_binary(s))
    do_bit_chunks(bytes, bits, 0, []) |> Enum.reverse()
  end

  def do_bit_chunks(_bytes, 0, _off, acc), do: acc

  def do_bit_chunks(bytes, bits, off, acc) do
    n = min(bits, 31)

    v =
      Enum.reduce(0..(n - 1), 0, fn i, out ->
        p = off + i
        byte = Enum.at(bytes, div(p, 8), 0)
        bit = Bitwise.band(Bitwise.bsr(byte, 7 - rem(p, 8)), 1)
        Bitwise.bor(Bitwise.bsl(out, 1), bit)
      end)

    do_bit_chunks(bytes, bits - n, off + n, [{off, n, v} | acc])
  end

  # ---- binary construction (bs_create_bin) ----

  # emit WAT that builds the binary from its segments into $bdst; returns {lines, result_expr}.
  # Each seg = [type, flags, unit, nil, src, size]. Supported: string segs and binary segs
  # (size :all or a fixed integer byte count). Runtime length = sum of segment byte lengths.
  def create_bin_lines(segs, val) do
    if Enum.any?(segs, &subbyte_seg?/1) do
      create_bin_bits(segs, val)
    else
      blen_expr =
        Enum.reduce(segs, "(i32.const 0)", fn seg, acc ->
          "(i32.add #{acc} #{seg_len(seg, val)})"
        end)

      setup = [
        "(local.set $blen #{blen_expr})",
        "(local.set $bdst (array.new_default $bytes (local.get $blen)))",
        "(local.set $boff (i32.const 0))"
      ]

      blits = Enum.flat_map(segs, &blit_seg(&1, val))
      {setup ++ blits, "(struct.new $binary (ref.as_non_null (local.get $bdst)))"}
    end
  end

  # ── bit-mode construction: any sub-byte/dynamic-size integer segment, a float segment, or a
  # binary segment whose SOURCE may be a $bitstr switches the build to bit-level writes
  # ($bits_write/$bits_copy, MSB-first; $boff/$blen track BITS, computed at runtime in two passes).
  # The result is a $bitstr when the total isn't byte-aligned, else a normal $binary.
  defp subbyte_seg?([{:atom, :integer}, _fl, u, _n, _src, {:integer, sz}]), do: rem(sz * u, 8) != 0
  defp subbyte_seg?([{:atom, :integer}, _fl, _u, _n, _src, sz]) when not is_integer(sz), do: true
  defp subbyte_seg?([{:atom, :float} | _]), do: true
  defp subbyte_seg?(_), do: false

  # runtime bit-length expression of one segment
  defp seg_bits_expr([{:atom, :integer}, _fl, u, _n, _src, {:integer, sz}], _val), do: "(i32.const #{sz * u})"

  defp seg_bits_expr([{:atom, :integer}, _fl, u, _n, _src, sz], _val),
    do: "(i32.mul #{i32val(sz)} (i32.const #{u}))"

  defp seg_bits_expr([{:atom, :float}, _fl, u, _n, _src, {:integer, sz}], _val) when sz * u == 64,
    do: "(i32.const 64)"

  defp seg_bits_expr([{:atom, t}, _fl, _u, _n, src, {:atom, :all}], val)
       when t in [:binary, :append, :private_append] do
    "(if (result i32) (ref.test (ref $bitstr) #{val.(src)}) " <>
      "(then (struct.get $bitstr 1 (ref.cast (ref $bitstr) #{val.(src)}))) " <>
      "(else (i32.shl (array.len (struct.get $binary 0 (ref.cast (ref $binary) #{val.(src)}))) (i32.const 3))))"
  end

  defp seg_bits_expr([{:atom, :binary}, _fl, u, _n, _src, {:integer, sz}], _val),
    do: "(i32.const #{sz * u * 8})"

  defp seg_bits_expr([{:atom, :string}, _fl, _u, _n, {:string, str}, _sz], _val),
    do: "(i32.const #{byte_size(str) * 8})"

  defp seg_bits_expr(seg, _val), do: raise("bit-mode bs_create_bin segment unsupported: #{inspect(seg)}")

  defp create_bin_bits(segs, val) do
    blen_expr =
      Enum.reduce(segs, "(i32.const 0)", fn seg, acc -> "(i32.add #{acc} #{seg_bits_expr(seg, val)})" end)

    setup = [
      "(local.set $blen #{blen_expr})",
      "(local.set $bdst (array.new_default $bytes (i32.div_u (i32.add (local.get $blen) (i32.const 7)) (i32.const 8))))",
      "(local.set $boff (i32.const 0))"
    ]

    blits =
      Enum.flat_map(segs, fn seg ->
        bits = seg_bits_expr(seg, val)

        write =
          case seg do
            [{:atom, :integer}, _fl, _u, _n, src, _sz] ->
              "(call $bits_write (ref.as_non_null (local.get $bdst)) (local.get $boff) #{bits} (call $term_i64 #{val.(src)}))"

            [{:atom, :float}, _fl, _u, _n, src, _sz] ->
              "(call $bits_write (ref.as_non_null (local.get $bdst)) (local.get $boff) #{bits} (i64.reinterpret_f64 (struct.get $float 0 (ref.cast (ref $float) #{val.(src)}))))"

            [{:atom, t}, _fl, _u, _n, src, _sz] when t in [:binary, :append, :private_append] ->
              "(call $bits_copy " <>
                "(if (result (ref $bytes)) (ref.test (ref $bitstr) #{val.(src)}) " <>
                "(then (struct.get $bitstr 0 (ref.cast (ref $bitstr) #{val.(src)}))) " <>
                "(else (struct.get $binary 0 (ref.cast (ref $binary) #{val.(src)})))) " <>
                "(i32.const 0) (ref.as_non_null (local.get $bdst)) (local.get $boff) #{bits})"

            [{:atom, :string}, _fl, _u, _n, {:string, str}, _sz] ->
              "(call $bits_copy (struct.get $binary 0 (ref.cast (ref $binary) #{materialize(str)})) (i32.const 0) (ref.as_non_null (local.get $bdst)) (local.get $boff) #{bits})"
          end

        [write, "(local.set $boff (i32.add (local.get $boff) #{bits}))"]
      end)

    result =
      "(if (result (ref null eq)) (i32.rem_u (local.get $blen) (i32.const 8)) " <>
        "(then (struct.new $bitstr (ref.as_non_null (local.get $bdst)) (local.get $blen))) " <>
        "(else (struct.new $binary (ref.as_non_null (local.get $bdst)))))"

    {setup ++ blits, result}
  end

  def seg_len([{:atom, :string}, _fl, _u, _n, {:string, s}, _sz], _val), do: "(i32.const #{byte_size(s)})"
  # :append / :private_append (building on an existing binary, e.g. <<acc::binary, …>>) behave like
  # a whole :binary segment — copy all the bytes of the source binary.
  def seg_len([{:atom, t}, _fl, _u, _n, src, {:atom, :all}], val)
      when t in [:binary, :append, :private_append],
      do: "(array.len (struct.get $binary 0 (ref.cast (ref $binary) #{val.(src)})))"

  def seg_len([{:atom, :binary}, _fl, _u, _n, _src, {:integer, n}], _val), do: "(i32.const #{n})"

  def seg_len([{:atom, :integer}, _fl, u, _n, _src, {:integer, sz}], _val),
    do: "(i32.const #{div(sz * u, 8)})"

  def seg_len([{:atom, :utf8}, _fl, _u, _n, src, {:atom, :undefined}], _val),
    do: "(call $utf8_enc_len #{i32val(src)})"

  def seg_len(seg, _val), do: raise("bs_create_bin seg_len unsupported: #{inspect(seg)}")

  def blit_seg([{:atom, :string}, _fl, _u, _n, {:string, s}, _sz], _val) do
    bytes = :binary.bin_to_list(s)

    sets =
      bytes
      |> Enum.with_index()
      |> Enum.map(fn {byte, k} ->
        "(array.set $bytes (local.get $bdst) (i32.add (local.get $boff) (i32.const #{k})) (i32.const #{byte}))"
      end)

    sets ++ ["(local.set $boff (i32.add (local.get $boff) (i32.const #{length(bytes)})))"]
  end

  def blit_seg([{:atom, t}, _fl, _u, _n, src, _size], val) when t in [:binary, :append, :private_append] do
    s = val.(src)

    [
      "(local.set $bsrc (struct.get $binary 0 (ref.cast (ref $binary) #{s})))",
      "(array.copy $bytes $bytes (local.get $bdst) (local.get $boff) (local.get $bsrc) (i32.const 0) (array.len (local.get $bsrc)))",
      "(local.set $boff (i32.add (local.get $boff) (array.len (local.get $bsrc))))"
    ]
  end

  def blit_seg([{:atom, :integer}, _fl, u, flags, src, {:integer, sz}], val) do
    nbytes = div(sz * u, 8)
    little? = match?({:literal, fl} when is_list(fl), flags) and :little in elem(flags, 1)
    # value via $term_i64 (an i31 cast would trap on $i64/$big-tier values, e.g. a 32-bit payload
    # above 2^30); byte order from the segment flags ([:little] in the flags slot).
    sets =
      for k <- 0..(nbytes - 1) do
        shift = if(little?, do: k, else: nbytes - 1 - k) * 8

        "(array.set $bytes (local.get $bdst) (i32.add (local.get $boff) (i32.const #{k})) (i32.and (i32.wrap_i64 (i64.shr_u (call $term_i64 #{val.(src)}) (i64.const #{shift}))) (i32.const 255)))"
      end

    sets ++ ["(local.set $boff (i32.add (local.get $boff) (i32.const #{nbytes})))"]
  end

  def blit_seg([{:atom, :utf8}, _fl, _u, _n, src, {:atom, :undefined}], _val) do
    ["(local.set $boff (call $utf8_enc (local.get $bdst) (local.get $boff) #{i32val(src)}))"]
  end

  def blit_seg(seg, _val), do: raise("bs_create_bin blit unsupported: #{inspect(seg)}")

  # fold a list of [k1,v1,k2,v2,...] into nested $map_put calls over a source-map expr
  def fold_map_put(src_expr, kvs, val) do
    kvs
    |> Enum.chunk_every(2)
    |> Enum.reduce(src_expr, fn [k, v], acc ->
      "(call $map_put #{acc} #{val.(k)} #{val.(v)})"
    end)
  end

  # Build a map from put_map_assoc/exact. Fast path: when the source is the empty map and every
  # key is a compile-time constant, dedup (last wins) + sort the pairs by Erlang term order at
  # COMPILE time and emit the whole kv array in one `array.new_fixed` — O(k) instead of the O(k²)
  # chain of copy-on-write $map_put calls. (Elixir's term order matches $term_compare, so the
  # array is already in the canonical sorted order the rest of the runtime expects.) Otherwise
  # fall back to the general chained build, which is always correct.
  def build_map(src, kvs, val) do
    pairs = kvs |> Enum.chunk_every(2) |> Enum.map(fn [k, v] -> {k, v} end)

    static? =
      match?({:literal, %{}}, src) and Enum.all?(pairs, fn {k, _} -> match?({:ok, _}, key_term(k)) end)

    if static? do
      ordered =
        pairs
        |> Enum.reduce(%{}, fn {k, v}, acc ->
          {:ok, kt} = key_term(k)
          Map.put(acc, kt, {k, v})
        end)
        # default sorter = Erlang term order
        |> Enum.sort_by(fn {kt, _} -> kt end)
        |> Enum.map(fn {_kt, kv} -> kv end)

      # keys are statically sorted -> emit the BALANCED TREE directly (dynamic value exprs). Exactly
      # K node allocations, ZERO runtime comparisons/rebalancing (vs $map_from_kv's K inserts).
      "(struct.new $map #{build_tree_expr(Enum.map(ordered, fn {k, v} -> {val.(k), val.(v)} end))})"
    else
      fold_map_put(val.(src), kvs, val)
    end
  end

  # balanced tree from a key-sorted list of {key_wat, val_wat} (pre-rendered WAT). Median = root.
  def build_tree_expr([]), do: "(ref.null $mnode)"

  def build_tree_expr(pairs) do
    n = length(pairs)
    {left, [{k, v} | right]} = Enum.split(pairs, div(n, 2))
    "(struct.new $mnode #{k} #{v} #{build_tree_expr(left)} #{build_tree_expr(right)} (i32.const #{n}))"
  end

  # the literal term of a constant key operand (for compile-time map sorting), or :dynamic
  def key_term({:integer, n}), do: {:ok, n}
  def key_term({:atom, a}), do: {:ok, a}
  # bare nil operand = the empty list
  def key_term(nil), do: {:ok, []}
  def key_term({:literal, t}), do: {:ok, t}
  def key_term({:tr, reg, _}), do: key_term(reg)
  def key_term(_), do: :dynamic

  # a constant term (from beam_disasm's {:literal, _}) -> WAT that constructs it
  def materialize(n) when is_integer(n), do: int_literal(n)
  def materialize(f) when is_float(f), do: "(struct.new $float (f64.const #{float_lit(f)}))"
  # the atom nil (distinct from [] below)
  def materialize(nil), do: "(global.get $atom_nil)"
  # the empty list
  def materialize([]), do: "(ref.null none)"
  # constant binaries (string keys/values like "qty", SKU codes) are hoisted too — otherwise each use
  # re-allocates a $binary + $bytes. Immutable globals, built once. (Binaries are never mutated.)
  def materialize(b) when is_binary(b) and byte_size(b) > 0 and byte_size(b) <= 9_999,
    do: hoist_const({:bin, b}, fn -> bin_literal(b) end)

  # >9999 bytes: array.new_fixed is V8-capped and array.new_data is not a constant expression —
  # build inline at the use site from a data segment (never hoisted to a global).
  def materialize(b) when is_binary(b) and byte_size(b) > 9_999, do: bin_literal(b)
  def materialize(b) when is_binary(b), do: bin_literal(b)
  # sub-byte bitstring literal (<<5::3>>): bytes MSB-padded + explicit bit length
  def materialize(b) when is_bitstring(b) do
    bits = bit_size(b)
    pad = 8 - rem(bits, 8)
    <<v::size(bits)>> = b
    bytes = :binary.bin_to_list(<<v::size(bits), 0::size(pad)>>)
    inner = if bytes == [], do: "", else: " " <> Enum.map_join(bytes, " ", &"(i32.const #{&1})")
    "(struct.new $bitstr (array.new_fixed $bytes #{length(bytes)}#{inner}) (i32.const #{bits}))"
  end

  def materialize(a) when is_atom(a), do: "(global.get $atom_#{sanitize(a)})"

  def materialize(f) when is_function(f) do
    info = :erlang.fun_info(f)
    m = Keyword.fetch!(info, :module)
    name = Keyword.fetch!(info, :name)
    arity = Keyword.fetch!(info, :arity)

    "(struct.new $fun (i32.const #{Process.get(:tramp_base) + arity}) (array.new_fixed $freevars 2 (global.get $atom_#{sanitize(m)}) (global.get $atom_#{sanitize(name)})))"
  end

  # Constant maps are HOISTED to immutable module globals, built ONCE as a compile-time-constant
  # balanced tree (nested struct.new $mnode — a valid global initializer). Otherwise the literal would
  # be re-materialized (a full tree rebuild) at every use site — e.g. `Map.get(@prices, sku)` would
  # rebuild @prices on every lookup. (Was the dominant cost in the realistic/decimal workloads.)
  def materialize(m) when is_map(m) and map_size(m) > 0 do
    # a >i64 integer anywhere inside materializes via host bigint CALLS — not a valid Wasm
    # constant expression, so such a literal must be built inline at the use site, not hoisted.
    if const_exprable?(m), do: hoist_const(m, fn -> const_map_expr(m) end), else: const_map_expr(m)
  end

  def materialize(m) when is_map(m), do: "(struct.new $map (ref.null $mnode))"

  def materialize([h | t]), do: "(struct.new $cons #{materialize(h)} #{materialize(t)})"

  def materialize(t) when is_tuple(t) do
    elems = Tuple.to_list(t)
    "(array.new_fixed $tuple #{length(elems)} #{Enum.map_join(elems, " ", &materialize/1)})"
  end

  # Unhandled literal kinds (external fun captures &M.f/a, floats, bitstrings of odd shape)
  # appear only on non-list Enum paths. In STUB mode, null them so the module still builds.
  def materialize(other) do
    # never emit a usable nil for an unsupported literal — that silently flows on as a wrong value
    # (the operand-fallback lesson). Trap and COUNT it like every other stub.
    if Process.get(:stub) do
      Process.put(:stubs, (Process.get(:stubs) || 0) + 1)
      "(unreachable) (; STUB literal #{inspect(other) |> String.slice(0, 40) |> String.replace(";", ",")} ;)"
    else
      raise("materialize: #{inspect(other)}")
    end
  end

  def const_exprable?(n) when is_integer(n),
    do: not Process.get(:bignum) or (n >= -9_223_372_036_854_775_808 and n <= 9_223_372_036_854_775_807)

  def const_exprable?(b) when is_binary(b), do: byte_size(b) <= 9_999
  # NB: Map.to_list, not Enum — struct literals (%Earmark.Options{}) have no Enumerable impl
  def const_exprable?(m) when is_map(m),
    do: m |> Map.to_list() |> Enum.all?(fn {k, v} -> const_exprable?(k) and const_exprable?(v) end)

  def const_exprable?([h | t]), do: const_exprable?(h) and const_exprable?(t)
  def const_exprable?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.all?(&const_exprable?/1)
  def const_exprable?(_), do: true

  def const_map_expr(m) do
    # Erlang term order (Elixir's default sort) = tree order
    pairs = Map.to_list(m) |> Enum.sort()
    "(struct.new $map #{const_tree(pairs)})"
  end

  def const_tree([]), do: "(ref.null $mnode)"

  def const_tree(pairs) do
    n = length(pairs)
    # median root -> balanced
    {left, [{k, v} | right]} = Enum.split(pairs, div(n, 2))

    "(struct.new $mnode #{materialize(k)} #{materialize(v)} #{const_tree(left)} #{const_tree(right)} (i32.const #{n}))"
  end

  # register a constant -> an immutable global (dedup by value); returns a (global.get …). Nested
  # consts registered during expr_fun get LOWER indices (declared first), so a parent's initializer
  # may reference them via global.get.
  def hoist_const(term, expr_fun) do
    case Map.get(Process.get(:consts, %{}), term) do
      nil ->
        expr = expr_fun.()
        idx = Process.get(:const_n, 0)
        Process.put(:const_n, idx + 1)
        Process.put(:consts, Map.put(Process.get(:consts, %{}), term, idx))
        Process.put(:const_defs, [{idx, expr} | Process.get(:const_defs, [])])
        "(global.get $const#{idx})"

      idx ->
        "(global.get $const#{idx})"
    end
  end

  def int_literal(n) when n >= @i31_lo and n <= @i31_hi, do: "(ref.i31 (i32.const #{n}))"

  def int_literal(n) do
    cond do
      not Process.get(:bignum) ->
        "(ref.i31 (i32.const #{n}))"

      # fits i64: build the middle tier directly — no host BigInt digit-chain at all.
      n >= -9_223_372_036_854_775_808 and n <= 9_223_372_036_854_775_807 ->
        "(struct.new $i64 (i64.const #{n}))"

      true ->
        "(struct.new $big #{bigint_const_expr(n)})"
    end
  end

  def bigint_const_expr(n) do
    sign = if n < 0, do: -1, else: 1
    digits = Integer.to_string(abs(n)) |> String.to_charlist() |> Enum.map(&(&1 - ?0))
    zero = "(call $bigint_from_i64 (i64.const 0))"

    expr =
      Enum.reduce(digits, zero, fn digit, acc ->
        "(call $bigint_add (call $bigint_mul #{acc} (call $bigint_from_i64 (i64.const 10))) (call $bigint_from_i64 (i64.const #{digit})))"
      end)

    if sign < 0,
      do: "(call $bigint_sub (call $bigint_from_i64 (i64.const 0)) #{expr})",
      else: expr
  end
end
