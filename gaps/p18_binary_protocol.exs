# extra: Bitwise Enum Map List
# A binary-protocol codec: synthesize message records from a seed, BUILD them as binaries with the
# bitstring syntax (fixed-width fields, big/little-endian multi-byte ints, length-prefixed blobs,
# packed flag bits), then PARSE them back with binary pattern matching and verify round-trip. Also a
# CRC-ish rolling checksum over bytes and a small TLV pack/unpack. Every derived value folds into a
# rolling checksum so any miscompiled bitstring/binary op changes Gap18.run(seed). Pure & deterministic.
defmodule Gap18 do
  import Bitwise
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @magic 0xCAFE

  def run(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    {recs, s1} = gen_records(10 + rem(abs(seed), 8), s0, [])
    h = 14_695_981
    h = mix(h, length(recs))

    # Build each record into a binary message, parse it back, verify round-trip equality.
    {h, frames} =
      Enum.reduce(recs, {h, []}, fn rec, {a, fs} ->
        bin = build(rec)
        a = a |> mix(byte_size(bin)) |> mix(bin)
        parsed = parse(bin)
        a = mix(a, if(parsed == rec, do: 1, else: 0))
        a = fold_map(a, rec)
        {a, [bin | fs]}
      end)

    frames = Enum.reverse(frames)

    # CRC-ish over the concatenation of all frames.
    blob = Enum.reduce(frames, <<>>, fn b, acc -> acc <> b end)
    h = h |> mix(byte_size(blob)) |> mix(crc16(blob)) |> mix(crc32ish(blob))

    # Bit-level packing: pack a list of small ints into a tight bitstream, read it back.
    nums = Enum.map(recs, fn r -> rem(r.id * 7 + r.kind, 1024) end)
    packed = pack_bits(nums, <<>>)
    h = mix(h, byte_size(packed))
    unpacked = unpack_bits(packed, length(nums), [])
    h = mix(h, if(unpacked == nums, do: 17, else: 0))
    h = fold_list(h, unpacked)

    # Endianness contrast: same value, big vs little; bytes differ but reparse agrees.
    h =
      Enum.reduce(recs, h, fn r, a ->
        v = rem(r.id * 1000 + r.len, 0x7FFFFFFF)
        be = <<v::big-32>>
        le = <<v::little-32>>
        <<vb::big-32>> = be
        <<vl::little-32>> = le
        a |> mix(be) |> mix(le) |> mix(vb) |> mix(vl) |> mix(vb == vl && vb == v && 1 || 0)
      end)

    # TLV: encode (type, value-bytes) tuples, decode back, verify.
    tlvs = Enum.map(recs, fn r -> {rem(r.kind, 8), seed_bytes(r.id, rem(r.len, 6) + 1)} end)
    tlv_bin = encode_tlv(tlvs, <<>>)
    h = h |> mix(byte_size(tlv_bin)) |> mix(tlv_bin)
    decoded = decode_tlv(tlv_bin, [])
    h = mix(h, if(decoded == tlvs, do: 31, else: 0))

    h =
      Enum.reduce(decoded, h, fn {t, v}, a ->
        a |> mix(t) |> mix(byte_size(v)) |> mix(v)
      end)

    # Nibble split / byte reassembly round-trip.
    h =
      Enum.reduce(0..40, h, fn n, a ->
        byte = rem(n * 37 + 11, 256)
        <<hi::4, lo::4>> = <<byte>>
        <<reb::8>> = <<hi::4, lo::4>>
        a |> mix(hi) |> mix(lo) |> mix(reb) |> mix(reb == byte && 1 || 0)
      end)

    # Binary slicing with binary_part + part-wise XOR fold.
    h =
      Enum.reduce(frames, h, fn b, a ->
        n = byte_size(b)
        head = binary_part(b, 0, min(4, n))
        tail = binary_part(b, n - min(4, n), min(4, n))
        a |> mix(head) |> mix(tail) |> mix(xor_bytes(b, 0))
      end)

    h |> mix(s1) |> mix(@magic)
  end

  # ---- record model ----
  defp gen_records(0, s, acc), do: {Enum.reverse(acc), s}

  defp gen_records(n, s, acc) do
    {id, s1} = rng(s, 60000)
    {kind, s2} = rng(s1, 16)
    {len, s3} = rng(s2, 12)
    {flagbits, s4} = rng(s3, 256)
    {payv, s5} = rng(s4, 0x7FFFFFFF)
    payload = seed_bytes(id + len, len + 1)
    rec = %{id: id, kind: kind, len: len, flags: flagbits, payv: payv, payload: payload}
    gen_records(n - 1, s5, [rec | acc])
  end

  # Deterministic byte blob of length k derived from a seed value.
  defp seed_bytes(seed, k), do: seed_bytes(seed, k, <<>>)
  defp seed_bytes(_seed, 0, acc), do: acc

  defp seed_bytes(seed, k, acc) do
    b = rem(seed * 131 + k * 17 + 7, 256)
    seed_bytes(seed + 1, k - 1, acc <> <<b>>)
  end

  # ---- frame build / parse ----
  # Layout: magic:16/big, kind:8, flags:8, id:16/little, payv:32/big, len:8, payload:len bytes, trailer:16/big
  defp build(%{id: id, kind: kind, len: len, flags: flags, payv: payv, payload: payload}) do
    trailer = rem(id + kind + len + flags, 0xFFFF)

    <<@magic::big-16, kind::8, flags::8, id::little-16, payv::big-32, byte_size(payload)::8,
      payload::binary, trailer::big-16>>
  end

  defp parse(<<@magic::big-16, kind::8, flags::8, id::little-16, payv::big-32, plen::8, rest::binary>>) do
    <<payload::binary-size(plen), _trailer::big-16>> = rest
    %{id: id, kind: kind, len: byte_size(payload), flags: flags, payv: payv, payload: payload}
  end

  # ---- bit packing: each value as 10 bits ----
  defp pack_bits([], acc) do
    # pad to byte boundary
    rem_bits = rem(bit_size(acc), 8)
    if rem_bits == 0, do: acc, else: <<acc::bitstring, 0::size(8 - rem_bits)>>
  end

  defp pack_bits([v | rest], acc), do: pack_bits(rest, <<acc::bitstring, v::10>>)

  defp unpack_bits(_bin, 0, acc), do: Enum.reverse(acc)

  defp unpack_bits(bin, n, acc) do
    <<v::10, rest::bitstring>> = bin
    unpack_bits(rest, n - 1, [v | acc])
  end

  # ---- TLV: type:8, length:8, value:length bytes ----
  defp encode_tlv([], acc), do: acc

  defp encode_tlv([{t, v} | rest], acc),
    do: encode_tlv(rest, <<acc::binary, t::8, byte_size(v)::8, v::binary>>)

  defp decode_tlv(<<>>, acc), do: Enum.reverse(acc)

  defp decode_tlv(<<t::8, len::8, rest::binary>>, acc) do
    <<v::binary-size(len), more::binary>> = rest
    decode_tlv(more, [{t, v} | acc])
  end

  # ---- checksums over bytes ----
  defp crc16(bin), do: crc16(bin, 0xFFFF)
  defp crc16(<<>>, acc), do: acc

  defp crc16(<<b, rest::binary>>, acc) do
    acc = bxor(acc, b)
    acc = crc16_round(acc, 8)
    crc16(rest, acc)
  end

  defp crc16_round(acc, 0), do: band(acc, 0xFFFF)

  defp crc16_round(acc, k) do
    acc =
      if band(acc, 1) == 1 do
        bxor(bsr(acc, 1), 0xA001)
      else
        bsr(acc, 1)
      end

    crc16_round(acc, k - 1)
  end

  defp crc32ish(bin), do: crc32ish(bin, 0x811C9DC5)
  defp crc32ish(<<>>, acc), do: band(acc, 0xFFFFFFFF)

  defp crc32ish(<<b, rest::binary>>, acc) do
    acc = band(bxor(acc, b) * 0x01000193, 0xFFFFFFFF)
    crc32ish(rest, acc)
  end

  defp xor_bytes(<<>>, acc), do: acc
  defp xor_bytes(<<b, rest::binary>>, acc), do: xor_bytes(rest, bxor(acc, b))

  # ---- shared checksum kit (identical across the gap corpus) ----
  defp rng(s, m), do: {rem(div(s, 65_536), max(m, 1)), nxt(s)}
  defp nxt(s), do: rem(s * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407, @lcg)
  defp mix(h, x), do: rem(h * 1_000_003 + intify(x) + 1, @cmod)
  defp fold_list(h, l), do: Enum.reduce(l, h, fn e, a -> mix(a, e) end)
  defp fold_map(h, m), do: Enum.reduce(Enum.sort(Map.to_list(m)), h, fn {k, v}, a -> a |> mix(k) |> mix(v) end)
  defp intify(x) when is_integer(x), do: rem(abs(x), @cmod)
  defp intify(x) when is_float(x), do: trunc(x * 1_000_000)
  defp intify(x) when is_binary(x), do: bsum(x, 7)
  defp intify(true), do: 2
  defp intify(false), do: 3
  defp intify(nil), do: 5
  defp intify(x) when is_atom(x), do: bsum(Atom.to_string(x), 11)
  defp intify(x) when is_list(x), do: Enum.reduce(x, 13, fn e, a -> mix(a, intify(e)) end)
  defp intify(x) when is_tuple(x), do: intify(Tuple.to_list(x))
  defp bsum(<<>>, a), do: a
  defp bsum(<<c, r::binary>>, a), do: bsum(r, rem(a * 131 + c, @cmod))
end
