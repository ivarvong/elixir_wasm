# Shared leaf helpers used by BOTH the runtime library (Codegen.Runtime) and the emit path in
# Beam2Wasm. Extracted verbatim from beam2wasm.exs (defp -> def); pure string/term production +
# process-dictionary reads, no other compiler dependencies.
defmodule Codegen.Common do
  # Erlang `==`/`=:=` as an i32 (1/0), given two already-rendered term operands. In bignum mode
  # two equal-valued integers may be *distinct* boxed $big structs, so a bare ref.eq false-negatives:
  # treat them equal if ref.eq OR (both integers AND $int_cmp == 0). Non-integer terms collapse
  # back to ref.eq (unchanged behavior, and the non-bignum default).
  def term_eq(a, b) do
    # SHORT-CIRCUIT on ref.eq: equal immediates (i31/atoms) and same-ref boxes answer immediately
    # WITHOUT calling term_compare. (i32.or evaluates both sides, so the old form called term_compare
    # on EVERY equality — a storm in select_val/pattern matching. This is the common-case fast path.)
    base =
      "(if (result i32) (ref.eq #{a} #{b}) (then (i32.const 1)) " <>
      "(else (if (result i32) (i32.or (ref.test (ref $fun) #{a}) (ref.test (ref $fun) #{b})) " <>
      "(then (i32.const 0)) (else (i32.eqz (call $term_compare #{a} #{b}))))))"
    # In proc mode, two distinct pid/ref boxes with the same id are equal (compare by id, not identity).
    # NB: the id-compare must be GUARDED by an `if` — i32.and doesn't short-circuit, so an unguarded
    # `ref.cast $pid` would trap when either operand isn't a pid (e.g. comparing `x == nil`).
    if Process.get(:proc) do
      id = fn t, x -> "(struct.get $#{t} 0 (ref.cast (ref $#{t}) #{x}))" end
      both = fn t -> "(i32.and (ref.test (ref $#{t}) #{a}) (ref.test (ref $#{t}) #{b}))" end
      eqid = fn t -> "(if (result i32) #{both.(t)} (then (i32.eq #{id.(t, a)} #{id.(t, b)})) (else (i32.const 0)))" end
      "(i32.or #{base} (i32.or #{eqid.("pid")} #{eqid.("ref")}))"
    else
      base
    end
  end

  def sanitize(name) when is_atom(name), do: sanitize(Atom.to_string(name))
  # injective: keep [A-Za-z0-9_]; escape every other char as _<code>_ so distinct atoms
  # (e.g. :+, :-, :*) get distinct names (no global-name / function-name collisions).
  def sanitize(name) when is_binary(name) do
    name
    |> String.to_charlist()
    |> Enum.map_join(fn c ->
      cond do
        c >= ?a and c <= ?z -> <<c>>
        c >= ?A and c <= ?Z -> <<c>>
        c >= ?0 and c <= ?9 -> <<c>>
        c == ?_ -> "_"
        true -> "_#{c}_"
      end
    end)
  end

  # minimal JSON array-of-strings encoder (no deps) for the @atoms table comment

  # a constant binary -> a $binary built byte-by-byte from an array.new_fixed
  def bin_literal(b) do
    bytes = :binary.bin_to_list(b)
    inner = if bytes == [], do: "", else: " " <> Enum.map_join(bytes, " ", &"(i32.const #{&1})")
    "(struct.new $binary (array.new_fixed $bytes #{length(bytes)}#{inner}))"
  end
end
