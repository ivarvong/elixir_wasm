# The hand-written WasmGC runtime library as WAT strings: term/list/map(BST)/binary helpers, the
# 3-tier bignum ops, exception glue, floats, and the native-BIF shims. Extracted verbatim from
# beam2wasm.exs (defp -> def). Assembled by Beam2Wasm.run; imports Codegen.Common for the two
# shared leaves it calls (term_eq, bin_literal). Independent of the emit path (AST-confirmed).
defmodule Codegen.Runtime do
  import Codegen.Common
  # JS<->Wasm bridge for list terms (build/walk cons cells from the harness)
  def helpers do
    """
      (func (export "nil") (result (ref null eq)) (ref.null none))
      (func (export "cons") (param $h i32) (param $t (ref null eq)) (result (ref null eq))
        (struct.new $cons (ref.i31 (local.get $h)) (local.get $t)))
      ;; --- binary JS bridge: build/read $binary terms across the boundary ---
      (func (export "bin_alloc") (param $n i32) (result (ref null eq))
        (struct.new $binary (array.new_default $bytes (local.get $n))))
      (func (export "bin_put") (param $b (ref null eq)) (param $i i32) (param $v i32)
        (array.set $bytes (struct.get $binary 0 (ref.cast (ref $binary) (local.get $b))) (local.get $i) (local.get $v)))
      (func (export "bin_len") (param $b (ref null eq)) (result i32)
        (array.len (struct.get $binary 0 (ref.cast (ref $binary) (local.get $b)))))
      (func (export "bin_get") (param $b (ref null eq)) (param $i i32) (result i32)
        (array.get_u $bytes (struct.get $binary 0 (ref.cast (ref $binary) (local.get $b))) (local.get $i)))
      (func (export "is_bin") (param $b (ref null eq)) (result i32) (ref.test (ref $binary) (local.get $b)))
      (func (export "get_int") (param $x (ref null eq)) (result i32) (i31.get_s (ref.cast (ref i31) (local.get $x))))
      (func (export "mk_int") (param $v i32) (result (ref null eq)) (ref.i31 (local.get $v)))
      ;; --- tuple / atom JS bridge: read a returned term across the boundary ---
      (func (export "is_tuple") (param $t (ref null eq)) (result i32) (ref.test (ref $tuple) (local.get $t)))
      (func (export "tup_len") (param $t (ref null eq)) (result i32) (array.len (ref.cast (ref $tuple) (local.get $t))))
      (func (export "tup_get") (param $t (ref null eq)) (param $i i32) (result (ref null eq))
        (array.get $tuple (ref.cast (ref $tuple) (local.get $t)) (local.get $i)))
      (func (export "is_atom") (param $t (ref null eq)) (result i32) (ref.test (ref $atom) (local.get $t)))
      (func (export "atom_idx") (param $t (ref null eq)) (result i32) (struct.get $atom 0 (ref.cast (ref $atom) (local.get $t))))
      (func $list_len (param $l (ref null eq)) (result i32) (local $n i32)
        (block $done (loop $lp
          (br_if $done (i32.eqz (ref.test (ref $cons) (local.get $l))))
          (local.set $n (i32.add (local.get $n) (i32.const 1)))
          (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
          (br $lp)))
        (local.get $n))
      (func (export "is_cons") (param $l (ref null eq)) (result i32) (ref.test (ref $cons) (local.get $l)))
      (func (export "head") (param $l (ref null eq)) (result i32)
        (i31.get_s (ref.cast (ref i31) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))))
      (func (export "tail") (param $l (ref null eq)) (result (ref null eq))
        (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
      ;; ── weight-balanced BST internals (Adams' algorithm, delta=3 gamma=2). Persistent: every
      ;; mutation path-copies, so old maps stay valid. Node fields 0=key 1=val 2=left 3=right 4=size.
      (func $msz (param $t (ref null $mnode)) (result i32)
        (if (result i32) (ref.is_null (local.get $t)) (then (i32.const 0))
          (else (struct.get $mnode 4 (ref.as_non_null (local.get $t))))))
      (func $mnew (param $k (ref null eq)) (param $v (ref null eq)) (param $l (ref null $mnode)) (param $r (ref null $mnode)) (result (ref $mnode))
        (struct.new $mnode (local.get $k) (local.get $v) (local.get $l) (local.get $r)
          (i32.add (i32.const 1) (i32.add (call $msz (local.get $l)) (call $msz (local.get $r))))))
      (func $mrotL (param $k (ref null eq)) (param $v (ref null eq)) (param $l (ref null $mnode)) (param $r (ref $mnode)) (result (ref $mnode))
        (call $mnew (struct.get $mnode 0 (local.get $r)) (struct.get $mnode 1 (local.get $r))
          (call $mnew (local.get $k) (local.get $v) (local.get $l) (struct.get $mnode 2 (local.get $r)))
          (struct.get $mnode 3 (local.get $r))))
      (func $mrotR (param $k (ref null eq)) (param $v (ref null eq)) (param $l (ref $mnode)) (param $r (ref null $mnode)) (result (ref $mnode))
        (call $mnew (struct.get $mnode 0 (local.get $l)) (struct.get $mnode 1 (local.get $l))
          (struct.get $mnode 2 (local.get $l))
          (call $mnew (local.get $k) (local.get $v) (struct.get $mnode 3 (local.get $l)) (local.get $r))))
      (func $mrotLR (param $k (ref null eq)) (param $v (ref null eq)) (param $l (ref null $mnode)) (param $r (ref $mnode)) (result (ref $mnode))
        (local $rl (ref $mnode))
        (local.set $rl (ref.cast (ref $mnode) (struct.get $mnode 2 (local.get $r))))
        (call $mnew (struct.get $mnode 0 (local.get $rl)) (struct.get $mnode 1 (local.get $rl))
          (call $mnew (local.get $k) (local.get $v) (local.get $l) (struct.get $mnode 2 (local.get $rl)))
          (call $mnew (struct.get $mnode 0 (local.get $r)) (struct.get $mnode 1 (local.get $r)) (struct.get $mnode 3 (local.get $rl)) (struct.get $mnode 3 (local.get $r)))))
      (func $mrotRL (param $k (ref null eq)) (param $v (ref null eq)) (param $l (ref $mnode)) (param $r (ref null $mnode)) (result (ref $mnode))
        (local $lr (ref $mnode))
        (local.set $lr (ref.cast (ref $mnode) (struct.get $mnode 3 (local.get $l))))
        (call $mnew (struct.get $mnode 0 (local.get $lr)) (struct.get $mnode 1 (local.get $lr))
          (call $mnew (struct.get $mnode 0 (local.get $l)) (struct.get $mnode 1 (local.get $l)) (struct.get $mnode 2 (local.get $l)) (struct.get $mnode 2 (local.get $lr)))
          (call $mnew (local.get $k) (local.get $v) (struct.get $mnode 3 (local.get $lr)) (local.get $r))))
      (func $mbal (param $k (ref null eq)) (param $v (ref null eq)) (param $l (ref null $mnode)) (param $r (ref null $mnode)) (result (ref $mnode))
        (local $ln i32) (local $rn i32)
        (local.set $ln (call $msz (local.get $l)))
        (local.set $rn (call $msz (local.get $r)))
        (if (result (ref $mnode)) (i32.le_u (i32.add (local.get $ln) (local.get $rn)) (i32.const 1))
          (then (call $mnew (local.get $k) (local.get $v) (local.get $l) (local.get $r)))
          (else (if (result (ref $mnode)) (i32.gt_u (local.get $rn) (i32.mul (i32.const 3) (local.get $ln)))
            (then (if (result (ref $mnode))
                (i32.lt_u (call $msz (struct.get $mnode 2 (ref.as_non_null (local.get $r)))) (i32.mul (i32.const 2) (call $msz (struct.get $mnode 3 (ref.as_non_null (local.get $r))))))
                (then (call $mrotL (local.get $k) (local.get $v) (local.get $l) (ref.as_non_null (local.get $r))))
                (else (call $mrotLR (local.get $k) (local.get $v) (local.get $l) (ref.as_non_null (local.get $r))))))
            (else (if (result (ref $mnode)) (i32.gt_u (local.get $ln) (i32.mul (i32.const 3) (local.get $rn)))
              (then (if (result (ref $mnode))
                  (i32.lt_u (call $msz (struct.get $mnode 3 (ref.as_non_null (local.get $l)))) (i32.mul (i32.const 2) (call $msz (struct.get $mnode 2 (ref.as_non_null (local.get $l))))))
                  (then (call $mrotR (local.get $k) (local.get $v) (ref.as_non_null (local.get $l)) (local.get $r)))
                  (else (call $mrotRL (local.get $k) (local.get $v) (ref.as_non_null (local.get $l)) (local.get $r)))))
              (else (call $mnew (local.get $k) (local.get $v) (local.get $l) (local.get $r)))))))))
      (func $mput (param $t (ref null $mnode)) (param $k (ref null eq)) (param $v (ref null eq)) (result (ref $mnode))
        (local $c i32)
        (if (result (ref $mnode)) (ref.is_null (local.get $t))
          (then (call $mnew (local.get $k) (local.get $v) (ref.null $mnode) (ref.null $mnode)))
          (else
            (local.set $c (call $term_compare (local.get $k) (struct.get $mnode 0 (ref.as_non_null (local.get $t)))))
            (if (result (ref $mnode)) (i32.lt_s (local.get $c) (i32.const 0))
              (then (call $mbal (struct.get $mnode 0 (ref.as_non_null (local.get $t))) (struct.get $mnode 1 (ref.as_non_null (local.get $t)))
                      (call $mput (struct.get $mnode 2 (ref.as_non_null (local.get $t))) (local.get $k) (local.get $v))
                      (struct.get $mnode 3 (ref.as_non_null (local.get $t)))))
              (else (if (result (ref $mnode)) (i32.gt_s (local.get $c) (i32.const 0))
                (then (call $mbal (struct.get $mnode 0 (ref.as_non_null (local.get $t))) (struct.get $mnode 1 (ref.as_non_null (local.get $t)))
                        (struct.get $mnode 2 (ref.as_non_null (local.get $t)))
                        (call $mput (struct.get $mnode 3 (ref.as_non_null (local.get $t))) (local.get $k) (local.get $v))))
                (else (call $mnew (local.get $k) (local.get $v) (struct.get $mnode 2 (ref.as_non_null (local.get $t))) (struct.get $mnode 3 (ref.as_non_null (local.get $t)))))))))))
      (func $mfind (param $t (ref null $mnode)) (param $k (ref null eq)) (result (ref null $mnode))
        (local $c i32)
        (block $done (loop $lp
          (br_if $done (ref.is_null (local.get $t)))
          (local.set $c (call $term_compare (local.get $k) (struct.get $mnode 0 (ref.as_non_null (local.get $t)))))
          (if (i32.eqz (local.get $c)) (then (return (local.get $t))))
          (local.set $t (if (result (ref null $mnode)) (i32.lt_s (local.get $c) (i32.const 0))
            (then (struct.get $mnode 2 (ref.as_non_null (local.get $t)))) (else (struct.get $mnode 3 (ref.as_non_null (local.get $t))))))
          (br $lp)))
        (ref.null $mnode))
      ;; i-th node in key order (0-based) via subtree sizes — O(log n); used by map iteration.
      (func $msel (param $t (ref null $mnode)) (param $i i32) (result (ref null $mnode))
        (local $ls i32)
        (block $done (loop $lp
          (br_if $done (ref.is_null (local.get $t)))
          (local.set $ls (call $msz (struct.get $mnode 2 (ref.as_non_null (local.get $t)))))
          (if (i32.lt_u (local.get $i) (local.get $ls))
            (then (local.set $t (struct.get $mnode 2 (ref.as_non_null (local.get $t)))))
            (else (if (i32.eq (local.get $i) (local.get $ls))
              (then (return (local.get $t)))
              (else (local.set $i (i32.sub (local.get $i) (i32.add (local.get $ls) (i32.const 1))))
                    (local.set $t (struct.get $mnode 3 (ref.as_non_null (local.get $t))))))))
          (br $lp)))
        (ref.null $mnode))
      (func $mflat (param $t (ref null $mnode)) (param $a (ref $tuple)) (param $i i32) (result i32)
        (if (result i32) (ref.is_null (local.get $t)) (then (local.get $i))
          (else
            (local.set $i (call $mflat (struct.get $mnode 2 (ref.as_non_null (local.get $t))) (local.get $a) (local.get $i)))
            (array.set $tuple (local.get $a) (local.get $i) (struct.get $mnode 0 (ref.as_non_null (local.get $t))))
            (array.set $tuple (local.get $a) (i32.add (local.get $i) (i32.const 1)) (struct.get $mnode 1 (ref.as_non_null (local.get $t))))
            (call $mflat (struct.get $mnode 3 (ref.as_non_null (local.get $t))) (local.get $a) (i32.add (local.get $i) (i32.const 2))))))
      ;; ── public map ops over $map = struct{root} ──
      (func $map_root (param $m (ref null eq)) (result (ref null $mnode))
        (struct.get $map 0 (ref.cast (ref $map) (local.get $m))))
      (func $map_size (param $m (ref null eq)) (result i32) (call $msz (call $map_root (local.get $m))))
      ;; returns the matching node (read field 1 for the value) or null if absent — null is an
      ;; unambiguous "absent" since map VALUES are never wasm-null (a present `[]` value is wasm-null,
      ;; so we must NOT use a value sentinel).
      (func $map_get (param $m (ref null eq)) (param $k (ref null eq)) (result (ref null $mnode))
        (return_call $mfind (call $map_root (local.get $m)) (local.get $k)))
      (func $map_has (param $m (ref null eq)) (param $k (ref null eq)) (result i32)
        (i32.eqz (ref.is_null (call $mfind (call $map_root (local.get $m)) (local.get $k)))))
      (func $map_put (param $m (ref null eq)) (param $k (ref null eq)) (param $v (ref null eq)) (result (ref null eq))
        (struct.new $map (call $mput (call $map_root (local.get $m)) (local.get $k) (local.get $v))))
      ;; flatten in-order to a sorted kv array — for the inherently-O(n) consumers (to_list/keys/
      ;; values/merge/equality). NOT used by get/put/size, which are tree-native.
      (func $map_kv (param $m (ref null eq)) (result (ref $tuple))
        (local $a (ref $tuple))
        (local.set $a (array.new_default $tuple (i32.mul (i32.const 2) (call $map_size (local.get $m)))))
        (drop (call $mflat (call $map_root (local.get $m)) (local.get $a) (i32.const 0)))
        (local.get $a))
      (func $map_from_kv (param $a (ref $tuple)) (result (ref null eq))
        (local $t (ref null $mnode)) (local $i i32) (local $n i32)
        (local.set $n (array.len (local.get $a)))
        (block $done (loop $lp
          (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
          (local.set $t (call $mput (local.get $t) (array.get $tuple (local.get $a) (local.get $i)) (array.get $tuple (local.get $a) (i32.add (local.get $i) (i32.const 1)))))
          (local.set $i (i32.add (local.get $i) (i32.const 2)))
          (br $lp)))
        (struct.new $map (local.get $t)))
      ;; binary_part(Subject, Start, Length) -> sub-binary. Subject = a $binary or a $mctx (use its bytes).
      (func $binary_part (param $src (ref null eq)) (param $start i32) (param $len i32) (result (ref null eq))
        (local $s (ref $bytes)) (local $d (ref $bytes))
        (local.set $s (if (result (ref $bytes)) (ref.test (ref $mctx) (local.get $src))
          (then (struct.get $mctx 0 (ref.cast (ref $mctx) (local.get $src))))
          (else (struct.get $binary 0 (ref.cast (ref $binary) (local.get $src))))))
        ;; a NEGATIVE length extracts BACKWARD from Start (Erlang semantics): part = [Start+Len, Start).
        (if (i32.lt_s (local.get $len) (i32.const 0))
          (then (local.set $start (i32.add (local.get $start) (local.get $len)))
                (local.set $len (i32.sub (i32.const 0) (local.get $len)))))
        (local.set $d (array.new_default $bytes (local.get $len)))
        (array.copy $bytes $bytes (local.get $d) (i32.const 0) (local.get $s) (local.get $start) (local.get $len))
        (struct.new $binary (local.get $d)))
      ;; Big-endian bit-slice read from any bit offset. BEAM's optimized binary function heads can
      ;; split string literals into non-byte-aligned chunks, so bs_match must not assume byte offset.
      (func $bits_read (param $b (ref null $bytes)) (param $bitpos i32) (param $nbits i32) (result i32)
        (local $i i32) (local $p i32) (local $byte i32) (local $bit i32) (local $out i32)
        ;; FAST PATH: byte-aligned whole-byte reads (the overwhelmingly common case — byte-aligned
        ;; binary matching, e.g. JSON scanning) read whole bytes directly instead of bit-by-bit (8x).
        (if (i32.and (i32.eqz (i32.rem_u (local.get $bitpos) (i32.const 8))) (i32.eqz (i32.rem_u (local.get $nbits) (i32.const 8))))
          (then
            (local.set $p (i32.div_u (local.get $bitpos) (i32.const 8)))
            (local.set $i (i32.div_u (local.get $nbits) (i32.const 8)))
            (block $bd (loop $bl
              (br_if $bd (i32.eqz (local.get $i)))
              (local.set $out (i32.or (i32.shl (local.get $out) (i32.const 8)) (array.get_u $bytes (ref.cast (ref $bytes) (local.get $b)) (local.get $p))))
              (local.set $p (i32.add (local.get $p) (i32.const 1)))
              (local.set $i (i32.sub (local.get $i) (i32.const 1)))
              (br $bl)))
            (return (local.get $out))))
        (block $done (loop $lp
          (br_if $done (i32.ge_u (local.get $i) (local.get $nbits)))
          (local.set $p (i32.add (local.get $bitpos) (local.get $i)))
          (local.set $byte (array.get_u $bytes (ref.cast (ref $bytes) (local.get $b)) (i32.div_u (local.get $p) (i32.const 8))))
          (local.set $bit (i32.and (i32.shr_u (local.get $byte) (i32.sub (i32.const 7) (i32.rem_u (local.get $p) (i32.const 8)))) (i32.const 1)))
          (local.set $out (i32.or (i32.shl (local.get $out) (i32.const 1)) (local.get $bit)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $lp)))
        (local.get $out))
      ;; read one UTF-8 codepoint from a match context at its (byte-aligned) position, advancing it.
      ;; returns the codepoint, or -1 on a short/invalid sequence.
      (func $mctx_get_utf8 (param $ctx (ref null eq)) (result i32)
        (local $m (ref $mctx)) (local $b (ref $bytes)) (local $off i32) (local $n i32)
        (local $b0 i32) (local $cp i32) (local $len i32) (local $i i32)
        (local.set $m (ref.cast (ref $mctx) (local.get $ctx)))
        (local.set $b (struct.get $mctx 0 (local.get $m)))
        (local.set $off (i32.div_u (struct.get $mctx 1 (local.get $m)) (i32.const 8)))
        (local.set $n (array.len (local.get $b)))
        (if (i32.ge_u (local.get $off) (local.get $n)) (then (return (i32.const -1))))
        (local.set $b0 (array.get_u $bytes (local.get $b) (local.get $off)))
        (if (i32.lt_u (local.get $b0) (i32.const 0x80))
          (then (local.set $cp (local.get $b0)) (local.set $len (i32.const 1)))
          (else (if (i32.lt_u (local.get $b0) (i32.const 0xE0))
            (then (local.set $cp (i32.and (local.get $b0) (i32.const 0x1F))) (local.set $len (i32.const 2)))
            (else (if (i32.lt_u (local.get $b0) (i32.const 0xF0))
              (then (local.set $cp (i32.and (local.get $b0) (i32.const 0x0F))) (local.set $len (i32.const 3)))
              (else (local.set $cp (i32.and (local.get $b0) (i32.const 0x07))) (local.set $len (i32.const 4))))))))
        (if (i32.gt_u (i32.add (local.get $off) (local.get $len)) (local.get $n)) (then (return (i32.const -1))))
        (local.set $i (i32.const 1))
        (block $d (loop $lp
          (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
          (local.set $cp (i32.or (i32.shl (local.get $cp) (i32.const 6))
            (i32.and (array.get_u $bytes (local.get $b) (i32.add (local.get $off) (local.get $i))) (i32.const 0x3F))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $lp)))
        (struct.set $mctx 1 (local.get $m) (i32.add (struct.get $mctx 1 (local.get $m)) (i32.mul (local.get $len) (i32.const 8))))
        (local.get $cp))\
    """
  end

  # Arbitrary-precision integers: i31 fast path; on overflow, box a JS BigInt (externref).
  # All BigInt math is done by the host; the i31 branch keeps small ints fast and unboxed.
  def bignum_imports do
    """
      (import "big" "from_i64"  (func $bigint_from_i64 (param i64) (result externref)))
      (import "big" "from_str"  (func $bigint_from_str (param externref) (result externref)))
      (import "big" "add"       (func $bigint_add (param externref externref) (result externref)))
      (import "big" "sub"       (func $bigint_sub (param externref externref) (result externref)))
      (import "big" "mul"       (func $bigint_mul (param externref externref) (result externref)))
      (import "big" "div"       (func $bigint_div (param externref externref) (result externref)))
      (import "big" "rem"       (func $bigint_rem (param externref externref) (result externref)))
      (import "big" "band"      (func $bigint_band (param externref externref) (result externref)))
      (import "big" "bor"       (func $bigint_bor (param externref externref) (result externref)))
      (import "big" "bxor"      (func $bigint_bxor (param externref externref) (result externref)))
      (import "big" "bsl"       (func $bigint_bsl (param externref externref) (result externref)))
      (import "big" "bsr"       (func $bigint_bsr (param externref externref) (result externref)))
      (import "big" "fits_i31"  (func $bigint_fits_i31 (param externref) (result i32)))
      (import "big" "to_i32"    (func $bigint_to_i32 (param externref) (result i32)))
      (import "big" "fits_i64"  (func $bigint_fits_i64 (param externref) (result i32)))
      (import "big" "to_i64"    (func $bigint_to_i64 (param externref) (result i64)))
      (import "big" "cmp"       (func $bigint_cmp (param externref externref) (result i32)))
      (import "big" "bit_length" (func $bigint_bit_length (param externref) (result i32)))#{if Process.get(:float), do: "\n      (import \"big\" \"to_f64\"    (func $bigint_to_f64 (param externref) (result f64)))\n      (import \"big\" \"from_float\" (func $bigint_from_float (param f64) (result externref)))", else: ""}\
    """
  end

  # float -> integer (trunc semantics) across ALL tiers: i64-fitting floats convert in Wasm;
  # finite floats past 2^63 go to the host for an exact bignum (the VM produces a bignum there,
  # e.g. trunc(Float.max_finite())); NaN/±inf trap honestly (badarith on the VM).
  def f64_to_int_helper do
    """
      (func $f64_to_int (param $x f64) (result (ref null eq))
        (if (f64.ne (local.get $x) (local.get $x)) (then (unreachable)))
        (if (i32.and (f64.lt (local.get $x) (f64.const 9223372036854775808))
                     (f64.ge (local.get $x) (f64.const -9223372036854775808)))
          (then (return (call $narrow (i64.trunc_f64_s (local.get $x))))))
        (if (f64.eq (f64.abs (local.get $x)) (f64.const inf)) (then (unreachable)))
        (call $from_big (call $bigint_from_float (local.get $x))))
    """
  end

  def bignum_helpers do
    """
      ;; ── three-tier integers: i31 (|x|<2^30) → $i64 (fits 64 bits) → $big (host BigInt). The first
      ;; two tiers are computed entirely in Wasm; only true >64-bit values cross to the host.
      (func $is_i64rep (param $x (ref null eq)) (result i32)   ;; i31 OR $i64 (i64-representable)
        (i32.or (ref.test (ref i31) (local.get $x)) (ref.test (ref $i64) (local.get $x))))
      (func $as_i64 (param $x (ref null eq)) (result i64)      ;; precondition: is_i64rep
        (if (result i64) (ref.test (ref i31) (local.get $x))
          (then (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $x)))))
          (else (struct.get $i64 0 (ref.cast (ref $i64) (local.get $x))))))
      (func $to_big (param $x (ref null eq)) (result externref)
        (if (result externref) (call $is_i64rep (local.get $x))
          (then (call $bigint_from_i64 (call $as_i64 (local.get $x))))
          (else (struct.get $big 0 (ref.cast (ref $big) (local.get $x))))))
      (func $narrow (param $v i64) (result (ref null eq))   ;; i64 -> i31 if it fits, else $i64
        (if (result (ref null eq))
            (i32.and (i64.ge_s (local.get $v) (i64.const -1073741824)) (i64.lt_s (local.get $v) (i64.const 1073741824)))
          (then (ref.i31 (i32.wrap_i64 (local.get $v))))
          (else (struct.new $i64 (local.get $v)))))
      (func $from_big (param $r externref) (result (ref null eq))   ;; BigInt -> smallest tier that fits
        (if (result (ref null eq)) (call $bigint_fits_i31 (local.get $r))
          (then (ref.i31 (call $bigint_to_i32 (local.get $r))))
          (else (if (result (ref null eq)) (call $bigint_fits_i64 (local.get $r))
            (then (struct.new $i64 (call $bigint_to_i64 (local.get $r))))
            (else (struct.new $big (local.get $r)))))))
      ;; Each op: TIER 1 both-i31 (inline, cheapest — operands ±2^30 so the i64 result can't overflow,
      ;; just narrow), TIER 2 both-i64rep (native i64 with an overflow check → host on overflow),
      ;; TIER 3 host BigInt. Keeping tier 1 inline-first is what keeps small-int code fast.
      (func $int_add (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
        (local $ia i64) (local $ib i64) (local $r i64)
        (if (result (ref null eq)) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
          (then (call $narrow (i64.add (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $a)))) (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $b)))))))
          (else (if (result (ref null eq)) (i32.and (call $is_i64rep (local.get $a)) (call $is_i64rep (local.get $b)))
            (then
              (local.set $ia (call $as_i64 (local.get $a))) (local.set $ib (call $as_i64 (local.get $b)))
              (local.set $r (i64.add (local.get $ia) (local.get $ib)))
              (if (result (ref null eq)) (i64.lt_s (i64.and (i64.xor (local.get $ia) (local.get $r)) (i64.xor (local.get $ib) (local.get $r))) (i64.const 0))
                (then (call $from_big (call $bigint_add (call $bigint_from_i64 (local.get $ia)) (call $bigint_from_i64 (local.get $ib)))))
                (else (call $narrow (local.get $r)))))
            (else (call $from_big (call $bigint_add (call $to_big (local.get $a)) (call $to_big (local.get $b)))))))))
      (func $int_sub (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
        (local $ia i64) (local $ib i64) (local $r i64)
        (if (result (ref null eq)) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
          (then (call $narrow (i64.sub (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $a)))) (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $b)))))))
          (else (if (result (ref null eq)) (i32.and (call $is_i64rep (local.get $a)) (call $is_i64rep (local.get $b)))
            (then
              (local.set $ia (call $as_i64 (local.get $a))) (local.set $ib (call $as_i64 (local.get $b)))
              (local.set $r (i64.sub (local.get $ia) (local.get $ib)))
              (if (result (ref null eq)) (i64.lt_s (i64.and (i64.xor (local.get $ia) (local.get $ib)) (i64.xor (local.get $ia) (local.get $r))) (i64.const 0))
                (then (call $from_big (call $bigint_sub (call $bigint_from_i64 (local.get $ia)) (call $bigint_from_i64 (local.get $ib)))))
                (else (call $narrow (local.get $r)))))
            (else (call $from_big (call $bigint_sub (call $to_big (local.get $a)) (call $to_big (local.get $b)))))))))
      (func $int_mul (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
        (local $ia i64) (local $ib i64) (local $r i64) (local $ovf i32)
        (if (result (ref null eq)) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
          (then (call $narrow (i64.mul (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $a)))) (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $b)))))))
          (else (if (result (ref null eq)) (i32.and (call $is_i64rep (local.get $a)) (call $is_i64rep (local.get $b)))
            (then
              (local.set $ia (call $as_i64 (local.get $a))) (local.set $ib (call $as_i64 (local.get $b)))
              (local.set $r (i64.mul (local.get $ia) (local.get $ib)))
              (local.set $ovf
                (if (result i32) (i64.eqz (local.get $ia)) (then (i32.const 0))
                  (else (if (result i32) (i64.eq (local.get $ia) (i64.const -1))
                    (then (i64.eq (local.get $ib) (i64.const -9223372036854775808)))
                    (else (i64.ne (i64.div_s (local.get $r) (local.get $ia)) (local.get $ib)))))))
              (if (result (ref null eq)) (local.get $ovf)
                (then (call $from_big (call $bigint_mul (call $bigint_from_i64 (local.get $ia)) (call $bigint_from_i64 (local.get $ib)))))
                (else (call $narrow (local.get $r)))))
            (else (call $from_big (call $bigint_mul (call $to_big (local.get $a)) (call $to_big (local.get $b)))))))))
      (func $int_div (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
        (local $ia i64) (local $ib i64)
        ;; every tier canonicalizes integer 0 to i31 0, so one ref.eq covers them all. Raises a
        ;; CATCHABLE :badarith (rescue ArithmeticError) like the VM — not a hard Wasm trap.
        (if (ref.eq (local.get $b) (ref.i31 (i32.const 0)))
          (then (drop (call $erlang.error_1 (global.get $atom_badarith))) (unreachable)))
        (if (result (ref null eq)) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
          (then (call $narrow (i64.div_s (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $a)))) (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $b)))))))
          (else (if (result (ref null eq)) (i32.and (call $is_i64rep (local.get $a)) (call $is_i64rep (local.get $b)))
            (then
              (local.set $ia (call $as_i64 (local.get $a))) (local.set $ib (call $as_i64 (local.get $b)))
              (if (result (ref null eq)) (i32.and (i64.eq (local.get $ib) (i64.const -1)) (i64.eq (local.get $ia) (i64.const -9223372036854775808)))
                (then (call $from_big (call $bigint_div (call $bigint_from_i64 (local.get $ia)) (call $bigint_from_i64 (local.get $ib)))))
                (else (call $narrow (i64.div_s (local.get $ia) (local.get $ib))))))
            (else (call $from_big (call $bigint_div (call $to_big (local.get $a)) (call $to_big (local.get $b)))))))))
      (func $int_rem (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
        (if (ref.eq (local.get $b) (ref.i31 (i32.const 0)))
          (then (drop (call $erlang.error_1 (global.get $atom_badarith))) (unreachable)))
        (if (result (ref null eq)) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
          (then (call $narrow (i64.rem_s (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $a)))) (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $b)))))))
          (else (if (result (ref null eq)) (i32.and (call $is_i64rep (local.get $a)) (call $is_i64rep (local.get $b)))
            (then (call $narrow (i64.rem_s (call $as_i64 (local.get $a)) (call $as_i64 (local.get $b)))))
            (else (call $from_big (call $bigint_rem (call $to_big (local.get $a)) (call $to_big (local.get $b)))))))))
      ;; bitwise: i31 fast path; i64-rep native (result fits i64); boxed -> host. bsl/bsr always host.
      (func $int_band (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
        (if (result (ref null eq)) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
          (then (ref.i31 (i32.and (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))
          (else (if (result (ref null eq)) (i32.and (call $is_i64rep (local.get $a)) (call $is_i64rep (local.get $b)))
            (then (call $narrow (i64.and (call $as_i64 (local.get $a)) (call $as_i64 (local.get $b)))))
            (else (call $from_big (call $bigint_band (call $to_big (local.get $a)) (call $to_big (local.get $b)))))))))
      (func $int_bor (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
        (if (result (ref null eq)) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
          (then (ref.i31 (i32.or (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))
          (else (if (result (ref null eq)) (i32.and (call $is_i64rep (local.get $a)) (call $is_i64rep (local.get $b)))
            (then (call $narrow (i64.or (call $as_i64 (local.get $a)) (call $as_i64 (local.get $b)))))
            (else (call $from_big (call $bigint_bor (call $to_big (local.get $a)) (call $to_big (local.get $b)))))))))
      (func $int_bxor (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
        (if (result (ref null eq)) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
          (then (ref.i31 (i32.xor (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))
          (else (if (result (ref null eq)) (i32.and (call $is_i64rep (local.get $a)) (call $is_i64rep (local.get $b)))
            (then (call $narrow (i64.xor (call $as_i64 (local.get $a)) (call $as_i64 (local.get $b)))))
            (else (call $from_big (call $bigint_bxor (call $to_big (local.get $a)) (call $to_big (local.get $b)))))))))
      (func $int_bsl (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
        (call $from_big (call $bigint_bsl (call $to_big (local.get $a)) (call $to_big (local.get $b)))))
      (func $int_bsr (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
        (call $from_big (call $bigint_bsr (call $to_big (local.get $a)) (call $to_big (local.get $b)))))
      (func $to_extbig (param $t (ref null eq)) (result externref) (call $to_big (local.get $t)))
      (func $is_int (param $x (ref null eq)) (result i32)   ;; i31 OR $i64 OR boxed $big
        (i32.or (call $is_i64rep (local.get $x)) (ref.test (ref $big) (local.get $x))))
      (func $int_cmp (param $a (ref null eq)) (param $b (ref null eq)) (result i32)  ;; -1/0/1
        (local $ia i64) (local $ib i64)#{if Process.get(:float), do: "
        (if (result i32) (i32.or (ref.test (ref $float) (local.get $a)) (ref.test (ref $float) (local.get $b)))
          (then   ;; a float is involved: compare numerically as f64 (Erlang number order)
            (i32.sub (f64.gt (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b))) (f64.lt (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))))
          (else", else: ""}
        (if (result i32) (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b)))
          (then   ;; both small: i32 compare (inline, the common case)
            (i32.sub
              (i32.gt_s (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))
              (i32.lt_s (i31.get_s (ref.cast (ref i31) (local.get $a))) (i31.get_s (ref.cast (ref i31) (local.get $b))))))
          (else (if (result i32) (i32.and (call $is_i64rep (local.get $a)) (call $is_i64rep (local.get $b)))
            (then   ;; both i64-representable: native i64 compare
              (local.set $ia (call $as_i64 (local.get $a))) (local.set $ib (call $as_i64 (local.get $b)))
              (i32.sub (i64.gt_s (local.get $ia) (local.get $ib)) (i64.lt_s (local.get $ia) (local.get $ib))))
            (else   ;; at least one true bignum: compare as BigInt (host)
              (call $bigint_cmp (call $to_big (local.get $a)) (call $to_big (local.get $b)))))#{if Process.get(:float), do: "))", else: ""})))\
    """
  end

  # Hand-written WAT for native BIFs/NIFs the BEAM implements in C. Keyed by $Mod.fun_arity.
  # These override the (nif_error) BEAM body when the module is compiled in, and fill the
  # gap when it isn't. The ROADMAP's "BIF shims" — grown as real programs need them.
  def builtins do
    base = %{
      "$lists.reverse_2" =>
        """
          (func $lists.reverse_2 (param $l (ref null eq)) (param $acc (ref null eq)) (result (ref null eq))
            (block $done (loop $lp
              (br_if $done (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (local.set $acc (struct.new $cons (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))) (local.get $acc)))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (local.get $acc))\
        """,
      "$lists.reverse_1" =>
        """
          (func $lists.reverse_1 (param $l (ref null eq)) (result (ref null eq))
            (return_call $lists.reverse_2 (local.get $l) (ref.null none)))\
        """,
      # :erlang.list_to_bitstring(iolist) — byte-aligned in practice (lists of binaries/bytes) → iolist_to_binary.
      "$erlang.list_to_bitstring_1" =>
        "  (func $erlang.list_to_bitstring_1 (param $l (ref null eq)) (result (ref null eq))\n    (return_call $erlang.iolist_to_binary_1 (local.get $l)))",
      # a codepoint -> a 1-grapheme UTF-8 binary
      "$cp_to_binary" =>
        """
          (func $cp_to_binary (param $cp i32) (result (ref null eq))
            (local $d (ref $bytes))
            (local.set $d (array.new_default $bytes (call $utf8_enc_len (local.get $cp))))
            (drop (call $utf8_enc (local.get $d) (i32.const 0) (local.get $cp)))
            (struct.new $binary (local.get $d)))\
        """,
      # String.grapheme_to_binary(grapheme): binary→itself, codepoint→UTF-8, list (chardata)→flatten.
      "$Elixir_46_String._45_inlined_45_grapheme_to_binary_47_1_45__1" =>
        """
          (func $Elixir_46_String._45_inlined_45_grapheme_to_binary_47_1_45__1 (param $x (ref null eq)) (result (ref null eq))
            (if (ref.test (ref $binary) (local.get $x)) (then (return (local.get $x))))
            (if (ref.test (ref i31) (local.get $x)) (then (return_call $cp_to_binary (i31.get_s (ref.cast (ref i31) (local.get $x))))))
            (return_call $erlang.iolist_to_binary_1 (local.get $x)))\
        """,
      # Application.get_env(app, key, default) — no application env in the sandbox → the default (or nil).
      "$Elixir_46_Application.get_env_3" =>
        "  (func $Elixir_46_Application.get_env_3 (param $app (ref null eq)) (param $key (ref null eq)) (param $default (ref null eq)) (result (ref null eq))\n    (local.get $default))",
      "$Elixir_46_Application.get_env_2" =>
        "  (func $Elixir_46_Application.get_env_2 (param $app (ref null eq)) (param $key (ref null eq)) (result (ref null eq))\n    (global.get $atom_nil))",
      # IO.chardata_to_string(chardata) — a binary passes through; an iolist flattens.
      "$Elixir_46_IO.chardata_to_string_1" =>
        """
          (func $Elixir_46_IO.chardata_to_string_1 (param $x (ref null eq)) (result (ref null eq))
            (if (ref.test (ref $binary) (local.get $x)) (then (return (local.get $x))))
            (return_call $erlang.iolist_to_binary_1 (local.get $x)))\
        """,
      # :elixir_config.get(key, default) — no config ETS in the sandbox → the default.
      "$elixir_config.get_2" =>
        "  (func $elixir_config.get_2 (param $key (ref null eq)) (param $default (ref null eq)) (result (ref null eq))\n    (local.get $default))",
      # :os.type() — an OS query NIF. Constant in the sandbox; the :unix family is all that affects behavior.
      "$os.type_0" =>
        "  (func $os.type_0 (result (ref null eq))\n    (array.new_fixed $tuple 2 (global.get $atom_unix) (global.get $atom_linux)))",
      # read a big-endian u32 from $bytes at offset (shared by the regex host-frame decoders)
      "$rdu32be" =>
        """
          (func $rdu32be (param $b (ref $bytes)) (param $o i32) (result i32)
            (i32.or (i32.or (i32.or
              (i32.shl (array.get_u $bytes (local.get $b) (local.get $o)) (i32.const 24))
              (i32.shl (array.get_u $bytes (local.get $b) (i32.add (local.get $o) (i32.const 1))) (i32.const 16)))
              (i32.shl (array.get_u $bytes (local.get $b) (i32.add (local.get $o) (i32.const 2))) (i32.const 8)))
              (array.get_u $bytes (local.get $b) (i32.add (local.get $o) (i32.const 3)))))\
        """,
      # binary_part(Subject, Start, Length) as an ext-callable function (the gc_bif form inlines $binary_part).
      "$erlang.binary_part_3" =>
        """
          (func $erlang.binary_part_3 (param $s (ref null eq)) (param $start (ref null eq)) (param $len (ref null eq)) (result (ref null eq))
            (return_call $binary_part (local.get $s) (i31.get_s (ref.cast (ref i31) (local.get $start))) (i31.get_s (ref.cast (ref i31) (local.get $len)))))\
        """,
      "$binary.part_3" =>
        """
          (func $binary.part_3 (param $s (ref null eq)) (param $start (ref null eq)) (param $len (ref null eq)) (result (ref null eq))
            (return_call $binary_part (local.get $s) (i31.get_s (ref.cast (ref i31) (local.get $start))) (i31.get_s (ref.cast (ref i31) (local.get $len)))))\
        """,
      # :binary.part(Subject, {Start, Length}) — position/length packed in a 2-tuple.
      "$binary.part_2" =>
        """
          (func $binary.part_2 (param $s (ref null eq)) (param $pl (ref null eq)) (result (ref null eq))
            (return_call $binary_part (local.get $s)
              (i31.get_s (ref.cast (ref i31) (array.get $tuple (ref.cast (ref $tuple) (local.get $pl)) (i32.const 0))))
              (i31.get_s (ref.cast (ref i31) (array.get $tuple (ref.cast (ref $tuple) (local.get $pl)) (i32.const 1))))))\
        """,
      # unicode:characters_to_list(Binary) -> a list of codepoints (UTF-8 decode). Backs String.to_charlist.
      "$unicode.characters_to_list_1" =>
        """
          (func $unicode.characters_to_list_1 (param $x (ref null eq)) (result (ref null eq))
            (local $b (ref $bytes)) (local $n i32) (local $i i32) (local $c i32) (local $cp i32) (local $out (ref null eq))
            ;; chardata that is ALREADY a flat codepoint list (or []) passes through unchanged —
            ;; List.to_charlist(charlist) etc. (nested/mixed chardata still goes the binary path only).
            (if (ref.is_null (local.get $x)) (then (return (local.get $x))))
            (if (ref.test (ref $cons) (local.get $x)) (then (return (local.get $x))))
            (local.set $b (call $bin_bytes (local.get $x)))
            (local.set $n (array.len (local.get $b)))
            (block $done (loop $lp
              (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
              (local.set $c (array.get_u $bytes (local.get $b) (local.get $i)))
              (if (i32.lt_u (local.get $c) (i32.const 128))
                (then (local.set $cp (local.get $c)) (local.set $i (i32.add (local.get $i) (i32.const 1))))
                (else (if (i32.lt_u (local.get $c) (i32.const 224))
                  (then
                    (local.set $cp (i32.or (i32.shl (i32.and (local.get $c) (i32.const 31)) (i32.const 6)) (i32.and (array.get_u $bytes (local.get $b) (i32.add (local.get $i) (i32.const 1))) (i32.const 63))))
                    (local.set $i (i32.add (local.get $i) (i32.const 2))))
                  (else (if (i32.lt_u (local.get $c) (i32.const 240))
                    (then
                      (local.set $cp (i32.or (i32.or (i32.shl (i32.and (local.get $c) (i32.const 15)) (i32.const 12)) (i32.shl (i32.and (array.get_u $bytes (local.get $b) (i32.add (local.get $i) (i32.const 1))) (i32.const 63)) (i32.const 6))) (i32.and (array.get_u $bytes (local.get $b) (i32.add (local.get $i) (i32.const 2))) (i32.const 63))))
                      (local.set $i (i32.add (local.get $i) (i32.const 3))))
                    (else
                      (local.set $cp (i32.or (i32.or (i32.or (i32.shl (i32.and (local.get $c) (i32.const 7)) (i32.const 18)) (i32.shl (i32.and (array.get_u $bytes (local.get $b) (i32.add (local.get $i) (i32.const 1))) (i32.const 63)) (i32.const 12))) (i32.shl (i32.and (array.get_u $bytes (local.get $b) (i32.add (local.get $i) (i32.const 2))) (i32.const 63)) (i32.const 6))) (i32.and (array.get_u $bytes (local.get $b) (i32.add (local.get $i) (i32.const 3))) (i32.const 63))))
                      (local.set $i (i32.add (local.get $i) (i32.const 4)))))))))
              (local.set $out (struct.new $cons (ref.i31 (local.get $cp)) (local.get $out)))
              (br $lp)))
            (return_call $lists.reverse_1 (local.get $out)))\
        """,
      # Code.ensure_compiled(Module) -> {:module, Module}. In our closed world every referenced module
      # IS shipped, so this always succeeds. Lets the UNconsolidated protocol dispatch (Enumerable.impl_for
      # → struct_impl_for) resolve an impl instead of trapping on module-loading machinery.
      "$Elixir_46_Code.ensure_compiled_1" =>
        """
          (func $Elixir_46_Code.ensure_compiled_1 (param $m (ref null eq)) (result (ref null eq))
            (array.new_fixed $tuple 2 (global.get $atom_module) (local.get $m)))\
        """,
      # read a 64-bit big-endian IEEE-754 double from $bytes at byte offset $off (bs_get_float2, default flags)
      "$read_f64_be" =>
        """
          (func $read_f64_be (param $b (ref $bytes)) (param $off i32) (result f64)
            (local $v i64) (local $i i32)
            (block $d (loop $lp
              (br_if $d (i32.ge_u (local.get $i) (i32.const 8)))
              (local.set $v (i64.or (i64.shl (local.get $v) (i64.const 8))
                (i64.extend_i32_u (array.get_u $bytes (local.get $b) (i32.add (local.get $off) (local.get $i))))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $lp)))
            (f64.reinterpret_i64 (local.get $v)))\
        """,
      # ---- :binary search/split family (naive byte search; parts are copied sub-binaries) ----
      "$subbin" =>
        """
          (func $subbin (param $b (ref $bytes)) (param $off i32) (param $len i32) (result (ref null eq))
            (local $d (ref $bytes))
            (local.set $d (array.new_default $bytes (local.get $len)))
            (array.copy $bytes $bytes (local.get $d) (i32.const 0) (local.get $b) (local.get $off) (local.get $len))
            (struct.new $binary (local.get $d)))\
        """,
      "$bin_find" =>
        """
          (func $bin_find (param $s (ref $bytes)) (param $start i32) (param $p (ref $bytes)) (result i32)
            (local $sn i32) (local $pn i32) (local $i i32) (local $j i32)
            (local.set $sn (array.len (local.get $s))) (local.set $pn (array.len (local.get $p)))
            (if (i32.eqz (local.get $pn)) (then (return (local.get $start))))
            (local.set $i (local.get $start))
            (block $done (loop $lp
              (br_if $done (i32.gt_s (i32.add (local.get $i) (local.get $pn)) (local.get $sn)))
              (local.set $j (i32.const 0))
              (block $nomatch
                (block $mt (loop $jl
                  (br_if $mt (i32.ge_u (local.get $j) (local.get $pn)))
                  (br_if $nomatch (i32.ne (array.get_u $bytes (local.get $s) (i32.add (local.get $i) (local.get $j))) (array.get_u $bytes (local.get $p) (local.get $j))))
                  (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $jl)))
                (return (local.get $i)))
              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $lp)))
            (i32.const -1))\
        """,
      "$bin_bytes" =>
        """
          (func $bin_bytes (param $x (ref null eq)) (result (ref $bytes))
            (struct.get $binary 0 (ref.cast (ref $binary) (local.get $x))))\
        """,
      "$list_has_atom" =>
        """
          (func $list_has_atom (param $l (ref null eq)) (param $a (ref null eq)) (result i32)
            (block $done (loop $lp
              (br_if $done (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (if (ref.eq (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))) (local.get $a)) (then (return (i32.const 1))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (i32.const 0))\
        """,
      # binary:split(Subject, Pattern[, Opts]) — Pattern is a single binary OR a list of binaries
      # (leftmost occurrence wins; at equal positions the longest pattern, per binary:match/2).
      # Opts: :global (every occurrence), :trim (drop trailing empties), :trim_all (drop all empties).
      "$binary.split_2" =>
        """
          (func $binary.split_2 (param $subj (ref null eq)) (param $pat (ref null eq)) (result (ref null eq))
            (return_call $bsplit (local.get $subj) (local.get $pat) (i32.const 0) (i32.const 0)))\
        """,
      "$binary.split_3" =>
        """
          (func $binary.split_3 (param $subj (ref null eq)) (param $pat (ref null eq)) (param $opts (ref null eq)) (result (ref null eq))
            (return_call $bsplit (local.get $subj) (local.get $pat)
              (call $list_has_atom (local.get $opts) (global.get $atom_global))
              (if (result i32) (call $list_has_atom (local.get $opts) (global.get $atom_trim_all))
                (then (i32.const 2))
                (else (call $list_has_atom (local.get $opts) (global.get $atom_trim))))))\
        """,
      # leftmost (then longest) occurrence of any pattern in the $cons list, from byte $from.
      # Packed result: (pos << 32) | matched_len, or -1 when nothing matches.
      "$bin_find_any" =>
        """
          (func $bin_find_any (param $s (ref $bytes)) (param $from i32) (param $pats (ref null eq)) (result i64)
            (local $best_pos i32) (local $best_len i32) (local $c (ref null eq)) (local $p (ref $bytes)) (local $i i32)
            (local.set $best_pos (i32.const -1))
            (local.set $c (local.get $pats))
            (block $done (loop $lp
              (br_if $done (i32.eqz (ref.test (ref $cons) (local.get $c))))
              (local.set $p (call $bin_bytes (struct.get $cons 0 (ref.cast (ref $cons) (local.get $c)))))
              (local.set $i (call $bin_find (local.get $s) (local.get $from) (local.get $p)))
              (if (i32.ge_s (local.get $i) (i32.const 0)) (then
                (if (i32.or (i32.lt_s (local.get $best_pos) (i32.const 0))
                            (i32.or (i32.lt_s (local.get $i) (local.get $best_pos))
                                    (i32.and (i32.eq (local.get $i) (local.get $best_pos))
                                             (i32.gt_s (array.len (local.get $p)) (local.get $best_len)))))
                  (then (local.set $best_pos (local.get $i)) (local.set $best_len (array.len (local.get $p)))))))
              (local.set $c (struct.get $cons 1 (ref.cast (ref $cons) (local.get $c))))
              (br $lp)))
            (if (i32.lt_s (local.get $best_pos) (i32.const 0)) (then (return (i64.const -1))))
            (i64.or (i64.shl (i64.extend_i32_u (local.get $best_pos)) (i64.const 32))
                    (i64.extend_i32_u (local.get $best_len))))\
        """,
      "$bsplit" =>
        """
          (func $bsplit (param $subj (ref null eq)) (param $pat (ref null eq)) (param $glob i32) (param $trim i32) (result (ref null eq))
            (local $s (ref $bytes)) (local $sn i32) (local $prev i32) (local $hit i64) (local $pos i32) (local $plen i32)
            (local $parts (ref null eq)) (local $pats (ref null eq))
            (local.set $s (call $bin_bytes (local.get $subj)))
            (local.set $sn (array.len (local.get $s)))
            (local.set $pats (if (result (ref null eq)) (ref.test (ref $cons) (local.get $pat))
              (then (local.get $pat))
              (else (struct.new $cons (local.get $pat) (ref.null none)))))
            (block $done (loop $lp
              (local.set $hit (call $bin_find_any (local.get $s) (local.get $prev) (local.get $pats)))
              (br_if $done (i64.lt_s (local.get $hit) (i64.const 0)))
              (local.set $pos (i32.wrap_i64 (i64.shr_u (local.get $hit) (i64.const 32))))
              (local.set $plen (i32.wrap_i64 (local.get $hit)))
              (if (i32.or (i32.ne (local.get $trim) (i32.const 2)) (i32.ne (local.get $pos) (local.get $prev)))
                (then (local.set $parts (struct.new $cons (call $subbin (local.get $s) (local.get $prev) (i32.sub (local.get $pos) (local.get $prev))) (local.get $parts)))))
              (local.set $prev (i32.add (local.get $pos) (local.get $plen)))
              (br_if $done (i32.eqz (local.get $glob)))
              (br $lp)))
            (if (i32.or (i32.ne (local.get $trim) (i32.const 2)) (i32.ne (local.get $prev) (local.get $sn)))
              (then (local.set $parts (struct.new $cons (call $subbin (local.get $s) (local.get $prev) (i32.sub (local.get $sn) (local.get $prev))) (local.get $parts)))))
            (if (i32.eq (local.get $trim) (i32.const 1)) (then
              (block $t (loop $tl
                (br_if $t (i32.eqz (ref.test (ref $cons) (local.get $parts))))
                (br_if $t (i32.ne (array.len (call $bin_bytes (struct.get $cons 0 (ref.cast (ref $cons) (local.get $parts))))) (i32.const 0)))
                (local.set $parts (struct.get $cons 1 (ref.cast (ref $cons) (local.get $parts))))
                (br $tl)))))
            (return_call $lists.reverse_1 (local.get $parts)))\
        """,
      "$binary.matches_2" =>
        """
          (func $binary.matches_2 (param $subj (ref null eq)) (param $pat (ref null eq)) (result (ref null eq))
            (local $s (ref $bytes)) (local $p (ref $bytes)) (local $pn i32) (local $i i32) (local $out (ref null eq))
            (local.set $s (call $bin_bytes (local.get $subj))) (local.set $p (call $bin_bytes (local.get $pat)))
            (local.set $pn (array.len (local.get $p)))
            (block $done (loop $lp
              (local.set $i (call $bin_find (local.get $s) (local.get $i) (local.get $p)))
              (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
              (local.set $out (struct.new $cons (array.new_fixed $tuple 2 (ref.i31 (local.get $i)) (ref.i31 (local.get $pn))) (local.get $out)))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $lp)))
            (return_call $lists.reverse_1 (local.get $out)))\
        """,
      "$binary.match_2" =>
        """
          (func $binary.match_2 (param $subj (ref null eq)) (param $pat (ref null eq)) (result (ref null eq))
            (local $i i32)
            (local.set $i (call $bin_find (call $bin_bytes (local.get $subj)) (i32.const 0) (call $bin_bytes (local.get $pat))))
            (if (i32.lt_s (local.get $i) (i32.const 0)) (then (return (global.get $atom_nomatch))))
            (array.new_fixed $tuple 2 (ref.i31 (local.get $i)) (ref.i31 (array.len (call $bin_bytes (local.get $pat))))))\
        """,
      "$binary.at_2" =>
        """
          (func $binary.at_2 (param $subj (ref null eq)) (param $idx (ref null eq)) (result (ref null eq))
            (ref.i31 (array.get_u $bytes (call $bin_bytes (local.get $subj)) (i31.get_s (ref.cast (ref i31) (local.get $idx))))))\
        """,
      # compile_pattern/1: our search takes a raw binary pattern, so a single-binary pattern is identity.
      "$binary.compile_pattern_1" =>
        """
          (func $binary.compile_pattern_1 (param $p (ref null eq)) (result (ref null eq)) (local.get $p))\
        """,
      "$erlang.split_binary_2" =>
        """
          (func $erlang.split_binary_2 (param $subj (ref null eq)) (param $pos (ref null eq)) (result (ref null eq))
            (local $s (ref $bytes)) (local $n i32) (local $k i32)
            (local.set $s (call $bin_bytes (local.get $subj))) (local.set $n (array.len (local.get $s)))
            (local.set $k (i31.get_s (ref.cast (ref i31) (local.get $pos))))
            (array.new_fixed $tuple 2 (call $subbin (local.get $s) (i32.const 0) (local.get $k)) (call $subbin (local.get $s) (local.get $k) (i32.sub (local.get $n) (local.get $k)))))\
        """,
      # binary:replace(Subject, Pattern, Replacement, Opts) — replace first (or all w/ :global).
      "$binary.replace_4" =>
        """
          (func $binary.replace_4 (param $subj (ref null eq)) (param $pat (ref null eq)) (param $rep (ref null eq)) (param $opts (ref null eq)) (result (ref null eq))
            (local $parts (ref null eq))
            (local.set $parts (call $bsplit (local.get $subj) (local.get $pat) (call $list_has_atom (local.get $opts) (global.get $atom_global)) (i32.const 0)))
            (return_call $bin_join (local.get $parts) (local.get $rep)))\
        """,
      "$bin_join" =>
        """
          (func $bin_join (param $parts (ref null eq)) (param $sep (ref null eq)) (result (ref null eq))
            (local $tot i32) (local $c (ref null eq)) (local $sepn i32) (local $first i32) (local $d (ref $bytes)) (local $o i32) (local $pb (ref $bytes))
            (local.set $sepn (array.len (call $bin_bytes (local.get $sep))))
            (local.set $c (local.get $parts)) (local.set $first (i32.const 1))
            (block $d1 (loop $l1
              (br_if $d1 (i32.eqz (ref.test (ref $cons) (local.get $c))))
              (if (i32.eqz (local.get $first)) (then (local.set $tot (i32.add (local.get $tot) (local.get $sepn)))))
              (local.set $first (i32.const 0))
              (local.set $tot (i32.add (local.get $tot) (array.len (call $bin_bytes (struct.get $cons 0 (ref.cast (ref $cons) (local.get $c)))))))
              (local.set $c (struct.get $cons 1 (ref.cast (ref $cons) (local.get $c)))) (br $l1)))
            (local.set $d (array.new_default $bytes (local.get $tot)))
            (local.set $c (local.get $parts)) (local.set $first (i32.const 1)) (local.set $o (i32.const 0))
            (block $d2 (loop $l2
              (br_if $d2 (i32.eqz (ref.test (ref $cons) (local.get $c))))
              (if (i32.eqz (local.get $first)) (then
                (array.copy $bytes $bytes (local.get $d) (local.get $o) (call $bin_bytes (local.get $sep)) (i32.const 0) (local.get $sepn))
                (local.set $o (i32.add (local.get $o) (local.get $sepn)))))
              (local.set $first (i32.const 0))
              (local.set $pb (call $bin_bytes (struct.get $cons 0 (ref.cast (ref $cons) (local.get $c)))))
              (array.copy $bytes $bytes (local.get $d) (local.get $o) (local.get $pb) (i32.const 0) (array.len (local.get $pb)))
              (local.set $o (i32.add (local.get $o) (array.len (local.get $pb))))
              (local.set $c (struct.get $cons 1 (ref.cast (ref $cons) (local.get $c)))) (br $l2)))
            (struct.new $binary (local.get $d)))\
        """,
      # ---- tuple BIFs (tuples are $tuple = (array (ref null eq)); indices are 1-based) ----
      "$erlang.tuple_to_list_1" =>
        """
          (func $erlang.tuple_to_list_1 (param $t (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $i i32) (local $out (ref null eq))
            (local.set $a (ref.cast (ref $tuple) (local.get $t)))
            (local.set $i (array.len (local.get $a)))
            (block $d (loop $lp
              (br_if $d (i32.eqz (local.get $i)))
              (local.set $i (i32.sub (local.get $i) (i32.const 1)))
              (local.set $out (struct.new $cons (array.get $tuple (local.get $a) (local.get $i)) (local.get $out)))
              (br $lp)))
            (local.get $out))\
        """,
      "$erlang.list_to_tuple_1" =>
        """
          (func $erlang.list_to_tuple_1 (param $l (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $i i32) (local $c (ref null eq))
            (local.set $a (array.new_default $tuple (call $list_len (local.get $l))))
            (local.set $c (local.get $l))
            (block $d (loop $lp
              (br_if $d (i32.eqz (ref.test (ref $cons) (local.get $c))))
              (array.set $tuple (local.get $a) (local.get $i) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $c))))
              (local.set $c (struct.get $cons 1 (ref.cast (ref $cons) (local.get $c))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $lp)))
            (local.get $a))\
        """,
      "$erlang.setelement_3" =>
        """
          (func $erlang.setelement_3 (param $idx (ref null eq)) (param $t (ref null eq)) (param $v (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $n i32) (local $out (ref $tuple))
            (local.set $a (ref.cast (ref $tuple) (local.get $t)))
            (local.set $n (array.len (local.get $a)))
            (local.set $out (array.new_default $tuple (local.get $n)))
            (array.copy $tuple $tuple (local.get $out) (i32.const 0) (local.get $a) (i32.const 0) (local.get $n))
            (array.set $tuple (local.get $out) (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $idx))) (i32.const 1)) (local.get $v))
            (local.get $out))\
        """,
      "$erlang.make_tuple_2" =>
        """
          (func $erlang.make_tuple_2 (param $ar (ref null eq)) (param $v (ref null eq)) (result (ref null eq))
            (array.new $tuple (local.get $v) (i31.get_s (ref.cast (ref i31) (local.get $ar)))))\
        """,
      "$erlang.append_element_2" =>
        """
          (func $erlang.append_element_2 (param $t (ref null eq)) (param $v (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $n i32) (local $out (ref $tuple))
            (local.set $a (ref.cast (ref $tuple) (local.get $t)))
            (local.set $n (array.len (local.get $a)))
            (local.set $out (array.new_default $tuple (i32.add (local.get $n) (i32.const 1))))
            (array.copy $tuple $tuple (local.get $out) (i32.const 0) (local.get $a) (i32.const 0) (local.get $n))
            (array.set $tuple (local.get $out) (local.get $n) (local.get $v))
            (local.get $out))\
        """,
      "$erlang.insert_element_3" =>
        """
          (func $erlang.insert_element_3 (param $idx (ref null eq)) (param $t (ref null eq)) (param $v (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $n i32) (local $p i32) (local $out (ref $tuple))
            (local.set $a (ref.cast (ref $tuple) (local.get $t)))
            (local.set $n (array.len (local.get $a)))
            (local.set $p (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $idx))) (i32.const 1)))
            (local.set $out (array.new_default $tuple (i32.add (local.get $n) (i32.const 1))))
            (array.copy $tuple $tuple (local.get $out) (i32.const 0) (local.get $a) (i32.const 0) (local.get $p))
            (array.set $tuple (local.get $out) (local.get $p) (local.get $v))
            (array.copy $tuple $tuple (local.get $out) (i32.add (local.get $p) (i32.const 1)) (local.get $a) (local.get $p) (i32.sub (local.get $n) (local.get $p)))
            (local.get $out))\
        """,
      "$erlang.delete_element_2" =>
        """
          (func $erlang.delete_element_2 (param $idx (ref null eq)) (param $t (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $n i32) (local $p i32) (local $out (ref $tuple))
            (local.set $a (ref.cast (ref $tuple) (local.get $t)))
            (local.set $n (array.len (local.get $a)))
            (local.set $p (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $idx))) (i32.const 1)))
            (local.set $out (array.new_default $tuple (i32.sub (local.get $n) (i32.const 1))))
            (array.copy $tuple $tuple (local.get $out) (i32.const 0) (local.get $a) (i32.const 0) (local.get $p))
            (array.copy $tuple $tuple (local.get $out) (local.get $p) (local.get $a) (i32.add (local.get $p) (i32.const 1)) (i32.sub (i32.sub (local.get $n) (local.get $p)) (i32.const 1)))
            (local.get $out))\
        """,
      # iolist_to_binary/1 — flatten a (possibly deep, improper) iolist of bytes/binaries into one
      # $binary. Two passes: measure total length, then fill. The core BIF behind IO.iodata_to_binary.
      "$iol_len" =>
        """
          (func $iol_len (param $t (ref null eq)) (result i32)
            (if (ref.is_null (local.get $t)) (then (return (i32.const 0))))
            (if (ref.test (ref i31) (local.get $t)) (then (return (i32.const 1))))
            (if (ref.test (ref $binary) (local.get $t))
              (then (return (array.len (struct.get $binary 0 (ref.cast (ref $binary) (local.get $t)))))))
            (i32.add
              (call $iol_len (struct.get $cons 0 (ref.cast (ref $cons) (local.get $t))))
              (call $iol_len (struct.get $cons 1 (ref.cast (ref $cons) (local.get $t))))))\
        """,
      "$iol_fill" =>
        """
          (func $iol_fill (param $t (ref null eq)) (param $dst (ref $bytes)) (param $off i32) (result i32)
            (local $b (ref $bytes)) (local $len i32) (local $c (ref $cons))
            (if (ref.is_null (local.get $t)) (then (return (local.get $off))))
            (if (ref.test (ref i31) (local.get $t)) (then
              (array.set $bytes (local.get $dst) (local.get $off) (i31.get_s (ref.cast (ref i31) (local.get $t))))
              (return (i32.add (local.get $off) (i32.const 1)))))
            (if (ref.test (ref $binary) (local.get $t)) (then
              (local.set $b (struct.get $binary 0 (ref.cast (ref $binary) (local.get $t))))
              (local.set $len (array.len (local.get $b)))
              (array.copy $bytes $bytes (local.get $dst) (local.get $off) (local.get $b) (i32.const 0) (local.get $len))
              (return (i32.add (local.get $off) (local.get $len)))))
            (local.set $c (ref.cast (ref $cons) (local.get $t)))
            (local.set $off (call $iol_fill (struct.get $cons 0 (local.get $c)) (local.get $dst) (local.get $off)))
            (return_call $iol_fill (struct.get $cons 1 (local.get $c)) (local.get $dst) (local.get $off)))\
        """,
      "$erlang.iolist_to_binary_1" =>
        """
          (func $erlang.iolist_to_binary_1 (param $t (ref null eq)) (result (ref null eq))
            (local $dst (ref $bytes))
            (local.set $dst (array.new_default $bytes (call $iol_len (local.get $t))))
            (drop (call $iol_fill (local.get $t) (local.get $dst) (i32.const 0)))
            (struct.new $binary (local.get $dst)))\
        """,
      # maps:from_list/1 — build a $map from a list of {k,v} tuples (later dups win, via $map_put).
      "$maps.from_list_1" =>
        """
          (func $maps.from_list_1 (param $l (ref null eq)) (result (ref null eq))
            (local $m (ref null eq)) (local $p (ref $tuple))
            (local.set $m (struct.new $map (ref.null $mnode)))
            (block $done (loop $lp
              (br_if $done (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (local.set $p (ref.cast (ref $tuple) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))))
              (local.set $m (call $map_put (local.get $m) (array.get $tuple (local.get $p) (i32.const 0)) (array.get $tuple (local.get $p) (i32.const 1))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (local.get $m))\
        """,
      "$binary.copy_1" =>
        """
          (func $binary.copy_1 (param $bin (ref null eq)) (result (ref null eq))
            (local $src (ref $bytes)) (local $dst (ref $bytes)) (local $n i32)
            (local.set $src (struct.get $binary 0 (ref.cast (ref $binary) (local.get $bin))))
            (local.set $n (array.len (local.get $src)))
            (local.set $dst (array.new_default $bytes (local.get $n)))
            (array.copy $bytes $bytes (local.get $dst) (i32.const 0) (local.get $src) (i32.const 0) (local.get $n))
            (struct.new $binary (local.get $dst)))\
        """,
      "$binary.copy_2" =>
        """
          (func $binary.copy_2 (param $bin (ref null eq)) (param $times (ref null eq)) (result (ref null eq))
            (local $src (ref $bytes)) (local $dst (ref $bytes)) (local $n i32) (local $t i32) (local $i i32)
            (local.set $src (struct.get $binary 0 (ref.cast (ref $binary) (local.get $bin))))
            (local.set $n (array.len (local.get $src)))
            (local.set $t (i31.get_s (ref.cast (ref i31) (local.get $times))))
            (local.set $dst (array.new_default $bytes (i32.mul (local.get $n) (local.get $t))))
            (block $done (loop $lp
              (br_if $done (i32.ge_u (local.get $i) (local.get $t)))
              (array.copy $bytes $bytes (local.get $dst) (i32.mul (local.get $i) (local.get $n)) (local.get $src) (i32.const 0) (local.get $n))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $lp)))
            (struct.new $binary (local.get $dst)))\
        """,
      # integer_to_binary/1 — decimal ASCII of an i31 integer (count digits, then fill from the end).
      "$erlang.integer_to_binary_1" =>
        """
          (func $erlang.integer_to_binary_1 (param $x (ref null eq)) (result (ref null eq))
            (local $n i32) (local $neg i32) (local $len i32) (local $t i32) (local $d (ref $bytes)) (local $i i32)
            (if (i32.eqz (ref.test (ref i31) (local.get $x)))
              (then (return_call $erlang.integer_to_binary_2 (local.get $x) (ref.i31 (i32.const 10)))))
            (local.set $n (i31.get_s (ref.cast (ref i31) (local.get $x))))
            (if (i32.eqz (local.get $n)) (then
              (local.set $d (array.new_default $bytes (i32.const 1)))
              (array.set $bytes (local.get $d) (i32.const 0) (i32.const 48))
              (return (struct.new $binary (local.get $d)))))
            (if (i32.lt_s (local.get $n) (i32.const 0))
              (then (local.set $neg (i32.const 1)) (local.set $n (i32.sub (i32.const 0) (local.get $n)))))
            (local.set $t (local.get $n))
            (block $c (loop $cl (br_if $c (i32.eqz (local.get $t)))
              (local.set $len (i32.add (local.get $len) (i32.const 1)))
              (local.set $t (i32.div_u (local.get $t) (i32.const 10))) (br $cl)))
            (local.set $len (i32.add (local.get $len) (local.get $neg)))
            (local.set $d (array.new_default $bytes (local.get $len)))
            (if (local.get $neg) (then (array.set $bytes (local.get $d) (i32.const 0) (i32.const 45))))
            (local.set $i (i32.sub (local.get $len) (i32.const 1)))
            (block $f (loop $fl (br_if $f (i32.eqz (local.get $n)))
              (array.set $bytes (local.get $d) (local.get $i) (i32.add (i32.const 48) (i32.rem_u (local.get $n) (i32.const 10))))
              (local.set $n (i32.div_u (local.get $n) (i32.const 10)))
              (local.set $i (i32.sub (local.get $i) (i32.const 1))) (br $fl)))
            (struct.new $binary (local.get $d)))\
        """,
      # ── the effects ABI: :file/:IO handed to the HOST (virtual fs is a valid backing). These live
      # in builtins() so they BEAT the fed File/IO beam bodies (the builtin-overrides-beam rule).
      # Bodies are gated on the :fs_shim/:io_shim flags (set during detection) so an unconditional
      # emission never references absent host imports — ungated builds get honest traps.
      # Frames: fs read -> <<1, bytes>> ok | <<0, errcode>> (1 enoent, 2 eacces, 3 eio); write -> errcode.
      "$posix_atom" =>
        """
          (func $posix_atom (param $c i32) (result (ref null eq))
            (if (i32.eq (local.get $c) (i32.const 1)) (then (return (global.get $atom_enoent))))
            (if (i32.eq (local.get $c) (i32.const 2)) (then (return (global.get $atom_eacces))))
            (global.get $atom_eio))\
        """,
      "$file.read_file_1" =>
        if(Process.get(:fs_shim),
          do: """
            (func $file.read_file_1 (param $p (ref null eq)) (result (ref null eq))
              (local $fb (ref $bytes))
              (local.set $fb (call $bin_bytes (call $host_fs_read (local.get $p))))
              (if (i32.eq (array.get_u $bytes (local.get $fb) (i32.const 0)) (i32.const 1))
                (then (return (array.new_fixed $tuple 2 (global.get $atom_ok) (call $subbin (local.get $fb) (i32.const 1) (i32.sub (array.len (local.get $fb)) (i32.const 1)))))))
              (array.new_fixed $tuple 2 (global.get $atom_error) (call $posix_atom (array.get_u $bytes (local.get $fb) (i32.const 1)))))\
          """,
          else: "  (func $file.read_file_1 (param $p (ref null eq)) (result (ref null eq)) (unreachable))"),
      "$file.write_file_2" =>
        if(Process.get(:fs_shim),
          do: """
            (func $file.write_file_2 (param $p (ref null eq)) (param $d (ref null eq)) (result (ref null eq))
              (local $c i32)
              (local.set $c (call $host_fs_write (local.get $p) (local.get $d)))
              (if (i32.eqz (local.get $c)) (then (return (global.get $atom_ok))))
              (array.new_fixed $tuple 2 (global.get $atom_error) (call $posix_atom (local.get $c))))\
          """,
          else: "  (func $file.write_file_2 (param $p (ref null eq)) (param $d (ref null eq)) (result (ref null eq)) (unreachable))"),
      "$file.write_file_3" =>
        """
          (func $file.write_file_3 (param $p (ref null eq)) (param $d (ref null eq)) (param $modes (ref null eq)) (result (ref null eq))
            (return_call $file.write_file_2 (local.get $p) (local.get $d)))\
        """,
      # numeric abs across ALL tiers (floats included) — dynamic code (interpreters) calls
      # abs/1 on whatever it has. Gated on float mode ($float doesn't exist otherwise).
      "$num_abs" =>
        if(Process.get(:float),
          do: """
            (func $num_abs (param $x (ref null eq)) (result (ref null eq))
              (if (ref.test (ref $float) (local.get $x))
                (then (return (struct.new $float (f64.abs (struct.get $float 0 (ref.cast (ref $float) (local.get $x))))))))
              (if (i32.lt_s (call $int_cmp (local.get $x) (ref.i31 (i32.const 0))) (i32.const 0))
                (then (return (call $int_sub (ref.i31 (i32.const 0)) (local.get $x)))))
              (local.get $x))\
          """,
          else: "  (func $num_abs (param $x (ref null eq)) (result (ref null eq)) (unreachable))"),
      # ── time: a deterministic monotonic counter (the $monotime global, "native" = nanoseconds,
      # +1µs per read). Pure programs see consistent budgets; real host time is a later upgrade.
      "$time_unit_hz" =>
        """
          (func $time_unit_hz (param $u (ref null eq)) (result i64)
            (if (ref.test (ref i31) (local.get $u)) (then (return (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $u)))))))
            (if (ref.eq (local.get $u) (global.get $atom_second)) (then (return (i64.const 1))))
            (if (ref.eq (local.get $u) (global.get $atom_millisecond)) (then (return (i64.const 1000))))
            (if (ref.eq (local.get $u) (global.get $atom_microsecond)) (then (return (i64.const 1000000))))
            (if (ref.eq (local.get $u) (global.get $atom_nanosecond)) (then (return (i64.const 1000000000))))
            (if (ref.eq (local.get $u) (global.get $atom_native)) (then (return (i64.const 1000000000))))
            (unreachable))\
        """,
      "$Elixir_46_System.convert_time_unit_3" =>
        """
          (func $Elixir_46_System.convert_time_unit_3 (param $v (ref null eq)) (param $f (ref null eq)) (param $t (ref null eq)) (result (ref null eq))
            (call $int_div (call $int_mul (local.get $v) (call $narrow (call $time_unit_hz (local.get $t))))
                           (call $narrow (call $time_unit_hz (local.get $f)))))\
        """,
      "$erlang.convert_time_unit_3" =>
        """
          (func $erlang.convert_time_unit_3 (param $v (ref null eq)) (param $f (ref null eq)) (param $t (ref null eq)) (result (ref null eq))
            (return_call $Elixir_46_System.convert_time_unit_3 (local.get $v) (local.get $f) (local.get $t)))\
        """,
      "$Elixir_46_System.monotonic_time_0" =>
        """
          (func $Elixir_46_System.monotonic_time_0 (result (ref null eq))
            (global.set $monotime (i32.add (global.get $monotime) (i32.const 1000)))
            (call $narrow (i64.extend_i32_s (global.get $monotime))))\
        """,
      "$Elixir_46_System.monotonic_time_1" =>
        """
          (func $Elixir_46_System.monotonic_time_1 (param $u (ref null eq)) (result (ref null eq))
            (return_call $Elixir_46_System.convert_time_unit_3 (call $Elixir_46_System.monotonic_time_0) (global.get $atom_native) (local.get $u)))\
        """,
      # erlang.--/2: list difference — remove the FIRST occurrence of each rhs element from lhs.
      "$erlang._45__45__2" =>
        """
          (func $erlang._45__45__2 (param $l (ref null eq)) (param $r (ref null eq)) (result (ref null eq))
            (block $done (loop $lp
              (br_if $done (i32.eqz (ref.test (ref $cons) (local.get $r))))
              (local.set $l (call $list_remove_first (local.get $l) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $r)))))
              (local.set $r (struct.get $cons 1 (ref.cast (ref $cons) (local.get $r))))
              (br $lp)))
            (local.get $l))\
        """,
      "$list_remove_first" =>
        """
          (func $list_remove_first (param $l (ref null eq)) (param $x (ref null eq)) (result (ref null eq))
            (local $acc (ref null eq)) (local $h (ref null eq)) (local $out (ref null eq))
            (block $found (block $miss (loop $lp
              (br_if $miss (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (local.set $h (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br_if $found #{term_eq("(local.get $h)", "(local.get $x)")})
              (local.set $acc (struct.new $cons (local.get $h) (local.get $acc)))
              (br $lp))))
            ;; $miss falls through with every element in $acc; $found skips the matched head.
            ;; reverse $acc onto $l
            (local.set $out (local.get $l))
            (block $d2 (loop $l2
              (br_if $d2 (i32.eqz (ref.test (ref $cons) (local.get $acc))))
              (local.set $out (struct.new $cons (struct.get $cons 0 (ref.cast (ref $cons) (local.get $acc))) (local.get $out)))
              (local.set $acc (struct.get $cons 1 (ref.cast (ref $cons) (local.get $acc))))
              (br $l2)))
            (local.get $out))\
        """,
      # binary <-> byte-list conversions
      "$erlang.binary_to_list_1" =>
        """
          (func $erlang.binary_to_list_1 (param $b (ref null eq)) (result (ref null eq))
            (local $fb (ref $bytes)) (local $i i32) (local $out (ref null eq))
            (local.set $fb (call $bin_bytes (local.get $b)))
            (local.set $i (array.len (local.get $fb)))
            (block $done (loop $lp
              (br_if $done (i32.eqz (local.get $i)))
              (local.set $i (i32.sub (local.get $i) (i32.const 1)))
              (local.set $out (struct.new $cons (ref.i31 (array.get_u $bytes (local.get $fb) (local.get $i))) (local.get $out)))
              (br $lp)))
            (local.get $out))\
        """,
      "$erlang.list_to_binary_1" =>
        """
          (func $erlang.list_to_binary_1 (param $l (ref null eq)) (result (ref null eq))
            (return_call $erlang.iolist_to_binary_1 (local.get $l)))\
        """,
      # :persistent_term as a single mutable global holding an assoc list (term-keyed). Real
      # storage semantics: put stores, get/2 returns the stored value or the default. Used by
      # pure caches (pyex builtins env); storing is what keeps cache-warm hot paths fast.
      "$persistent_term.put_2" =>
        """
          (func $persistent_term.put_2 (param $k (ref null eq)) (param $v (ref null eq)) (result (ref null eq))
            (global.set $ptermtab (struct.new $cons (array.new_fixed $tuple 2 (local.get $k) (local.get $v)) (global.get $ptermtab)))
            (global.get $atom_ok))\
        """,
      "$persistent_term.get_2" =>
        """
          (func $persistent_term.get_2 (param $k (ref null eq)) (param $d (ref null eq)) (result (ref null eq))
            (local $l (ref null eq)) (local $h (ref $tuple))
            (local.set $l (global.get $ptermtab))
            (block $done (loop $lp
              (br_if $done (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (local.set $h (ref.cast (ref $tuple) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))))
              (if #{term_eq("(array.get $tuple (local.get $h) (i32.const 0))", "(local.get $k)")}
                (then (return (array.get $tuple (local.get $h) (i32.const 1)))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (local.get $d))\
        """,
      # :sql_host.exec(sql_binary, params_json_binary) -> rows_json_binary. A SQL database as a
      # host effect, exactly like :file — the backing decides: node:sqlite locally, the Durable
      # Object's synchronous ctx.storage.sql in production. A SQL error throws host-side -> an
      # honest trap carrying the SQLite message.
      "$sql_host.exec_2" =>
        if(Process.get(:sql_shim),
          do: """
            (func $sql_host.exec_2 (param $q (ref null eq)) (param $p (ref null eq)) (result (ref null eq))
              (return_call $host_sql_exec (local.get $q) (local.get $p)))\
          """,
          else: "  (func $sql_host.exec_2 (param $q (ref null eq)) (param $p (ref null eq)) (result (ref null eq)) (unreachable))"),
      "$Elixir_46_IO.puts_1" =>
        if(Process.get(:io_shim),
          do: """
            (func $Elixir_46_IO.puts_1 (param $x (ref null eq)) (result (ref null eq))
              (drop (call $host_io_puts (local.get $x)))
              (global.get $atom_ok))\
          """,
          else: "  (func $Elixir_46_IO.puts_1 (param $x (ref null eq)) (result (ref null eq)) (unreachable))"),
      "$Elixir_46_IO.puts_2" =>
        """
          (func $Elixir_46_IO.puts_2 (param $dev (ref null eq)) (param $x (ref null eq)) (result (ref null eq))
            (return_call $Elixir_46_IO.puts_1 (local.get $x)))\
        """,
      "$Elixir_46_IO.warn_1" =>
        if(Process.get(:io_shim),
          do: """
            (func $Elixir_46_IO.warn_1 (param $x (ref null eq)) (result (ref null eq))
              (drop (call $host_io_warn (local.get $x)))
              (global.get $atom_ok))\
          """,
          else: "  (func $Elixir_46_IO.warn_1 (param $x (ref null eq)) (result (ref null eq)) (unreachable))"),
      # ── bit-level (sub-byte) bitstring primitives ──────────────────────────────────────────
      # 64-bit MSB-first bit read (the i32 $bits_read truncates past 32 bits — 52-bit float
      # mantissas need this). Per-bit loop: simple and correct; these paths aren't hot.
      "$bits_read64" =>
        """
          (func $bits_read64 (param $b (ref null $bytes)) (param $pos i32) (param $n i32) (result i64)
            (local $i i32) (local $acc i64) (local $bp i32)
            (block $d (loop $l
              (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
              (local.set $bp (i32.add (local.get $pos) (local.get $i)))
              (local.set $acc (i64.or (i64.shl (local.get $acc) (i64.const 1))
                (i64.extend_i32_u (i32.and (i32.shr_u (array.get_u $bytes (local.get $b) (i32.div_u (local.get $bp) (i32.const 8)))
                                                       (i32.sub (i32.const 7) (i32.rem_u (local.get $bp) (i32.const 8))))
                                            (i32.const 1)))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $l)))
            (local.get $acc))\
        """,
      # MSB-first bit write of the low `n` bits of $v at bit position $pos.
      "$bits_write" =>
        """
          (func $bits_write (param $d (ref $bytes)) (param $pos i32) (param $n i32) (param $v i64)
            (local $i i32) (local $bp i32) (local $byte i32)
            (block $dn (loop $l
              (br_if $dn (i32.ge_u (local.get $i) (local.get $n)))
              (if (i32.and (i32.wrap_i64 (i64.shr_u (local.get $v) (i64.extend_i32_u (i32.sub (i32.sub (local.get $n) (i32.const 1)) (local.get $i))))) (i32.const 1))
                (then
                  (local.set $bp (i32.add (local.get $pos) (local.get $i)))
                  (local.set $byte (i32.div_u (local.get $bp) (i32.const 8)))
                  (array.set $bytes (local.get $d) (local.get $byte)
                    (i32.or (array.get_u $bytes (local.get $d) (local.get $byte))
                            (i32.shl (i32.const 1) (i32.sub (i32.const 7) (i32.rem_u (local.get $bp) (i32.const 8))))))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $l)))
          )\
        """,
      # integer term -> i64 across the tiers (i31 / $i64 / host $big), for bit-segment values.
      "$term_i64" => term_i64_wat(Process.get(:bignum)),
      # little-endian byte-multiple integer read (id::little-16 etc.): bytes ascending, shifts ascending.
      "$bits_read64_le" =>
        """
          (func $bits_read64_le (param $b (ref null $bytes)) (param $pos i32) (param $n i32) (result i64)
            (local $i i32) (local $nb i32) (local $acc i64) (local $byte i32)
            (local.set $nb (i32.div_u (local.get $n) (i32.const 8)))
            (local.set $byte (i32.div_u (local.get $pos) (i32.const 8)))
            (block $d (loop $l
              (br_if $d (i32.ge_u (local.get $i) (local.get $nb)))
              (local.set $acc (i64.or (local.get $acc)
                (i64.shl (i64.extend_i32_u (array.get_u $bytes (local.get $b) (i32.add (local.get $byte) (local.get $i))))
                         (i64.extend_i32_u (i32.shl (local.get $i) (i32.const 3))))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $l)))
            (local.get $acc))\
        """,
      # MSB-first bit-range copy between byte arrays (sub-byte extraction/append). Per-bit; not hot.
      "$bits_copy" =>
        """
          (func $bits_copy (param $s (ref $bytes)) (param $sp i32) (param $d (ref $bytes)) (param $dp i32) (param $n i32)
            (local $i i32) (local $bit i32) (local $bp i32) (local $byte i32)
            (block $dn (loop $l
              (br_if $dn (i32.ge_u (local.get $i) (local.get $n)))
              (local.set $bp (i32.add (local.get $sp) (local.get $i)))
              (local.set $bit (i32.and (i32.shr_u (array.get_u $bytes (local.get $s) (i32.div_u (local.get $bp) (i32.const 8)))
                                                   (i32.sub (i32.const 7) (i32.rem_u (local.get $bp) (i32.const 8)))) (i32.const 1)))
              (if (local.get $bit) (then
                (local.set $bp (i32.add (local.get $dp) (local.get $i)))
                (local.set $byte (i32.div_u (local.get $bp) (i32.const 8)))
                (array.set $bytes (local.get $d) (local.get $byte)
                  (i32.or (array.get_u $bytes (local.get $d) (local.get $byte))
                          (i32.shl (i32.const 1) (i32.sub (i32.const 7) (i32.rem_u (local.get $bp) (i32.const 8))))))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $l)))
          )\
        """,
      # extract $n bits at bit-position $p of $s into a fresh value: $bitstr when n%8 != 0, else $binary.
      "$bits_extract" =>
        """
          (func $bits_extract (param $s (ref $bytes)) (param $p i32) (param $n i32) (result (ref null eq))
            (local $d (ref $bytes))
            (local.set $d (array.new_default $bytes (i32.div_u (i32.add (local.get $n) (i32.const 7)) (i32.const 8))))
            (call $bits_copy (local.get $s) (local.get $p) (local.get $d) (i32.const 0) (local.get $n))
            (if (result (ref null eq)) (i32.rem_u (local.get $n) (i32.const 8))
              (then (struct.new $bitstr (local.get $d) (local.get $n)))
              (else (struct.new $binary (local.get $d)))))\
        """,
      # :unicode NF* normalization — host (JS .normalize, same Unicode tables). Gated bodies.
      "$unicode.characters_to_nfc_binary_1" => uninorm_wat("nfc"),
      "$unicode.characters_to_nfd_binary_1" => uninorm_wat("nfd"),
      "$unicode.characters_to_nfkc_binary_1" => uninorm_wat("nfkc"),
      "$unicode.characters_to_nfkd_binary_1" => uninorm_wat("nfkd"),
      # epp:default_encoding/0 — a constant (:utf8); io_lib consults it for encoding decisions.
      "$epp.default_encoding_0" =>
        """
          (func $epp.default_encoding_0 (result (ref null eq))
            (global.get $atom_utf8))\
        """,
      # io:printable_range/0 — :latin1 unless the emulator runs +pc unicode (we match the default).
      "$io.printable_range_0" =>
        """
          (func $io.printable_range_0 (result (ref null eq))
            (global.get $atom_latin1))\
        """,
      # iolist_size/1 — byte size of any iodata (via the existing flattener).
      "$erlang.iolist_size_1" =>
        """
          (func $erlang.iolist_size_1 (param $l (ref null eq)) (result (ref null eq))
            (ref.i31 (array.len (struct.get $binary 0 (ref.cast (ref $binary) (call $erlang.iolist_to_binary_1 (local.get $l)))))))\
        """,
      # maps:take/2 — {Value, MapWithoutKey} | :error (what Map.pop/pop! route through).
      "$maps.take_2" =>
        """
          (func $maps.take_2 (param $k (ref null eq)) (param $m (ref null eq)) (result (ref null eq))
            (if (i32.eqz (call $map_has (local.get $m) (local.get $k))) (then (return (global.get $atom_error))))
            (array.new_fixed $tuple 2
              (struct.get $mnode 1 (ref.as_non_null (call $map_get (local.get $m) (local.get $k))))
              (call $maps.remove_2 (local.get $k) (local.get $m))))\
        """,
      # erts_internal:mc_iterator/1 — OTP-27 map cursor ({K, V, Next} chain ending :none; :none for
      # an empty map). We build the WHOLE chain eagerly from the sorted kv array, so mc_refill (the
      # lazy continuation for big maps) is never reached. Iteration order is key-sorted — the
      # documented map-order delta (LIMITATIONS §2).
      "$erts_internal.mc_iterator_1" =>
        """
          (func $erts_internal.mc_iterator_1 (param $m (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $i i32) (local $acc (ref null eq))
            (local.set $a (call $map_kv (local.get $m)))
            (local.set $i (array.len (local.get $a)))
            (local.set $acc (global.get $atom_none))
            (block $d (loop $l
              (br_if $d (i32.eqz (local.get $i)))
              (local.set $acc (array.new_fixed $tuple 3
                (array.get $tuple (local.get $a) (i32.sub (local.get $i) (i32.const 2)))
                (array.get $tuple (local.get $a) (i32.sub (local.get $i) (i32.const 1)))
                (local.get $acc)))
              (local.set $i (i32.sub (local.get $i) (i32.const 2)))
              (br $l)))
            (local.get $acc))\
        """,
      "$erts_internal.mc_refill_1" =>
        """
          (func $erts_internal.mc_refill_1 (param $c (ref null eq)) (result (ref null eq))
            (unreachable))\
        """,
      # maps:update/3 — replace an EXISTING key's value; {:badkey, K} error if absent (what
      # Kernel.struct!/2 relies on to validate field names).
      "$maps.update_3" =>
        """
          (func $maps.update_3 (param $k (ref null eq)) (param $v (ref null eq)) (param $m (ref null eq)) (result (ref null eq))
            (if (i32.eqz (call $map_has (local.get $m) (local.get $k)))
              (then (drop (call $erlang.error_1 (array.new_fixed $tuple 2 (global.get $atom_badkey) (local.get $k)))) (unreachable)))
            (return_call $map_put (local.get $m) (local.get $k) (local.get $v)))\
        """,
      # maps:to_list/1 — [{k,v}, …] in key-sorted order (the kv array is kept sorted). Walk from
      # the last pair backward, prepending, so the result list is ascending by key.
      "$maps.to_list_1" =>
        """
          (func $maps.to_list_1 (param $m (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $i i32) (local $out (ref null eq))
            (local.set $a (call $map_kv (local.get $m)))
            (local.set $i (array.len (local.get $a)))
            (block $done (loop $lp
              (br_if $done (i32.eqz (local.get $i)))
              (local.set $i (i32.sub (local.get $i) (i32.const 2)))
              (local.set $out (struct.new $cons
                (array.new_fixed $tuple 2 (array.get $tuple (local.get $a) (local.get $i)) (array.get $tuple (local.get $a) (i32.add (local.get $i) (i32.const 1))))
                (local.get $out)))
              (br $lp)))
            (local.get $out))\
        """,
      # maps:values/1, maps:keys/1 — in key-sorted order (walk the sorted kv array back-to-front).
      "$maps.values_1" =>
        """
          (func $maps.values_1 (param $m (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $i i32) (local $out (ref null eq))
            (local.set $a (call $map_kv (local.get $m)))
            (local.set $i (array.len (local.get $a)))
            (block $d (loop $lp (br_if $d (i32.eqz (local.get $i)))
              (local.set $i (i32.sub (local.get $i) (i32.const 2)))
              (local.set $out (struct.new $cons (array.get $tuple (local.get $a) (i32.add (local.get $i) (i32.const 1))) (local.get $out)))
              (br $lp)))
            (local.get $out))\
        """,
      "$maps.keys_1" =>
        """
          (func $maps.keys_1 (param $m (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $i i32) (local $out (ref null eq))
            (local.set $a (call $map_kv (local.get $m)))
            (local.set $i (array.len (local.get $a)))
            (block $d (loop $lp (br_if $d (i32.eqz (local.get $i)))
              (local.set $i (i32.sub (local.get $i) (i32.const 2)))
              (local.set $out (struct.new $cons (array.get $tuple (local.get $a) (local.get $i)) (local.get $out)))
              (br $lp)))
            (local.get $out))\
        """,
      # common maps NIFs over the $map kv array (find/get/put/is_key).
      "$maps.find_2" =>
        """
          (func $maps.find_2 (param $k (ref null eq)) (param $m (ref null eq)) (result (ref null eq))
            (local $n (ref null $mnode))
            (local.set $n (call $map_get (local.get $m) (local.get $k)))
            (if (result (ref null eq)) (ref.is_null (local.get $n))
              (then (global.get $atom_error))
              (else (array.new_fixed $tuple 2 (global.get $atom_ok) (struct.get $mnode 1 (ref.as_non_null (local.get $n)))))))\
        """,
      "$maps.get_2" =>
        """
          (func $maps.get_2 (param $k (ref null eq)) (param $m (ref null eq)) (result (ref null eq))
            (local $n (ref null $mnode))
            (local.set $n (call $map_get (local.get $m) (local.get $k)))
            (if (ref.is_null (local.get $n)) (then (unreachable)))
            (struct.get $mnode 1 (ref.as_non_null (local.get $n))))\
        """,
      "$maps.get_3" =>
        """
          (func $maps.get_3 (param $k (ref null eq)) (param $m (ref null eq)) (param $def (ref null eq)) (result (ref null eq))
            (local $n (ref null $mnode))
            (local.set $n (call $map_get (local.get $m) (local.get $k)))
            (if (result (ref null eq)) (ref.is_null (local.get $n))
              (then (local.get $def))
              (else (struct.get $mnode 1 (ref.as_non_null (local.get $n))))))\
        """,
      "$maps.put_3" =>
        """
          (func $maps.put_3 (param $k (ref null eq)) (param $v (ref null eq)) (param $m (ref null eq)) (result (ref null eq))
            (return_call $map_put (local.get $m) (local.get $k) (local.get $v)))\
        """,
      # maps:from_keys(Keys, Value) -> a map mapping each key to Value (backs :sets v2 / MapSet.new).
      "$maps.from_keys_2" =>
        """
          (func $maps.from_keys_2 (param $keys (ref null eq)) (param $v (ref null eq)) (result (ref null eq))
            (local $m (ref null eq)) (local $l (ref null eq))
            (local.set $m (struct.new $map (ref.null $mnode)))
            (local.set $l (local.get $keys))
            (block $d (loop $lp
              (br_if $d (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (local.set $m (call $map_put (local.get $m) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))) (local.get $v)))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (local.get $m))\
        """,
      # maps:iterator(Map) -> an iterator; we use the flattened {k,v} cons-list directly (see maps.next).
      "$maps.iterator_1" =>
        """
          (func $maps.iterator_1 (param $m (ref null eq)) (result (ref null eq))
            (return_call $maps.to_list_1 (local.get $m)))\
        """,
      # maps:next(Iter) -> {Key, Value, NextIter} | none. Iter is the {k,v} cons-list from iterator/1.
      "$maps.next_1" =>
        """
          (func $maps.next_1 (param $it (ref null eq)) (result (ref null eq))
            (local $kv (ref $tuple))
            (if (i32.eqz (ref.test (ref $cons) (local.get $it))) (then (return (global.get $atom_none))))
            (local.set $kv (ref.cast (ref $tuple) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $it)))))
            (array.new_fixed $tuple 3
              (array.get $tuple (local.get $kv) (i32.const 0))
              (array.get $tuple (local.get $kv) (i32.const 1))
              (struct.get $cons 1 (ref.cast (ref $cons) (local.get $it)))))\
        """,
      # proplists:get_value(Key, List, Default) -> value of {Key,V} (or `true` for a bare Key), else Default.
      "$proplists.get_value_3" =>
        """
          (func $proplists.get_value_3 (param $key (ref null eq)) (param $l (ref null eq)) (param $def (ref null eq)) (result (ref null eq))
            (local $h (ref null eq)) (local $t (ref $tuple))
            (block $d (loop $lp
              (br_if $d (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (local.set $h (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))
              (if (ref.test (ref $tuple) (local.get $h))
                (then
                  (local.set $t (ref.cast (ref $tuple) (local.get $h)))
                  (if (i32.ge_u (array.len (local.get $t)) (i32.const 2))
                    (then (if #{term_eq("(array.get $tuple (local.get $t) (i32.const 0))", "(local.get $key)")}
                      (then (return (array.get $tuple (local.get $t) (i32.const 1)))))))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (local.get $def))\
        """,
      "$maps.remove_2" =>
        """
          ;; remove: flatten to the sorted array, splice the pair out, rebuild the tree (O(n log n) —
          ;; remove isn't a hot path; this avoids a separate tree-delete with its own rebalancing).
          (func $maps.remove_2 (param $k (ref null eq)) (param $m (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $n i32) (local $i i32) (local $idx i32) (local $out (ref $tuple))
            (if (i32.eqz (call $map_has (local.get $m) (local.get $k))) (then (return (local.get $m))))
            (local.set $a (call $map_kv (local.get $m)))
            (local.set $n (array.len (local.get $a)))
            (local.set $idx (i32.const -1))
            (block $f (loop $fl (br_if $f (i32.ge_u (local.get $i) (local.get $n)))
              (if (i32.eqz (call $term_compare (array.get $tuple (local.get $a) (local.get $i)) (local.get $k)))
                (then (local.set $idx (local.get $i)) (br $f)))
              (local.set $i (i32.add (local.get $i) (i32.const 2))) (br $fl)))
            (local.set $out (array.new_default $tuple (i32.sub (local.get $n) (i32.const 2))))
            (array.copy $tuple $tuple (local.get $out) (i32.const 0) (local.get $a) (i32.const 0) (local.get $idx))
            (array.copy $tuple $tuple (local.get $out) (local.get $idx) (local.get $a) (i32.add (local.get $idx) (i32.const 2)) (i32.sub (i32.sub (local.get $n) (local.get $idx)) (i32.const 2)))
            (call $map_from_kv (local.get $out)))\
        """,
      "$maps.is_key_2" =>
        """
          (func $maps.is_key_2 (param $k (ref null eq)) (param $m (ref null eq)) (result (ref null eq))
            (if (result (ref null eq)) (call $map_has (local.get $m) (local.get $k))
              (then (global.get $atom_true)) (else (global.get $atom_false))))\
        """,
      "$erts_internal.map_next_3" =>
        """
          ;; idx is a PAIR index here (0,1,2,…); select the idx-th node in key order in O(log n) so
          ;; iterating a whole map is O(n log n), not O(n²) (no per-step flatten).
          (func $erts_internal.map_next_3 (param $idx_term (ref null eq)) (param $m (ref null eq)) (param $tag (ref null eq)) (result (ref null eq))
            (local $idx i32) (local $node (ref null $mnode))
            (local.set $idx (i31.get_s (ref.cast (ref i31) (local.get $idx_term))))
            (local.set $node (call $msel (call $map_root (local.get $m)) (local.get $idx)))
            (if (ref.is_null (local.get $node)) (then (return (global.get $atom_none))))
            (array.new_fixed $tuple 3
              (struct.get $mnode 0 (ref.as_non_null (local.get $node)))
              (struct.get $mnode 1 (ref.as_non_null (local.get $node)))
              (struct.new $cons (ref.i31 (i32.add (local.get $idx) (i32.const 1))) (local.get $m))))\
        """,
      # maps:merge/2 — entries of the second map win; put each of m2's pairs into m1.
      "$maps.merge_2" =>
        """
          (func $maps.merge_2 (param $m1 (ref null eq)) (param $m2 (ref null eq)) (result (ref null eq))
            (local $a (ref $tuple)) (local $n i32) (local $i i32) (local $out (ref null eq))
            (local.set $out (local.get $m1))
            (local.set $a (call $map_kv (local.get $m2)))
            (local.set $n (array.len (local.get $a)))
            (block $done (loop $lp
              (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
              (local.set $out (call $map_put (local.get $out)
                (array.get $tuple (local.get $a) (local.get $i))
                (array.get $tuple (local.get $a) (i32.add (local.get $i) (i32.const 1)))))
              (local.set $i (i32.add (local.get $i) (i32.const 2)))
              (br $lp)))
            (local.get $out))\
        """,
      # process_info(Pid, Item). proc_lib wants [] for unknown registered_name, while gen_server's
      # terminate path expects {:current_stacktrace, []} for current_stacktrace.
      "$erlang.process_info_2" =>
        """
          (func $erlang.process_info_2 (param $p (ref null eq)) (param $item (ref null eq)) (result (ref null eq))
            (if (result (ref null eq)) (ref.eq (local.get $item) (global.get $atom_current_stacktrace))
              (then (array.new_fixed $tuple 2 (global.get $atom_current_stacktrace) (ref.null none)))
              (else (ref.null none))))\
        """,
      # Optional callback checks (e.g. GenServer terminate/2). We do not expose a dynamic code server;
      # absent callbacks are reported as not exported.
      "$erlang.function_exported_3" =>
        """
          (func $erlang.function_exported_3 (param $m (ref null eq)) (param $f (ref null eq)) (param $a (ref null eq)) (result (ref null eq))
            (global.get $atom_false))\
        """,
      "$erlang.exit_1" =>
        if(Process.get(:exc),
          do: """
            (func $erlang.exit_1 (param $reason (ref null eq)) (result (ref null eq))
              (throw $exc (global.get $atom_exit) (local.get $reason) (ref.null none)))\
          """,
          else: if(Process.get(:proc),
            do: """
              (func $erlang.exit_1 (param $reason (ref null eq)) (result (ref null eq))
                (call $exit_raw (local.get $reason))
                (unreachable))\
            """,
            else: """
              (func $erlang.exit_1 (param $reason (ref null eq)) (result (ref null eq))
                (unreachable))\
            """)),
      # list_to_integer/1,2 — charlist -> $binary, then delegate to the mode-gated binary_to_integer/2
      # (one parsing implementation: bignum-safe in exact mode, base-aware, consistent digit checks).
      "$erlang.list_to_integer_1" =>
        """
          (func $erlang.list_to_integer_1 (param $l (ref null eq)) (result (ref null eq))
            (return_call $erlang.list_to_integer_2 (local.get $l) (ref.i31 (i32.const 10))))\
        """,
      "$erlang.list_to_integer_2" =>
        """
          (func $erlang.list_to_integer_2 (param $l (ref null eq)) (param $base (ref null eq)) (result (ref null eq))
            (local $n i32) (local $t (ref null eq)) (local $d (ref $bytes)) (local $i i32)
            (local.set $t (local.get $l))
            (block $c (loop $cl (br_if $c (i32.eqz (ref.test (ref $cons) (local.get $t))))
              (local.set $n (i32.add (local.get $n) (i32.const 1)))
              (local.set $t (struct.get $cons 1 (ref.cast (ref $cons) (local.get $t)))) (br $cl)))
            (local.set $d (array.new_default $bytes (local.get $n)))
            (local.set $t (local.get $l))
            (block $f (loop $fl (br_if $f (i32.ge_u (local.get $i) (local.get $n)))
              (array.set $bytes (local.get $d) (local.get $i) (i31.get_s (ref.cast (ref i31) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $t))))))
              (local.set $t (struct.get $cons 1 (ref.cast (ref $cons) (local.get $t))))
              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $fl)))
            (return_call $erlang.binary_to_integer_2 (struct.new $binary (local.get $d)) (local.get $base)))\
        """,
      "$Elixir_46_Process.get_2" =>
        """
          (func $Elixir_46_Process.get_2 (param $key (ref null eq)) (param $default (ref null eq)) (result (ref null eq))
            (local.get $default))\
        """,
      "$Elixir_46_Process.put_2" =>
        """
          (func $Elixir_46_Process.put_2 (param $key (ref null eq)) (param $value (ref null eq)) (result (ref null eq))
            (global.get $atom_nil))\
        """,
      "$erlang._43__43__2" =>
        """
          (func $erlang._43__43__2 (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
            (if (result (ref null eq)) (ref.is_null (local.get $a))
              (then (local.get $b))
              (else (struct.new $cons
                (struct.get $cons 0 (ref.cast (ref $cons) (local.get $a)))
                (call $erlang._43__43__2 (struct.get $cons 1 (ref.cast (ref $cons) (local.get $a))) (local.get $b))))))\
        """,
      "$erlang.list_to_atom_1" =>
        """
          (func $erlang.list_to_atom_1 (param $l (ref null eq)) (result (ref null eq))
            (global.get $atom_undefined))\
        """,
      # binary_to_integer/2 (base-aware) and /1 (base 10). In bignum mode (the default) it accumulates
      # through the tiered int helpers (acc = acc*base + digit on term values), so results above
      # i31/i64 promote to $big instead of truncating; in BIGNUM=0 wrapping mode it accumulates in i32
      # (consistent with that mode's arithmetic). Digits 0-9/A-Z/a-z; invalid digit / empty traps.
      "$erlang.binary_to_integer_2" => b2i_wat(Process.get(:bignum)),
      "$erlang.binary_to_integer_1" =>
        """
          (func $erlang.binary_to_integer_1 (param $bin (ref null eq)) (result (ref null eq))
            (return_call $erlang.binary_to_integer_2 (local.get $bin) (ref.i31 (i32.const 10))))\
        """,
      # integer_to_binary/2 (base-N, uppercase digits like Erlang) + /list variants. Bignum-safe in
      # exact mode (digit extraction via $int_rem/$int_div on term values); i32 in wrapping mode.
      "$erlang.integer_to_binary_2" => i2b_wat(Process.get(:bignum)),
      "$erlang.integer_to_list_1" =>
        """
          (func $erlang.integer_to_list_1 (param $x (ref null eq)) (result (ref null eq))
            (return_call $erlang.integer_to_list_2 (local.get $x) (ref.i31 (i32.const 10))))\
        """,
      "$erlang.integer_to_list_2" =>
        """
          (func $erlang.integer_to_list_2 (param $x (ref null eq)) (param $base (ref null eq)) (result (ref null eq))
            (local $b (ref $bytes)) (local $i i32) (local $out (ref null eq))
            (local.set $b (struct.get $binary 0 (ref.cast (ref $binary) (call $erlang.integer_to_binary_2 (local.get $x) (local.get $base)))))
            (local.set $i (array.len (local.get $b)))
            (block $d (loop $l
              (br_if $d (i32.eqz (local.get $i)))
              (local.set $i (i32.sub (local.get $i) (i32.const 1)))
              (local.set $out (struct.new $cons (ref.i31 (array.get_u $bytes (local.get $b) (local.get $i))) (local.get $out)))
              (br $l)))
            (local.get $out))\
        """,
      # erts_internal:cmp_term/2 — Erlang term order as -1/0/1; the existing $term_compare IS that.
      "$erts_internal.cmp_term_2" =>
        """
          (func $erts_internal.cmp_term_2 (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
            (ref.i31 (call $term_compare (local.get $a) (local.get $b))))\
        """,
      # make_ref/0 as a real function (the direct-call forms are emit-intercepted; this covers
      # captures/apply and tail-call forms). $refctr/$ref are always emitted.
      "$erlang.make_ref_0" =>
        """
          (func $erlang.make_ref_0 (result (ref null eq))
            (global.set $refctr (i32.add (global.get $refctr) (i32.const 1)))
            (struct.new $ref (global.get $refctr) (i32.const 0)))\
        """,
      "$binary.encode_unsigned_1" =>
        """
          (func $binary.encode_unsigned_1 (param $n (ref null eq)) (result (ref null eq))
            (local $bits i32) (local $len i32) (local $rem i32) (local $first i32) (local $d (ref $bytes))
            (local.set $bits (call $bigint_bit_length (call $to_big (local.get $n))))
            (if (i32.eqz (local.get $bits)) (then (local.set $bits (i32.const 1))))
            (local.set $len (i32.div_u (i32.add (local.get $bits) (i32.const 7)) (i32.const 8)))
            (local.set $rem (i32.rem_u (local.get $bits) (i32.const 8)))
            (if (i32.eqz (local.get $rem)) (then (local.set $rem (i32.const 8))))
            (local.set $first (i32.shl (i32.const 1) (i32.sub (local.get $rem) (i32.const 1))))
            (local.set $d (array.new_default $bytes (local.get $len)))
            (array.set $bytes (local.get $d) (i32.const 0) (local.get $first))
            (struct.new $binary (local.get $d)))\
        """,
      "$erlang.raise_3" =>
        if(Process.get(:exc),
          do: """
            (func $erlang.raise_3 (param $class (ref null eq)) (param $reason (ref null eq)) (param $trace (ref null eq)) (result (ref null eq))
              (throw $exc (local.get $class) (local.get $reason) (local.get $trace)))\
          """,
          else: if(Process.get(:proc),
            do: """
              (func $erlang.raise_3 (param $class (ref null eq)) (param $reason (ref null eq)) (param $trace (ref null eq)) (result (ref null eq))
                (call $exit_raw (local.get $reason))
                (unreachable))\
            """,
            else: """
              (func $erlang.raise_3 (param $class (ref null eq)) (param $reason (ref null eq)) (param $trace (ref null eq)) (result (ref null eq))
                (unreachable))\
            """)),
      # erlang:error/1,2,3 + throw/1 + nif_error/1 — the error-raising BIFs every program's error paths
      # reach (`raise X` compiles to error/1-3 with the exception struct as the reason). Same 3-mode
      # gating as raise/3: exc mode -> throw $exc with the right class; proc-only -> crash the process
      # with the reason (its supervisor/monitor sees it); neither -> honest trap. The /2 and /3 extra
      # args only annotate stacktraces (which we don't record) — semantics otherwise identical.
      "$erlang.error_1" => error_bif("error_1", "(param $r (ref null eq))", "$atom_error", "(local.get $r)"),
      "$erlang.error_2" => error_bif("error_2", "(param $r (ref null eq)) (param $a1 (ref null eq))", "$atom_error", "(local.get $r)"),
      "$erlang.error_3" => error_bif("error_3", "(param $r (ref null eq)) (param $a1 (ref null eq)) (param $a2 (ref null eq))", "$atom_error", "(local.get $r)"),
      "$erlang.nif_error_1" => error_bif("nif_error_1", "(param $r (ref null eq))", "$atom_error", "(local.get $r)"),
      "$erlang.throw_1" => error_bif("throw_1", "(param $r (ref null eq))", "$atom_throw", "(local.get $r)"),
      # lists:keyfind(Key, N, List) -> the first tuple T with element(N,T) == Key, else false.
      "$lists.keyfind_3" =>
        """
          (func $lists.keyfind_3 (param $key (ref null eq)) (param $n (ref null eq)) (param $l (ref null eq)) (result (ref null eq))
            (local $ni i32) (local $h (ref null eq)) (local $t (ref $tuple))
            (local.set $ni (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $n))) (i32.const 1)))
            (block $done (loop $lp
              (br_if $done (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (local.set $h (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))
              (if (ref.test (ref $tuple) (local.get $h)) (then
                (local.set $t (ref.cast (ref $tuple) (local.get $h)))
                (if (i32.gt_s (array.len (local.get $t)) (local.get $ni)) (then
                  (if (i32.eqz (call $term_compare (array.get $tuple (local.get $t) (local.get $ni)) (local.get $key)))
                    (then (return (local.get $h))))))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (global.get $atom_false))\
        """,
      # UTF-8 codepoint byte-length and encode (used by unicode:characters_to_binary).
      "$utf8_enc_len" =>
        """
          (func $utf8_enc_len (param $cp i32) (result i32)
            (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x80)) (then (i32.const 1))
              (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x800)) (then (i32.const 2))
                (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 0x10000)) (then (i32.const 3)) (else (i32.const 4))))))))\
        """,
      "$utf8_enc" =>
        """
          (func $utf8_enc (param $d (ref null $bytes)) (param $o i32) (param $cp i32) (result i32)
            (if (i32.lt_u (local.get $cp) (i32.const 0x80)) (then
              (array.set $bytes (ref.cast (ref $bytes) (local.get $d)) (local.get $o) (local.get $cp))
              (return (i32.add (local.get $o) (i32.const 1)))))
            (if (i32.lt_u (local.get $cp) (i32.const 0x800)) (then
              (array.set $bytes (ref.cast (ref $bytes) (local.get $d)) (local.get $o) (i32.or (i32.const 0xC0) (i32.shr_u (local.get $cp) (i32.const 6))))
              (array.set $bytes (ref.cast (ref $bytes) (local.get $d)) (i32.add (local.get $o) (i32.const 1)) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
              (return (i32.add (local.get $o) (i32.const 2)))))
            (if (i32.lt_u (local.get $cp) (i32.const 0x10000)) (then
              (array.set $bytes (ref.cast (ref $bytes) (local.get $d)) (local.get $o) (i32.or (i32.const 0xE0) (i32.shr_u (local.get $cp) (i32.const 12))))
              (array.set $bytes (ref.cast (ref $bytes) (local.get $d)) (i32.add (local.get $o) (i32.const 1)) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
              (array.set $bytes (ref.cast (ref $bytes) (local.get $d)) (i32.add (local.get $o) (i32.const 2)) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
              (return (i32.add (local.get $o) (i32.const 3)))))
            (array.set $bytes (ref.cast (ref $bytes) (local.get $d)) (local.get $o) (i32.or (i32.const 0xF0) (i32.shr_u (local.get $cp) (i32.const 18))))
            (array.set $bytes (ref.cast (ref $bytes) (local.get $d)) (i32.add (local.get $o) (i32.const 1)) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 0x3F))))
            (array.set $bytes (ref.cast (ref $bytes) (local.get $d)) (i32.add (local.get $o) (i32.const 2)) (i32.or (i32.const 0x80) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 0x3F))))
            (array.set $bytes (ref.cast (ref $bytes) (local.get $d)) (i32.add (local.get $o) (i32.const 3)) (i32.or (i32.const 0x80) (i32.and (local.get $cp) (i32.const 0x3F))))
            (i32.add (local.get $o) (i32.const 4)))\
        """,
      # unicode:characters_to_binary(Chardata) -> UTF-8 binary. Chardata = list of codepoints (i31,
      # UTF-8-encoded) and/or binaries (copied), nested. Two passes: measure byte length, then fill.
      "$cdata_len" =>
        """
          (func $cdata_len (param $t (ref null eq)) (result i32)
            (if (ref.is_null (local.get $t)) (then (return (i32.const 0))))
            (if (ref.test (ref i31) (local.get $t)) (then (return (call $utf8_enc_len (i31.get_s (ref.cast (ref i31) (local.get $t)))))))
            (if (ref.test (ref $binary) (local.get $t)) (then (return (array.len (struct.get $binary 0 (ref.cast (ref $binary) (local.get $t)))))))
            (i32.add
              (call $cdata_len (struct.get $cons 0 (ref.cast (ref $cons) (local.get $t))))
              (call $cdata_len (struct.get $cons 1 (ref.cast (ref $cons) (local.get $t))))))\
        """,
      "$cdata_fill" =>
        """
          (func $cdata_fill (param $t (ref null eq)) (param $d (ref $bytes)) (param $o i32) (result i32)
            (local $b (ref $bytes)) (local $len i32) (local $c (ref $cons))
            (if (ref.is_null (local.get $t)) (then (return (local.get $o))))
            (if (ref.test (ref i31) (local.get $t)) (then
              (return (call $utf8_enc (local.get $d) (local.get $o) (i31.get_s (ref.cast (ref i31) (local.get $t)))))))
            (if (ref.test (ref $binary) (local.get $t)) (then
              (local.set $b (struct.get $binary 0 (ref.cast (ref $binary) (local.get $t))))
              (local.set $len (array.len (local.get $b)))
              (array.copy $bytes $bytes (local.get $d) (local.get $o) (local.get $b) (i32.const 0) (local.get $len))
              (return (i32.add (local.get $o) (local.get $len)))))
            (local.set $c (ref.cast (ref $cons) (local.get $t)))
            (local.set $o (call $cdata_fill (struct.get $cons 0 (local.get $c)) (local.get $d) (local.get $o)))
            (return_call $cdata_fill (struct.get $cons 1 (local.get $c)) (local.get $d) (local.get $o)))\
        """,
      "$unicode.characters_to_binary_1" =>
        """
          (func $unicode.characters_to_binary_1 (param $t (ref null eq)) (result (ref null eq))
            (local $d (ref $bytes))
            (local.set $d (array.new_default $bytes (call $cdata_len (local.get $t))))
            (drop (call $cdata_fill (local.get $t) (local.get $d) (i32.const 0)))
            (struct.new $binary (local.get $d)))\
        """,
      # unicode_util:gc(Bin) -> [Codepoint | RestBin], or [] when empty. (One codepoint per grapheme:
      # correct for ASCII and non-combining text; combining-mark clusters are a known limitation.)
      "$unicode_util.gc_1" =>
        """
          (func $unicode_util.gc_1 (param $s (ref null eq)) (result (ref null eq))
            (local $b (ref $bytes)) (local $n i32) (local $b0 i32) (local $cp i32) (local $len i32) (local $i i32) (local $rest (ref $bytes))
            (if (ref.is_null (local.get $s)) (then (return (ref.null none))))
            (local.set $b (struct.get $binary 0 (ref.cast (ref $binary) (local.get $s))))
            (local.set $n (array.len (local.get $b)))
            (if (i32.eqz (local.get $n)) (then (return (ref.null none))))
            (local.set $b0 (array.get_u $bytes (local.get $b) (i32.const 0)))
            (if (i32.lt_u (local.get $b0) (i32.const 0x80))
              (then (local.set $cp (local.get $b0)) (local.set $len (i32.const 1)))
              (else (if (i32.lt_u (local.get $b0) (i32.const 0xE0))
                (then (local.set $cp (i32.and (local.get $b0) (i32.const 0x1F))) (local.set $len (i32.const 2)))
                (else (if (i32.lt_u (local.get $b0) (i32.const 0xF0))
                  (then (local.set $cp (i32.and (local.get $b0) (i32.const 0x0F))) (local.set $len (i32.const 3)))
                  (else (local.set $cp (i32.and (local.get $b0) (i32.const 0x07))) (local.set $len (i32.const 4))))))))
            (local.set $i (i32.const 1))
            (block $d (loop $lp (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
              (local.set $cp (i32.or (i32.shl (local.get $cp) (i32.const 6))
                (i32.and (array.get_u $bytes (local.get $b) (local.get $i)) (i32.const 0x3F))))
              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $lp)))
            (local.set $rest (array.new_default $bytes (i32.sub (local.get $n) (local.get $len))))
            (array.copy $bytes $bytes (local.get $rest) (i32.const 0) (local.get $b) (local.get $len) (i32.sub (local.get $n) (local.get $len)))
            (struct.new $cons (ref.i31 (local.get $cp)) (struct.new $binary (local.get $rest))))\
        """,
      # logging + crash-report functions are side-effects (no observable effect on results). No-op them
      # so a crashing process still exits with the right reason (propagating to its supervisor).
      "$logger.allow_2" =>
        """
          (func $logger.allow_2 (param $lvl (ref null eq)) (param $mod (ref null eq)) (result (ref null eq))
            (global.get $atom_false))\
        """,
      "$logger.macro_log_3" => "  (func $logger.macro_log_3 (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (result (ref null eq)) (global.get $atom_ok))",
      "$logger.macro_log_4" => "  (func $logger.macro_log_4 (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (result (ref null eq)) (global.get $atom_ok))",
      "$logger.log_3" => "  (func $logger.log_3 (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (result (ref null eq)) (global.get $atom_ok))",
      "$logger.error_2" => "  (func $logger.error_2 (param (ref null eq)) (param (ref null eq)) (result (ref null eq)) (global.get $atom_ok))",
      # lists:keymember(Key, N, List) -> true if some tuple T has element(N,T) == Key, else false.
      "$lists.keymember_3" =>
        """
          (func $lists.keymember_3 (param $key (ref null eq)) (param $n (ref null eq)) (param $l (ref null eq)) (result (ref null eq))
            (local $ni i32) (local $h (ref null eq)) (local $t (ref $tuple))
            (local.set $ni (i32.sub (i31.get_s (ref.cast (ref i31) (local.get $n))) (i32.const 1)))
            (block $done (loop $lp
              (br_if $done (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (local.set $h (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))
              (if (ref.test (ref $tuple) (local.get $h)) (then
                (local.set $t (ref.cast (ref $tuple) (local.get $h)))
                (if (i32.gt_s (array.len (local.get $t)) (local.get $ni)) (then
                  (if (i32.eqz (call $term_compare (array.get $tuple (local.get $t) (local.get $ni)) (local.get $key)))
                    (then (return (global.get $atom_true))))))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (global.get $atom_false))\
        """,
      "$lists.member_2" =>
        """
          (func $lists.member_2 (param $x (ref null eq)) (param $l (ref null eq)) (result (ref null eq))
            (block $done (loop $lp
              (br_if $done (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (if #{term_eq("(struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))", "(local.get $x)")}
                (then (return (global.get $atom_true))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (global.get $atom_false))\
        """,
      # Erlang term order, the REAL total order (number < atom < tuple < map < list < bitstring;
      # correct within each). The genuinely-native primitive; the real :lists.sort/max/min are
      # pure Erlang and compile on top of it. Atoms compare by index = name order (atoms are
      # interned name-sorted, see run/1). Maps: TODO (full map ordering).
      "$term_rank" =>
        """
          ;; Erlang term order: number < atom < ref < pid < tuple < map < list < bitstring
          (func $term_rank (param $x (ref null eq)) (result i32)
            ;; order tuned for the SLOW path (callers' fast paths already peel off i31/atom/binary):
            ;; integers, then map/tuple/cons (the common compound terms), then the rare types.
            (if (ref.test (ref i31) (local.get $x)) (then (return (i32.const 0))))#{if Process.get(:bignum), do: "\n            (if (ref.test (ref $i64) (local.get $x)) (then (return (i32.const 0))))\n            (if (ref.test (ref $big) (local.get $x)) (then (return (i32.const 0))))", else: ""}#{if Process.get(:float), do: "\n            (if (ref.test (ref $float) (local.get $x)) (then (return (i32.const 0))))   ;; float is a NUMBER (rank 0), sorts with ints", else: ""}
            (if (ref.test (ref $map) (local.get $x)) (then (return (i32.const 5))))
            (if (ref.test (ref $tuple) (local.get $x)) (then (return (i32.const 4))))
            (if (ref.test (ref $cons) (local.get $x)) (then (return (i32.const 6))))
            (if (ref.is_null (local.get $x)) (then (return (i32.const 6))))
            (if (ref.test (ref $atom) (local.get $x)) (then (return (i32.const 1))))
            (if (ref.test (ref $binary) (local.get $x)) (then (return (i32.const 7))))
            (if (ref.test (ref $ref) (local.get $x)) (then (return (i32.const 2))))
            (if (ref.test (ref $pid) (local.get $x)) (then (return (i32.const 3))))
            (i32.const 8))\
        """,
      "$term_compare" =>
        """
          (func $term_compare (param $a (ref null eq)) (param $b (ref null eq)) (result i32)
            (local $ra i32) (local $rb i32) (local $i i32) (local $na i32) (local $nb i32) (local $c i32)
            (local $ta (ref null $tuple)) (local $tb (ref null $tuple)) (local $ma (ref $tuple)) (local $mb (ref $tuple)) (local $xa (ref null $bytes)) (local $xb (ref null $bytes))
            ;; FAST PATHS: same-type comparisons (the hot case — map keys, sort, guards) handled before
            ;; the double term_rank dispatch. Identical logic to the rank handlers below, just hoisted.
            (if (i32.and (ref.test (ref i31) (local.get $a)) (ref.test (ref i31) (local.get $b))) (then
              (local.set $na (i31.get_s (ref.cast (ref i31) (local.get $a)))) (local.set $nb (i31.get_s (ref.cast (ref i31) (local.get $b))))
              (return (i32.sub (i32.gt_s (local.get $na) (local.get $nb)) (i32.lt_s (local.get $na) (local.get $nb))))))
            (if (i32.and (ref.test (ref $atom) (local.get $a)) (ref.test (ref $atom) (local.get $b))) (then
              (local.set $na (struct.get $atom 0 (ref.cast (ref $atom) (local.get $a)))) (local.set $nb (struct.get $atom 0 (ref.cast (ref $atom) (local.get $b))))
              (return (i32.sub (i32.gt_s (local.get $na) (local.get $nb)) (i32.lt_s (local.get $na) (local.get $nb))))))
            (if (i32.and (ref.test (ref $binary) (local.get $a)) (ref.test (ref $binary) (local.get $b))) (then
              (local.set $xa (struct.get $binary 0 (ref.cast (ref $binary) (local.get $a)))) (local.set $xb (struct.get $binary 0 (ref.cast (ref $binary) (local.get $b))))
              (local.set $na (array.len (local.get $xa))) (local.set $nb (array.len (local.get $xb))) (local.set $i (i32.const 0))
              (block $xd2 (loop $xl2
                (br_if $xd2 (i32.ge_u (local.get $i) (local.get $na))) (br_if $xd2 (i32.ge_u (local.get $i) (local.get $nb)))
                (local.set $c (i32.sub (array.get_u $bytes (local.get $xa) (local.get $i)) (array.get_u $bytes (local.get $xb) (local.get $i))))
                (if (i32.ne (local.get $c) (i32.const 0)) (then (return (i32.sub (i32.gt_s (local.get $c) (i32.const 0)) (i32.lt_s (local.get $c) (i32.const 0))))))
                (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $xl2)))
              (return (i32.sub (i32.gt_s (local.get $na) (local.get $nb)) (i32.lt_s (local.get $na) (local.get $nb))))))
            (local.set $ra (call $term_rank (local.get $a))) (local.set $rb (call $term_rank (local.get $b)))
            (if (i32.lt_s (local.get $ra) (local.get $rb)) (then (return (i32.const -1))))
            (if (i32.gt_s (local.get $ra) (local.get $rb)) (then (return (i32.const 1))))
            ;; rank 0: number (tiered through $int_cmp when bignums may be present)
            (if (i32.eqz (local.get $ra)) (then#{if Process.get(:bignum), do: "\n              (return (call $int_cmp (local.get $a) (local.get $b)))", else: "
              (local.set $na (i31.get_s (ref.cast (ref i31) (local.get $a)))) (local.set $nb (i31.get_s (ref.cast (ref i31) (local.get $b))))
              (return (i32.sub (i32.gt_s (local.get $na) (local.get $nb)) (i32.lt_s (local.get $na) (local.get $nb))))"}))
            ;; rank 1: atom (index = name order)
            (if (i32.eq (local.get $ra) (i32.const 1)) (then
              (local.set $na (struct.get $atom 0 (ref.cast (ref $atom) (local.get $a)))) (local.set $nb (struct.get $atom 0 (ref.cast (ref $atom) (local.get $b))))
              (return (i32.sub (i32.gt_s (local.get $na) (local.get $nb)) (i32.lt_s (local.get $na) (local.get $nb))))))
            ;; rank 2: reference, rank 3: pid — compare by i32 id
            (if (i32.eq (local.get $ra) (i32.const 2)) (then
              (local.set $na (struct.get $ref 0 (ref.cast (ref $ref) (local.get $a)))) (local.set $nb (struct.get $ref 0 (ref.cast (ref $ref) (local.get $b))))
              (return (i32.sub (i32.gt_s (local.get $na) (local.get $nb)) (i32.lt_s (local.get $na) (local.get $nb))))))
            (if (i32.eq (local.get $ra) (i32.const 3)) (then
              (local.set $na (struct.get $pid 0 (ref.cast (ref $pid) (local.get $a)))) (local.set $nb (struct.get $pid 0 (ref.cast (ref $pid) (local.get $b))))
              (return (i32.sub (i32.gt_s (local.get $na) (local.get $nb)) (i32.lt_s (local.get $na) (local.get $nb))))))
            ;; rank 6: list (head then tail); nil < non-empty
            (if (i32.eq (local.get $ra) (i32.const 6)) (then
              (if (ref.is_null (local.get $a)) (then (return (if (result i32) (ref.is_null (local.get $b)) (then (i32.const 0)) (else (i32.const -1))))))
              (if (ref.is_null (local.get $b)) (then (return (i32.const 1))))
              (local.set $c (call $term_compare (struct.get $cons 0 (ref.cast (ref $cons) (local.get $a))) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $b)))))
              (if (i32.ne (local.get $c) (i32.const 0)) (then (return (local.get $c))))
              (return (call $term_compare (struct.get $cons 1 (ref.cast (ref $cons) (local.get $a))) (struct.get $cons 1 (ref.cast (ref $cons) (local.get $b)))))))
            ;; rank 4: tuple (size then elementwise)
            (if (i32.eq (local.get $ra) (i32.const 4)) (then
              (local.set $ta (ref.cast (ref $tuple) (local.get $a))) (local.set $tb (ref.cast (ref $tuple) (local.get $b)))
              (local.set $na (array.len (local.get $ta))) (local.set $nb (array.len (local.get $tb)))
              (if (i32.ne (local.get $na) (local.get $nb)) (then (return (i32.sub (i32.gt_s (local.get $na) (local.get $nb)) (i32.lt_s (local.get $na) (local.get $nb))))))
              (block $td (loop $tl
                (br_if $td (i32.ge_u (local.get $i) (local.get $na)))
                (local.set $c (call $term_compare (array.get $tuple (local.get $ta) (local.get $i)) (array.get $tuple (local.get $tb) (local.get $i))))
                (if (i32.ne (local.get $c) (i32.const 0)) (then (return (local.get $c))))
                (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $tl)))
              (return (i32.const 0))))
            ;; rank 5: map (kv arrays are key-sorted; compare size, then key/value pairs)
            (if (i32.eq (local.get $ra) (i32.const 5)) (then
              (local.set $ma (call $map_kv (local.get $a))) (local.set $mb (call $map_kv (local.get $b)))
              (local.set $na (array.len (local.get $ma))) (local.set $nb (array.len (local.get $mb)))
              (if (i32.ne (local.get $na) (local.get $nb)) (then (return (i32.sub (i32.gt_s (local.get $na) (local.get $nb)) (i32.lt_s (local.get $na) (local.get $nb))))))
              (local.set $i (i32.const 0))
              (block $md (loop $ml
                (br_if $md (i32.ge_u (local.get $i) (local.get $na)))
                (local.set $c (call $term_compare (array.get $tuple (local.get $ma) (local.get $i)) (array.get $tuple (local.get $mb) (local.get $i))))
                (if (i32.ne (local.get $c) (i32.const 0)) (then (return (local.get $c))))
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (local.set $c (call $term_compare (array.get $tuple (local.get $ma) (local.get $i)) (array.get $tuple (local.get $mb) (local.get $i))))
                (if (i32.ne (local.get $c) (i32.const 0)) (then (return (local.get $c))))
                (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ml)))
              (return (i32.const 0))))
            ;; rank 7: binary (lexicographic, then shorter < longer)
            (if (i32.eq (local.get $ra) (i32.const 7)) (then
              (local.set $xa (struct.get $binary 0 (ref.cast (ref $binary) (local.get $a)))) (local.set $xb (struct.get $binary 0 (ref.cast (ref $binary) (local.get $b))))
              (local.set $na (array.len (local.get $xa))) (local.set $nb (array.len (local.get $xb)))
              (block $xd (loop $xl
                (br_if $xd (i32.ge_u (local.get $i) (local.get $na))) (br_if $xd (i32.ge_u (local.get $i) (local.get $nb)))
                (local.set $c (i32.sub (array.get_u $bytes (local.get $xa) (local.get $i)) (array.get_u $bytes (local.get $xb) (local.get $i))))
                (if (i32.ne (local.get $c) (i32.const 0)) (then (return (i32.sub (i32.gt_s (local.get $c) (i32.const 0)) (i32.lt_s (local.get $c) (i32.const 0))))))
                (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $xl)))
              (return (i32.sub (i32.gt_s (local.get $na) (local.get $nb)) (i32.lt_s (local.get $na) (local.get $nb))))))
            (i32.const 0))\
        """
    }
    # maps:fold/3 needs $clos3 + the $ftab table, so emit it only when the program uses it.
    base =
      if Process.get(:mapsfold) do
        Map.put(base, "$maps.fold_3",
          """
            (func $maps.fold_3 (param $f (ref null eq)) (param $acc (ref null eq)) (param $m (ref null eq)) (result (ref null eq))
              (local $a (ref $tuple)) (local $n i32) (local $i i32)
              (local.set $a (call $map_kv (local.get $m)))
              (local.set $n (array.len (local.get $a)))
              (block $d (loop $lp (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
                (local.set $acc (call_indirect $ftab (type $clos3)
                  (local.get $f)
                  (array.get $tuple (local.get $a) (local.get $i))
                  (array.get $tuple (local.get $a) (i32.add (local.get $i) (i32.const 1)))
                  (local.get $acc)
                  (struct.get $fun 0 (ref.cast (ref $fun) (local.get $f)))))
                (local.set $i (i32.add (local.get $i) (i32.const 2)))
                (br $lp)))
              (local.get $acc))\
          """)
      else
        base
      end
    base =
      # NOTE: float_builtins (a precision-0-only Float.round/ceil/floor shim) was REMOVED — the
      # real Float BEAM code (IEEE bit decomposition over $bitstr values) is fully supported now.
      base
    # Real Req: override ONLY the adapter step. Req.Finch.run(request) -> {request, %Req.Response{}} with
    # the body from the host (the socket). All other Req steps (request build + response decode) run for real.
    if Process.get(:req_override) do
      atom = fn a -> "(global.get $atom_#{sanitize(a)})" end
      emap = "(struct.new $map (ref.null $mnode))"
      put = fn r, k, v -> "(call $map_put #{r} #{atom.(k)} #{v})" end
      # a real response carries a content-type; it makes Req's decode_body take the text path (return the
      # body as-is) instead of sniffing the URL extension — both faithful and avoids extra stdlib surface.
      hdrs = "(call $map_put #{emap} #{bin_literal("content-type")} (struct.new $cons #{bin_literal("text/html; charset=utf-8")} (ref.null none)))"
      resp =
        emap
        |> then(&put.(&1, :__struct__, atom.(Req.Response)))
        |> then(&put.(&1, :status, "(ref.i31 (i32.const 200))"))
        |> then(&put.(&1, :headers, hdrs))
        |> then(&put.(&1, :trailers, emap))
        |> then(&put.(&1, :private, emap))
        |> then(&put.(&1, :body, "(call $host_http_get (local.get $req))"))
      Map.put(base, "$Elixir_46_Req_46_Finch.run_1",
        "  (func $Elixir_46_Req_46_Finch.run_1 (param $req (ref null eq)) (result (ref null eq))\n" <>
        "    (array.new_fixed $tuple 2 (local.get $req) #{resp}))")
    else
      base
    end
  end

  # binary_to_integer/2: bignum-tier (term-level acc via $int_mul/$int_add) vs wrapping-i32 fallback.
  defp b2i_wat(bignum?) do
    {acc_decl, acc_init, acc_step, ret} =
      if bignum? do
        {"(local $acc (ref null eq))",
         "(local.set $acc (ref.i31 (i32.const 0)))",
         "(local.set $acc (call $int_add (call $int_mul (local.get $acc) (local.get $base)) (ref.i31 (local.get $dv))))",
         "(if (result (ref null eq)) (local.get $neg) (then (call $int_sub (ref.i31 (i32.const 0)) (local.get $acc))) (else (local.get $acc)))"}
      else
        {"(local $acc i32)",
         "(local.set $acc (i32.const 0))",
         "(local.set $acc (i32.add (i32.mul (local.get $acc) (local.get $basei)) (local.get $dv)))",
         "(ref.i31 (if (result i32) (local.get $neg) (then (i32.sub (i32.const 0) (local.get $acc))) (else (local.get $acc))))"}
      end

    """
      (func $erlang.binary_to_integer_2 (param $bin (ref null eq)) (param $base (ref null eq)) (result (ref null eq))
        (local $b (ref $bytes)) (local $n i32) (local $i i32) (local $neg i32) (local $c i32) (local $dv i32) (local $basei i32) #{acc_decl}
        (local.set $b (struct.get $binary 0 (ref.cast (ref $binary) (local.get $bin))))
        (local.set $n (array.len (local.get $b)))
        (if (i32.eqz (local.get $n)) (then (unreachable)))
        (local.set $basei (i31.get_s (ref.cast (ref i31) (local.get $base))))
        (if (i32.eq (array.get_u $bytes (local.get $b) (i32.const 0)) (i32.const 45))
          (then (local.set $neg (i32.const 1)) (local.set $i (i32.const 1)))
          (else (if (i32.eq (array.get_u $bytes (local.get $b) (i32.const 0)) (i32.const 43))
            (then (local.set $i (i32.const 1))))))   ;; leading '+' is legal (list_to_integer('+2'))
        (if (i32.ge_u (local.get $i) (local.get $n)) (then (unreachable)))
        #{acc_init}
        (block $done (loop $lp
          (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
          (local.set $c (array.get_u $bytes (local.get $b) (local.get $i)))
          (local.set $dv
            (if (result i32) (i32.and (i32.ge_u (local.get $c) (i32.const 48)) (i32.le_u (local.get $c) (i32.const 57)))
              (then (i32.sub (local.get $c) (i32.const 48)))
              (else (if (result i32) (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))
                (then (i32.sub (local.get $c) (i32.const 55)))
                (else (if (result i32) (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))
                  (then (i32.sub (local.get $c) (i32.const 87)))
                  (else (i32.const 255))))))))
          (if (i32.ge_u (local.get $dv) (local.get $basei)) (then (unreachable)))
          #{acc_step}
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $lp)))
        #{ret})\
    """
  end

  # integer_to_binary/2: count digits, then fill from the end (digits 0-9,A-Z — Erlang uppercase).
  # Bignum-tier digit extraction via $int_rem/$int_div (a digit is always i31); i32 in wrapping mode.
  defp i2b_wat(bignum?) do
    if bignum? do
      """
        (func $erlang.integer_to_binary_2 (param $x (ref null eq)) (param $base (ref null eq)) (result (ref null eq))
          (local $v (ref null eq)) (local $v0 (ref null eq)) (local $neg i32) (local $len i32) (local $d (ref $bytes)) (local $i i32) (local $dv i32)
          (local.set $v (local.get $x))
          (if (i32.lt_s (call $int_cmp (local.get $v) (ref.i31 (i32.const 0))) (i32.const 0))
            (then (local.set $neg (i32.const 1)) (local.set $v (call $int_sub (ref.i31 (i32.const 0)) (local.get $v)))))
          (local.set $v0 (local.get $v))
          (block $c (loop $cl
            (local.set $len (i32.add (local.get $len) (i32.const 1)))
            (local.set $v (call $int_div (local.get $v) (local.get $base)))
            (br_if $c (i32.eqz (call $int_cmp (local.get $v) (ref.i31 (i32.const 0)))))
            (br $cl)))
          (local.set $len (i32.add (local.get $len) (local.get $neg)))
          (local.set $d (array.new_default $bytes (local.get $len)))
          (if (local.get $neg) (then (array.set $bytes (local.get $d) (i32.const 0) (i32.const 45))))
          (local.set $i (i32.sub (local.get $len) (i32.const 1)))
          (local.set $v (local.get $v0))
          (block $f (loop $fl
            (local.set $dv (i31.get_s (ref.cast (ref i31) (call $int_rem (local.get $v) (local.get $base)))))
            (array.set $bytes (local.get $d) (local.get $i)
              (if (result i32) (i32.lt_u (local.get $dv) (i32.const 10)) (then (i32.add (i32.const 48) (local.get $dv))) (else (i32.add (i32.const 55) (local.get $dv)))))
            (local.set $v (call $int_div (local.get $v) (local.get $base)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br_if $f (i32.eqz (call $int_cmp (local.get $v) (ref.i31 (i32.const 0)))))
            (br $fl)))
          (struct.new $binary (local.get $d)))\
      """
    else
      """
        (func $erlang.integer_to_binary_2 (param $x (ref null eq)) (param $base (ref null eq)) (result (ref null eq))
          (local $n i32) (local $basei i32) (local $neg i32) (local $len i32) (local $t i32) (local $d (ref $bytes)) (local $i i32) (local $dv i32)
          (local.set $n (i31.get_s (ref.cast (ref i31) (local.get $x))))
          (local.set $basei (i31.get_s (ref.cast (ref i31) (local.get $base))))
          (if (i32.lt_s (local.get $n) (i32.const 0))
            (then (local.set $neg (i32.const 1)) (local.set $n (i32.sub (i32.const 0) (local.get $n)))))
          (local.set $t (local.get $n)) (local.set $len (i32.const 0))
          (block $c (loop $cl
            (local.set $len (i32.add (local.get $len) (i32.const 1)))
            (local.set $t (i32.div_u (local.get $t) (local.get $basei)))
            (br_if $c (i32.eqz (local.get $t))) (br $cl)))
          (local.set $len (i32.add (local.get $len) (local.get $neg)))
          (local.set $d (array.new_default $bytes (local.get $len)))
          (if (local.get $neg) (then (array.set $bytes (local.get $d) (i32.const 0) (i32.const 45))))
          (local.set $i (i32.sub (local.get $len) (i32.const 1)))
          (block $f (loop $fl
            (local.set $dv (i32.rem_u (local.get $n) (local.get $basei)))
            (array.set $bytes (local.get $d) (local.get $i)
              (if (result i32) (i32.lt_u (local.get $dv) (i32.const 10)) (then (i32.add (i32.const 48) (local.get $dv))) (else (i32.add (i32.const 55) (local.get $dv)))))
            (local.set $n (i32.div_u (local.get $n) (local.get $basei)))
            (local.set $i (i32.sub (local.get $i) (i32.const 1)))
            (br_if $f (i32.eqz (local.get $n))) (br $fl)))
          (struct.new $binary (local.get $d)))\
      """
    end
  end

  defp term_i64_wat(bignum?) do
    if bignum? do
      """
        (func $term_i64 (param $x (ref null eq)) (result i64)
          (if (ref.test (ref i31) (local.get $x)) (then (return (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $x)))))))
          (if (ref.test (ref $i64) (local.get $x)) (then (return (struct.get $i64 0 (ref.cast (ref $i64) (local.get $x))))))
          (call $bigint_to_i64 (struct.get $big 0 (ref.cast (ref $big) (local.get $x)))))\
      """
    else
      """
        (func $term_i64 (param $x (ref null eq)) (result i64)
          (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $x)))))\
      """
    end
  end

  # :unicode.characters_to_<form>_binary/1 — host normalize when detected, honest trap otherwise.
  defp uninorm_wat(form) do
    name = "$unicode.characters_to_#{form}_binary_1"
    if Process.get(:uninorm) do
      """
        (func #{name} (param $s (ref null eq)) (result (ref null eq))
          (return_call $host_#{form} (local.get $s)))\
      """
    else
      "  (func #{name} (param $s (ref null eq)) (result (ref null eq)) (unreachable))"
    end
  end

  # WAT for an error-raising BIF, gated on the runtime mode (mirrors $erlang.raise_3):
  # exc -> (throw $exc class reason null-trace); proc-only -> exit_raw(reason); else -> trap.
  # `class_global` is "$atom_error" / "$atom_throw" (forced atoms whenever exc mode is on).
  defp error_bif(name, params, class_global, reason_expr) do
    cond do
      Process.get(:exc) ->
        """
          (func $erlang.#{name} #{params} (result (ref null eq))
            (throw $exc (global.get #{class_global}) #{reason_expr} (ref.null none)))\
        """

      Process.get(:proc) ->
        """
          (func $erlang.#{name} #{params} (result (ref null eq))
            (call $exit_raw #{reason_expr})
            (unreachable))\
        """

      true ->
        """
          (func $erlang.#{name} #{params} (result (ref null eq))
            (unreachable))\
        """
    end
  end
end
