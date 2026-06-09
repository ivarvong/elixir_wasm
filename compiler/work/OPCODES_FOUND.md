# Real opcode surface probed via :beam_disasm (OTP 27 / Elixir 1.17)

## Arithmetic tail (all `gc_bif`, easy)
- `{:gc_bif, :div,  {:f,0}, 2, [a,b], d}`  -> i32.div_s
- `{:gc_bif, :rem,  {:f,0}, 2, [a,b], d}`  -> i32.rem_s
- `{:gc_bif, :band, {:f,0}, 2, [a,b], d}`  -> i32.and
- `{:gc_bif, :bor,  {:f,0}, 2, [a,b], d}`  -> i32.or
- `{:gc_bif, :bxor, {:f,0}, 2, [a,b], d}`  -> i32.xor
- `{:gc_bif, :bsl,  {:f,0}, 2, [a,b], d}`  -> i32.shl
- `{:gc_bif, :bsr,  {:f,0}, 2, [a,b], d}`  -> i32.shr_s
- `{:gc_bif, :-,    {:f,0}, 1, [a],   d}`  -> unary negate (NEW arity-1 gc_bif clause)
- `{:gc_bif, :byte_size, {:f,0}, 1, [a], d}` -> array.len of binary bytes

## Guards (all `{:test, is_*, {:f,L}, [x]}`)
- is_integer -> ref.test (ref i31)  (+ $big in BIGNUM mode)
- is_atom    -> ref.test (ref $atom)
- is_list    -> ref.is_null OR ref.test (ref $cons)
- is_binary  -> ref.test (ref $binary)
- is_tuple   -> ref.test (ref $tuple)   [have]
- is_map     -> ref.test (ref $map)     [have]

## Strings / binary construction
- string literal "abc" arrives as an Erlang binary literal (materialize: is_binary host clause)
- `<>` / `<<>>`:
  `{:bs_create_bin, {:f,0}, 0, Live, Unit, Dst, {:list, SEGS}}`
  SEGS = groups of 6: [Type, Flags, Unit, nil, Src, Size]
    string seg: [:string, 0, 8, nil, {:string,"Hello, "}, {:integer,7}]
    binary seg: [:binary, 2, 8, nil, {:x,0},            {:atom,:all}]
  -> allocate i8 array of total bytes, blit each segment, wrap in $binary

## Binary matching (modern OTP bs_match family)
- `{:test, :bs_start_match3, {:f,Fail}, Live, [Src], CtxDst}` -> if not binary jump Fail; else make match ctx {bytes, bitpos=0}
- `{:bs_get_position, Ctx, Dst, Live}`  -> Dst = ctx.bitpos (as i31)
- `{:bs_set_position, Ctx, Pos}`        -> ctx.bitpos = Pos
- `{:bs_get_tail, Ctx, Dst, Live}`      -> Dst = new $binary from bytes[bitpos/8 ..]
- `{:bs_match, {:f,Fail}, Ctx, {:commands, CMDS}}`:
    {:ensure_at_least, Bits, Unit}              -> if remaining < Bits jump Fail
    {:integer, Live, Flags, Size, Unit, Dst}    -> Dst = read Size*Unit bits (BE), advance
    {:"=:=", nil, Bits, Value}                  -> read Bits, if != Value jump Fail, advance
  MVP assumption: byte-aligned (bitpos % 8 == 0), sizes multiple of 8 (covers strings/bytes).
