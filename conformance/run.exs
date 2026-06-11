#!/usr/bin/env elixir
# Differential conformance harness: for each corpus entry, compile the Elixir module to
# WasmGC (via ../compiler/beam2wasm.exs), run every case on Wasm AND on the real Elixir VM
# in-process, and diff bit-exact. Prints a category coverage matrix + overall %.
#
#   elixir run.exs            # whole corpus
#   elixir run.exs binaries   # only categories matching the filter
#
# Arg/result types bridged: int | bool | atom | bin(string) | list(of ints).

Code.require_file("../tooling.exs", __DIR__)

defmodule Conf do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../compiler/beam2wasm.exs")
  @driver Path.join(@here, "driver.mjs")
  @runproc Path.join(@here, "../runtime/scheduler.mjs")
  @tmp Path.join(@here, "_work")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()

  # ---- corpus ----
  # %{cat, mod_src, extra: [Module,...], cases: [%{fn, sig: {[argtype], rettype}, inputs: [[..],..]}]}
  def corpus do
    [
      %{cat: "arith", src: """
        defmodule CArith do
          def gcd(a, 0), do: a
          def gcd(a, b), do: gcd(b, rem(a, b))
          def sumto(0), do: 0
          def sumto(n), do: n + sumto(n - 1)
          def pow(_b, 0), do: 1
          def pow(b, e), do: b * pow(b, e - 1)
          def bits(a, b), do: a * 1000 + Bitwise.band(a, b) + Bitwise.bxor(a, b)
        end
        """, extra: [], cases: [
          %{fn: "gcd", sig: {[:int, :int], :int}, inputs: [[48, 36], [17, 5], [100, 25]]},
          %{fn: "sumto", sig: {[:int], :int}, inputs: [[10], [100], [0]]},
          %{fn: "pow", sig: {[:int, :int], :int}, inputs: [[2, 10], [3, 5], [7, 0]]},
          %{fn: "bits", sig: {[:int, :int], :int}, inputs: [[12, 10], [255, 128]]}
        ]},
      %{cat: "recursion", src: """
        defmodule CRec do
          def fib(0), do: 0
          def fib(1), do: 1
          def fib(n), do: fib(n - 1) + fib(n - 2)
          def fact(0), do: 1
          def fact(n), do: n * fact(n - 1)
          def ack(0, n), do: n + 1
          def ack(m, 0), do: ack(m - 1, 1)
          def ack(m, n), do: ack(m - 1, ack(m, n - 1))
        end
        """, extra: [], cases: [
          %{fn: "fib", sig: {[:int], :int}, inputs: [[10], [20], [25]]},
          %{fn: "fact", sig: {[:int], :int}, inputs: [[10], [11], [12]]},   # exact within i31; 13!+ -> bignum cat
          %{fn: "ack", sig: {[:int, :int], :int}, inputs: [[2, 3], [3, 3]]}
        ]},
      # ---- EXACT ARBITRARY-PRECISION INTEGERS (BIGNUM=1: i31 fast path, host BigInt on overflow) ----
      # Proves both exact bignum arithmetic AND tiered comparison (>, >=, ==) on boxed bignums.
      %{cat: "bignum", bignum: true, src: """
        defmodule CBig do
          def fact(0), do: 1
          def fact(n), do: n * fact(n - 1)
          def f(n), do: fact(n)
          def gt(n), do: if(fact(n) > fact(n - 1), do: 1, else: 0)       # ordering on huge values
          def eq(n), do: if(fact(n) == fact(n), do: 1, else: 0)          # equality on two distinct boxes
          def ge(n), do: if(fact(n - 1) >= fact(n), do: 1, else: 0)      # false for n>1 (fact grows)
        end
        """, extra: [], cases: [
          # f(13)=6.2e9 (>i31), f(20)=2.4e18 (within i64), f(25) (true BigInt > i64), f(50)
          %{fn: "f", sig: {[:int], :int}, inputs: [[12], [13], [20], [25], [50]]},
          %{fn: "gt", sig: {[:int], :int}, inputs: [[13], [25]]},
          %{fn: "eq", sig: {[:int], :int}, inputs: [[13], [25]]},
          %{fn: "ge", sig: {[:int], :int}, inputs: [[2], [13]]}
        ]},
      %{cat: "lists", src: """
        defmodule CList do
          def rev(l), do: rev(l, [])
          def rev([], acc), do: acc
          def rev([h | t], acc), do: rev(t, [h | acc])
          def dbl([]), do: []
          def dbl([h | t]), do: [h * 2 | dbl(t)]
          def sum([]), do: 0
          def sum([h | t]), do: h + sum(t)
          def evens([]), do: []
          def evens([h | t]) when rem(h, 2) == 0, do: [h | evens(t)]
          def evens([_ | t]), do: evens(t)
          def len([]), do: 0
          def len([_ | t]), do: 1 + len(t)
        end
        """, extra: [], cases: [
          %{fn: "rev", sig: {[:list], :list}, inputs: [[[1, 2, 3, 4]], [[]], [[9]]]},
          %{fn: "dbl", sig: {[:list], :list}, inputs: [[[1, 2, 3]], [[0, 5, 10]]]},
          %{fn: "sum", sig: {[:list], :int}, inputs: [[[1, 2, 3, 4, 5]], [[]]]},
          %{fn: "evens", sig: {[:list], :list}, inputs: [[[1, 2, 3, 4, 5, 6]], [[1, 3, 5]]]},
          %{fn: "len", sig: {[:list], :int}, inputs: [[[1, 2, 3]], [[]]]}
        ]},
      %{cat: "tuples", src: """
        defmodule CTup do
          def sum3(a, b, c), do: (t = {a, b, c}; elem(t, 0) + elem(t, 1) + elem(t, 2))
          def swapsum(a, b), do: (t = {b, a}; elem(t, 0) * 10 + elem(t, 1))
        end
        """, extra: [], cases: [
          %{fn: "sum3", sig: {[:int, :int, :int], :int}, inputs: [[1, 2, 3], [10, 20, 30]]},
          %{fn: "swapsum", sig: {[:int, :int], :int}, inputs: [[3, 7], [1, 9]]}
        ]},
      %{cat: "maps", src: """
        defmodule CMap do
          def step(x), do: (m = %{bal: x, st: :open}; m2 = %{m | bal: m.bal + 5}; m2.bal)
          def get2(x), do: (m = %{a: x, b: x + 1}; m.a + m.b)
        end
        """, extra: [], cases: [
          %{fn: "step", sig: {[:int], :int}, inputs: [[100], [0]]},
          %{fn: "get2", sig: {[:int], :int}, inputs: [[5], [41]]}
        ]},
      %{cat: "binaries", src: """
        defmodule CBin do
          def greet(name), do: "Hi, " <> name <> "!"
          def sz(b), do: byte_size(b)
          def cnt(<<c, rest::binary>>, c, acc), do: cnt(rest, c, acc + 1)
          def cnt(<<_, rest::binary>>, c, acc), do: cnt(rest, c, acc)
          def cnt(<<>>, _c, acc), do: acc
          def upc(<<c, rest::binary>>) when c >= ?a and c <= ?z, do: <<c - 32>> <> upc(rest)
          def upc(<<c, rest::binary>>), do: <<c>> <> upc(rest)
          def upc(<<>>), do: ""
        end
        """, extra: [], cases: [
          %{fn: "greet", sig: {[:bin], :bin}, inputs: [["world"], [""]]},
          %{fn: "sz", sig: {[:bin], :int}, inputs: [["hello"], ["héllo"]]},
          %{fn: "upc", sig: {[:bin], :bin}, inputs: [["Hello, World!"], ["abc 123"]]}
        ]},
      # ── TRMC: list-building body recursion at depths that OVERFLOWED before the transform
      # (the cliff was ~10^4 frames; these run at 10^5-10^6 and must stay bit-exact vs the VM,
      # including construction order — TRMC builds head-first iteratively, recursion built
      # tail-first, and the results must be indistinguishable).
      %{cat: "deep-lists", extra: [Enum, Enumerable, Enumerable.List, :lists], src: """
        defmodule CDeep do
          def mk(0), do: []
          def mk(n), do: [n | mk(n - 1)]
          def build_sum(n), do: mk(n) |> Enum.sum()
          def map_sum(n), do: mk(n) |> Enum.map(fn x -> x * 2 + 1 end) |> Enum.sum()
          def chain(n), do: mk(n) |> Enum.filter(fn x -> rem(x, 2) == 0 end) |> Enum.map(fn x -> x * 3 end) |> Enum.sum()
          def order(n), do: mk(n) |> Enum.map(fn x -> x + 1 end) |> Enum.take(3) |> Enum.reduce(0, fn x, a -> a * 1_000_003 + x end)
          def deep_lists_map(n), do: :lists.map(fn x -> x + 7 end, mk(n)) |> Enum.sum()
        end
        """, cases: [
          %{fn: "build_sum", sig: {[:int], :int}, inputs: [[1_000_000]]},
          %{fn: "map_sum", sig: {[:int], :int}, inputs: [[200_000]]},
          %{fn: "chain", sig: {[:int], :int}, inputs: [[100_000]]},
          %{fn: "order", sig: {[:int], :int}, inputs: [[100_000]]},
          %{fn: "deep_lists_map", sig: {[:int], :int}, inputs: [[300_000]]}
        ]},
      # binary:split full surface: list-of-binaries patterns (leftmost, longest at equal pos),
      # :trim / :trim_all, and String.split/1 whitespace (which is exactly that via String.Break).
      %{cat: "bin-split", extra: [Enum, String, String.Break, :lists], src: """
        defmodule CSplit do
          def multi(s), do: :binary.split(s, ["--", ","], [:global]) |> Enum.join("|")
          def once(s), do: :binary.split(s, [",", ";"]) |> Enum.join("|")
          def longest(s), do: :binary.split(s, ["ab", "abc"], [:global]) |> Enum.join("|")
          def trim(s), do: :binary.split(s, " ", [:global, :trim]) |> Enum.join("|")
          def trim_all(s), do: :binary.split(s, " ", [:global, :trim_all]) |> Enum.join("|")
          def ws(s), do: String.split(s) |> Enum.join("|")
        end
        """, cases: [
          %{fn: "multi", sig: {[:bin], :bin}, inputs: [["a--b,c--d"], ["x"], [",--"]]},
          %{fn: "once", sig: {[:bin], :bin}, inputs: [["a;b,c"], ["abc"]]},
          %{fn: "longest", sig: {[:bin], :bin}, inputs: [["xxabcyy"], ["zabz"]]},
          %{fn: "trim", sig: {[:bin], :bin}, inputs: [["a b  c   "], ["   "]]},
          %{fn: "trim_all", sig: {[:bin], :bin}, inputs: [["  a  b "], [""]]},
          %{fn: "ws", sig: {[:bin], :bin}, inputs: [["  hello   world "], ["one two  three"]]}
        ]},
      # float printing: Erlang :short picks the SHORTER of plain/scientific (plain on ties) and
      # never prints plain at/above 2^53. The old shim rule ("plain iff dp >= -3") survived every
      # suite here yet mis-rendered 2.07e-4 as 0.000207 — found by the rebalancer's structured
      # megafuzz, then pinned by these exact boundary values (and a 1M random-bit-pattern fuzz).
      %{cat: "float-format", extra: [Float, String], src: """
        defmodule CFltFmt do
          def fmt(s), do: Float.to_string(String.to_float(s))
        end
        """, cases: [
          %{fn: "fmt", sig: {[:bin], :bin}, inputs: [
            ["0.000207"], ["0.0001"], ["0.00049"], ["0.00123"], ["0.000999"], ["0.00003"],
            ["9007199254740991.0"], ["9007199254740992.0"], ["1.0e15"], ["123456789012345.0"],
            ["12345678901234567.0"], ["1.0e21"], ["-0.00025"], ["100.0"], ["1000.0"], ["0.1"]
          ]}
        ]},
      %{cat: "closures", src: """
        defmodule CClos do
          def map([], _f), do: []
          def map([h | t], f), do: [f.(h) | map(t, f)]
          def reduce([], acc, _f), do: acc
          def reduce([h | t], acc, f), do: reduce(t, f.(acc, h), f)
          def dbl(l), do: map(l, fn x -> x * 2 end)
          def total(l), do: reduce(l, 0, fn a, b -> a + b end)
          def add_n(l, n), do: map(l, fn x -> x + n end)
        end
        """, extra: [], cases: [
          %{fn: "dbl", sig: {[:list], :list}, inputs: [[[1, 2, 3]], [[]]]},
          %{fn: "total", sig: {[:list], :int}, inputs: [[[1, 2, 3, 4]], [[10, 20]]]},
          %{fn: "add_n", sig: {[:list, :int], :list}, inputs: [[[1, 2, 3], 10], [[5], 100]]}
        ]},
      %{cat: "real-enum", src: """
        defmodule CEnum do
          def sumsq_evens(l), do: l |> Enum.filter(fn x -> rem(x, 2) == 0 end) |> Enum.map(fn x -> x * x end) |> Enum.reduce(0, fn x, a -> x + a end)
          def cnt(l), do: Enum.count(l)
          def rev(l), do: Enum.reverse(l)
          def mapsum(l), do: l |> Enum.map(fn x -> x + 1 end) |> Enum.sum()
          def anybig(l), do: Enum.any?(l, fn x -> x > 100 end)
        end
        """, extra: [Enum], cases: [
          %{fn: "sumsq_evens", sig: {[:list], :int}, inputs: [[[3, 1, 4, 1, 5, 9, 2, 6]], [[2, 4, 6]]]},
          %{fn: "cnt", sig: {[:list], :int}, inputs: [[[1, 2, 3, 4, 5]], [[]]]},
          %{fn: "rev", sig: {[:list], :list}, inputs: [[[1, 2, 3, 4]], [[9]]]},
          %{fn: "mapsum", sig: {[:list], :int}, inputs: [[[1, 2, 3]], [[10, 20]]]},
          %{fn: "anybig", sig: {[:list], :bool}, inputs: [[[1, 2, 200]], [[1, 2, 3]]]}
        ]},
      # ---- FRONTIER: probes likely to expose gaps (protocols / exceptions / float / BIFs) ----
      %{cat: "enum-more", src: """
        defmodule CEnum2 do
          def emax(l), do: Enum.max(l)
          def emin(l), do: Enum.min(l)
          def esort(l), do: Enum.sort(l)
          def etake(l), do: Enum.take(l, 3)
          def euniq(l), do: Enum.uniq(l)
          def emember(l), do: Enum.member?(l, 3)
          def ewi(l), do: l |> Enum.with_index() |> Enum.map(fn {x, i} -> x + i end)
          def ededup(l), do: Enum.dedup(l)
        end
        """, extra: [Enum, :lists], cases: [
          %{fn: "emax", sig: {[:list], :int}, inputs: [[[3, 1, 4, 1, 5]], [[-2, -9, -1]]]},
          %{fn: "emin", sig: {[:list], :int}, inputs: [[[3, 1, 4, 1, 5]], [[-2, -9, -1]]]},
          %{fn: "esort", sig: {[:list], :list}, inputs: [[[3, 1, 4, 1, 5]], [[5, 4, 3, 2, 1]], [[-3, 10, -7, 0, 2]]]},
          %{fn: "etake", sig: {[:list], :list}, inputs: [[[1, 2, 3, 4, 5]]]},
          %{fn: "euniq", sig: {[:list], :list}, inputs: [[[1, 1, 2, 3, 3]]]},
          %{fn: "emember", sig: {[:list], :bool}, inputs: [[[1, 2, 3]], [[5, 6]]]},
          %{fn: "ewi", sig: {[:list], :list}, inputs: [[[10, 20, 30]]]},
          %{fn: "ededup", sig: {[:list], :list}, inputs: [[[1, 1, 2, 2, 1]]]}
        ]},
      %{cat: "negatives", src: """
        defmodule CNeg do
          def absdiff(a, b), do: abs(a - b)
          def signsum(l), do: signsum(l, 0)
          def signsum([], acc), do: acc
          def signsum([h | t], acc), do: signsum(t, acc - h)
          def mn(a, b), do: min(a, b)
          def mx(a, b), do: max(a, b)
        end
        """, extra: [], cases: [
          %{fn: "absdiff", sig: {[:int, :int], :int}, inputs: [[3, 7], [10, 2]]},
          %{fn: "signsum", sig: {[:list], :int}, inputs: [[[1, 2, 3]]]},
          %{fn: "mn", sig: {[:int, :int], :int}, inputs: [[3, 7], [-2, -5]]},
          %{fn: "mx", sig: {[:int, :int], :int}, inputs: [[3, 7], [-2, -5]]}
        ]},
      # ---- EXCEPTIONS: try/catch/raise lowered onto Wasm exception handling ----
      %{cat: "exceptions", src: """
        defmodule CExc do
          def ct(x) do
            try do
              if x > 0, do: throw(x * 10), else: x
            catch
              v -> v + 1
            end
          end
          def cclass(x) do
            try do
              cond do
                x == 1 -> throw(7)
                x == 2 -> :erlang.error(9)
                true -> 0
              end
            catch
              :throw, v -> 1000 + v
              :error, v -> 2000 + v
            end
          end
          def nested(x) do
            try do
              try do
                throw(x)
              catch
                :error, _ -> 1
              end
            catch
              :throw, v -> v * 2
            end
          end
        end
        """, extra: [], cases: [
          %{fn: "ct", sig: {[:int], :int}, inputs: [[-3], [0], [1], [5]]},
          %{fn: "cclass", sig: {[:int], :int}, inputs: [[0], [1], [2], [5]]},
          %{fn: "nested", sig: {[:int], :int}, inputs: [[-3], [0], [4]]}
        ]},
      %{cat: "string-mod", src: """
        defmodule CStr do
          def up(s), do: String.upcase(s)
          def ln(s), do: String.length(s)
          def rev(s), do: String.reverse(s)
        end
        """, extra: [String], cases: [
          %{fn: "up", sig: {[:bin], :bin}, inputs: [["hello"]]},
          %{fn: "ln", sig: {[:bin], :int}, inputs: [["hello"]]},
          %{fn: "rev", sig: {[:bin], :bin}, inputs: [["abc"]]}
        ]},
      # ---- BINARY STRING HEADS: BEAM lowers shared string literals into non-byte-aligned bs_match chunks ----
      %{cat: "bin-heads", src: """
        defmodule CBinHeads do
          def sku("SKU-BOOK"), do: 1499
          def sku("SKU-USB-C"), do: 899
          def sku("SKU-KEYBOARD"), do: 12900
          def sku("SKU-MONITOR"), do: 34900
          def sku("SKU-GPU"), do: 129900
          def sku("SKU-HOODIE"), do: 5900
          def sku("SKU-STICKER"), do: 199
          def sku(_), do: -1

          def route("GET /v1/orders"), do: 101
          def route("GET /v1/orders/active"), do: 102
          def route("POST /v1/orders"), do: 201
          def route("PATCH /v1/orders"), do: 301
          def route("DELETE /v1/orders"), do: 401
          def route(_), do: 0

          def combo(s, r), do: sku(s) * 1000 + route(r)
        end
        """, extra: [], cases: [
          %{fn: "sku", sig: {[:bin], :int}, inputs: [["SKU-BOOK"], ["SKU-GPU"], ["SKU-MONITOR"], ["SKU-UNKNOWN"], ["SKU-BOOKS"], ["SKU-BOO"]]},
          %{fn: "route", sig: {[:bin], :int}, inputs: [["GET /v1/orders"], ["GET /v1/orders/active"], ["POST /v1/orders"], ["PATCH /v1/orders"], ["DELETE /v1/orders"], ["GET /v1/order"]]},
          %{fn: "combo", sig: {[:bin, :bin], :int}, inputs: [["SKU-BOOK", "GET /v1/orders"], ["SKU-GPU", "POST /v1/orders"], ["SKU-UNKNOWN", "DELETE /v1/orders"]]}
        ]},
      # ---- RAISE: real `raise`/`rescue` with real exception STRUCTS + erlang error/throw classes ----
      %{cat: "raise", proc: true, extra: [Kernel, Exception, ArgumentError, RuntimeError, Enum, Map, Keyword, :lists, :maps], src: """
        defmodule RaiseDemo do
          def rescue_arg(x) do
            try do
              if x > 0, do: raise(ArgumentError, "bad arg"), else: x
            rescue
              e in ArgumentError -> byte_size(e.message) + 100
            end
          end
          def rescue_runtime(x) do
            try do
              raise "boom-" <> :erlang.integer_to_binary(x)
            rescue
              e in RuntimeError -> byte_size(e.message)
            end
          end
          def erlang_error(x) do
            try do
              :erlang.error({:badthing, x})
            catch
              :error, {:badthing, v} -> v * 2
            end
          end
          def throw_catch(x) do
            try do
              throw {:ball, x}
            catch
              {:ball, v} -> v + 7
            end
          end
          def struct_bang(x) do
            e = Kernel.struct!(%ArgumentError{}, message: "zz")
            byte_size(e.message) + x
          end
        end
        """, cases: [
          %{fn: "rescue_arg", sig: {[:int], :int}, inputs: [[7], [0]]},
          %{fn: "rescue_runtime", sig: {[:int], :int}, inputs: [[12]]},
          %{fn: "erlang_error", sig: {[:int], :int}, inputs: [[21]]},
          %{fn: "throw_catch", sig: {[:int], :int}, inputs: [[5]]},
          %{fn: "struct_bang", sig: {[:int], :int}, inputs: [[10]]}
        ]},
      # ---- TERM PRIMITIVES: cmp_term, base-N int<->text (bignum-safe), make_ref ----
      %{cat: "term-prims", extra: [Enum, :lists], src: """
        defmodule TermPrims do
          def cmp(_x) do
            :erts_internal.cmp_term(1, :a) + :erts_internal.cmp_term(:a, :a) * 10 +
              :erts_internal.cmp_term({2}, [1]) * 100
          end
          def i2b(x) do
            a = :erlang.integer_to_binary(x, 16)
            b = :erlang.integer_to_binary(99_999_999_999_999_999_999)
            c = :erlang.integer_to_binary(-x)
            byte_size(a) + byte_size(b) * 10 + byte_size(c) * 100
          end
          def i2l(x), do: length(:erlang.integer_to_list(x, 2))
          def l2i(_x), do: :erlang.list_to_integer(~c"-12345") + :erlang.list_to_integer(~c"ff", 16)
          def mkref(_x), do: (if is_reference(make_ref()), do: 1, else: 0)
        end
        """, cases: [
          %{fn: "cmp", sig: {[:int], :int}, inputs: [[0]]},
          %{fn: "i2b", sig: {[:int], :int}, inputs: [[255], [4095]]},
          %{fn: "i2l", sig: {[:int], :int}, inputs: [[7], [1024]]},
          %{fn: "l2i", sig: {[:int], :int}, inputs: [[0]]},
          %{fn: "mkref", sig: {[:int], :int}, inputs: [[0]]}
        ]},
      # ---- REGEX: the full host-shimmed surface (run/scan/match?/escape/split/replace/compile!) ----
      %{cat: "regex", extra: [Enum, :lists], src: """
        defmodule RegexDemo do
          def match_q(_), do: (if Regex.match?(~r/\\d+/, "ab12"), do: 1, else: 0) + (if Regex.match?(~r/zz/, "ab"), do: 10, else: 20)
          def scan(_), do: Regex.scan(~r/(\\w)(\\d)/, "a1 b2 c3") |> Enum.map(&Enum.join(&1, ",")) |> Enum.join(";")
          def escape(_), do: Regex.escape("a.b*c?(d)[e]|f#g-h i")
          def split2(_), do: Regex.split(~r/,+/, "a,b,,c") |> Enum.join("|")
          def replace_first(_), do: Regex.replace(~r/a/, "banana", "X", global: false)
          def replace_all(_), do: Regex.replace(~r/a/, "banana", "X")
          def replace_fn1(_), do: Regex.replace(~r/\\d+/, "a1b22c", fn m -> "<" <> m <> ">" end)
          def replace_fn2(_), do: Regex.replace(~r/(\\w)\\d/, "a1-b2", fn _m, c1 -> c1 <> c1 end)
          def compile_rt(x), do: (if Regex.match?(Regex.compile!("\\\\d{" <> :erlang.integer_to_binary(x) <> "}"), "abc123"), do: 5, else: 9)
          def run_idx(_) do
            [{o, l}] = Regex.run(~r/\\d+/, "abc123def", return: :index)
            o * 10 + l
          end
        end
        """, cases: [
          %{fn: "match_q", sig: {[:int], :int}, inputs: [[0]]},
          %{fn: "scan", sig: {[:int], :bin}, inputs: [[0]]},
          %{fn: "escape", sig: {[:int], :bin}, inputs: [[0]]},
          %{fn: "split2", sig: {[:int], :bin}, inputs: [[0]]},
          %{fn: "replace_first", sig: {[:int], :bin}, inputs: [[0]]},
          %{fn: "replace_all", sig: {[:int], :bin}, inputs: [[0]]},
          %{fn: "replace_fn1", sig: {[:int], :bin}, inputs: [[0]]},
          %{fn: "replace_fn2", sig: {[:int], :bin}, inputs: [[0]]},
          %{fn: "compile_rt", sig: {[:int], :int}, inputs: [[2], [9]]},
          %{fn: "run_idx", sig: {[:int], :int}, inputs: [[0]]}
        ]},
      # ---- FLOATS: f64 register file + :math.* host (libm) imports; bit-exact vs the VM ----
      %{cat: "floats", src: """
        defmodule FloatOps do
          def sqrt2(_n), do: :math.sqrt(2.0)
          def trig(_n), do: :math.sin(1.0) + :math.cos(2.0) * :math.tan(0.5)
          def powlog(_n), do: :math.pow(2.0, 10.0) - :math.log(100.0)
          def coerce(n), do: :math.sqrt(n + 0.0) * 2.0          # int arg -> float coercion
          # haversine LAX->JFK — the documented bit-exact case, in one expression chain.
          def haversine(_n) do
            r = 6371.0
            pi = :math.pi()
            lat1 = 33.9416 * pi / 180.0
            lat2 = 40.6413 * pi / 180.0
            dlat = lat2 - lat1
            dlon = (-73.7781 - -118.4085) * pi / 180.0
            a = :math.sin(dlat / 2.0) * :math.sin(dlat / 2.0) +
                  :math.cos(lat1) * :math.cos(lat2) * :math.sin(dlon / 2.0) * :math.sin(dlon / 2.0)
            r * 2.0 * :math.atan2(:math.sqrt(a), :math.sqrt(1.0 - a))
          end
        end
        """, extra: [], cases: [
          %{fn: "sqrt2", sig: {[:int], :float}, inputs: [[0]]},
          %{fn: "trig", sig: {[:int], :float}, inputs: [[0]]},
          %{fn: "powlog", sig: {[:int], :float}, inputs: [[0]]},
          %{fn: "coerce", sig: {[:int], :float}, inputs: [[2], [7]]},
          %{fn: "haversine", sig: {[:int], :float}, inputs: [[0]]}
        ]},
      # ---- PROCESSES: spawn/send/receive/self on the JSPI scheduler ----
      %{cat: "processes", proc: true, src: """
        defmodule CProc do
          def sumsq_to(n) do
            me = self()
            sr(1, n, me)
            collect(n, 0)
          end
          def sr(i, n, _me) when i > n, do: :ok
          def sr(i, n, me), do: (spawn(fn -> send(me, {:sq, i * i}) end); sr(i + 1, n, me))
          def collect(0, acc), do: acc
          def collect(n, acc), do: (receive do {:sq, v} -> collect(n - 1, acc + v) end)

          def counter(start) do
            s = spawn(fn -> server(0) end)
            send(s, {:add, start})
            send(s, {:add, 5})
            send(s, {:sub, 3})
            send(s, {:get, self()})
            receive do {:val, v} -> v end
          end
          def server(n) do
            receive do
              {:add, x} -> server(n + x)
              {:sub, x} -> server(n - x)
              {:get, from} -> send(from, {:val, n}); server(n)
            end
          end

          def nested(x) do
            me = self()
            spawn(fn ->
              inner = self()
              spawn(fn -> send(inner, {:r, x * 10}) end)
              receive do {:r, v} -> send(me, {:final, v + 1}) end
            end)
            receive do {:final, v} -> v end
          end
        end
        """, extra: [], cases: [
          %{fn: "sumsq_to", sig: {[:int], :int}, inputs: [[4], [10], [50]]},
          %{fn: "counter", sig: {[:int], :int}, inputs: [[10], [0]]},
          %{fn: "nested", sig: {[:int], :int}, inputs: [[5], [20]]}
        ]},
      # ---- GENSERVER: a generic server loop dispatching to a callback module (apply) ----
      %{cat: "genserver", proc: true, src: """
        defmodule GenDemo do
          def counter(start) do
            s = Srv.start(Counter, start)
            Srv.cast(s, {:inc, 10}); Srv.call(s, {:add, 5}); Srv.cast(s, {:inc, 3})
            Srv.call(s, :get)
          end
          def stack(_x) do
            s = Srv.start(Stack, [])
            Srv.cast(s, {:push, 1}); Srv.cast(s, {:push, 2}); Srv.cast(s, {:push, 3})
            a = Srv.call(s, :pop); b = Srv.call(s, :pop)
            a * 10 + b
          end
        end
        defmodule Srv do
          def start(mod, arg), do: spawn(fn -> loop(mod, mod.init(arg)) end)
          def loop(mod, state) do
            receive do
              {:call, from, req} ->
                {:reply, reply, ns} = mod.handle_call(req, from, state)
                send(from, {:reply, reply}); loop(mod, ns)
              {:cast, req} ->
                {:noreply, ns} = mod.handle_cast(req, state); loop(mod, ns)
            end
          end
          def call(pid, req), do: (send(pid, {:call, self(), req}); receive do {:reply, r} -> r end)
          def cast(pid, req), do: send(pid, {:cast, req})
        end
        defmodule Counter do
          def init(n), do: n
          def handle_call(:get, _f, s), do: {:reply, s, s}
          def handle_call({:add, x}, _f, s), do: {:reply, :ok, s + x}
          def handle_cast({:inc, x}, s), do: {:noreply, s + x}
        end
        defmodule Stack do
          def init(l), do: l
          def handle_call(:pop, _f, [h | t]), do: {:reply, h, t}
          def handle_cast({:push, x}, s), do: {:noreply, [x | s]}
        end
        """, extra: [], cases: [
          %{fn: "counter", sig: {[:int], :int}, inputs: [[100], [0]]},
          %{fn: "stack", sig: {[:int], :int}, inputs: [[0]]}
        ]},
      # ---- SUPERVISOR: links + trap_exit + exit signals -> restart a crashing worker ----
      %{cat: "supervisor", proc: true, src: """
        defmodule SupRestart do
          def run(x) do
            Process.flag(:trap_exit, true)
            loop(x, 0)
          end
          def loop(x, attempt) do
            me = self()
            spawn_link(fn -> worker(me, x, attempt) end)
            receive do
              {:result, v} -> v
              {:EXIT, _pid, :normal} -> loop(x, attempt)
              {:EXIT, _pid, _reason} -> loop(x, attempt + 1)
            end
          end
          def worker(parent, x, attempt) do
            if attempt < 2, do: exit(:crashed), else: send(parent, {:result, x * 100 + attempt})
          end
        end
        """, extra: [], cases: [
          %{fn: "run", sig: {[:int], :int}, inputs: [[5], [3], [0]]}
        ]},
      # ---- REGISTRY + MONITORS: named processes, send-by-name, {:DOWN,…} ----
      # (named uses one input: the VM's name table is GLOBAL across cases; the runtime's is
      #  per-run, so it would handle more — another spot the runtime is the cleaner one.)
      %{cat: "registry", proc: true, src: """
        defmodule NamedDemo do
          def named(start) do
            s = spawn(fn -> server(start) end)
            Process.register(s, :counter)
            send(:counter, {:add, 10})
            send(Process.whereis(:counter), {:add, 5})
            send(:counter, {:get, self()})
            receive do {:val, v} -> v end
          end
          def server(n) do
            receive do
              {:add, x} -> server(n + x)
              {:get, from} -> send(from, {:val, n}); server(n)
            end
          end
          def monitored(x) do
            w = spawn(fn -> :done end)
            Process.monitor(w)
            receive do {:DOWN, _ref, :process, _pid, _reason} -> x * 2 end
          end
        end
        """, extra: [], cases: [
          %{fn: "named", sig: {[:int], :int}, inputs: [[0]]},
          %{fn: "monitored", sig: {[:int], :int}, inputs: [[7], [21]]}
        ]},
      # ---- PIDS & REFERENCES as distinct types (is_pid/is_reference correctness) ----
      %{cat: "pid-ref", proc: true, src: """
        defmodule PidRef do
          def pid_is_pid(_x) do
            p = spawn(fn -> :ok end)
            if is_pid(p), do: 1, else: 0
          end
          def int_not_pid(x), do: (if is_pid(x), do: 1, else: 0)
          def ref_is_ref(_x), do: (if is_reference(make_ref()), do: 1, else: 0)
          def int_not_ref(x), do: (if is_reference(x), do: 1, else: 0)
          def self_eq(_x), do: (if self() == self(), do: 1, else: 0)
          def ref_neq(_x) do
            a = make_ref(); b = make_ref()
            if a == b, do: 1, else: 0
          end
        end
        """, extra: [], cases: [
          %{fn: "pid_is_pid", sig: {[:int], :int}, inputs: [[0]]},
          %{fn: "int_not_pid", sig: {[:int], :int}, inputs: [[5]]},
          %{fn: "ref_is_ref", sig: {[:int], :int}, inputs: [[0]]},
          %{fn: "int_not_ref", sig: {[:int], :int}, inputs: [[5]]},
          %{fn: "self_eq", sig: {[:int], :int}, inputs: [[0]]},
          %{fn: "ref_neq", sig: {[:int], :int}, inputs: [[0]]}
        ]},
      # ---- KILL: exit/2, kill-by-unwind of a parked process, link/monitor propagation ----
      %{cat: "kill", proc: true, src: """
        defmodule KillDemo do
          # Process.exit/2 kills a non-trapping child; the monitor sees :DOWN with our reason.
          def kill_parked(x) do
            child = spawn(fn -> receive do _ -> :never end end)
            ref = Process.monitor(child)
            Process.exit(child, :boom)
            receive do
              {:DOWN, ^ref, :process, ^child, :boom} -> x * 2
            end
          end
          # An abnormal exit propagates across a link to a trapping waiter as {:EXIT, pid, reason}.
          def trap_signal(x) do
            Process.flag(:trap_exit, true)
            child = spawn_link(fn -> receive do _ -> :never end end)
            Process.exit(child, :crash)
            receive do
              {:EXIT, ^child, :crash} -> x + 100
            end
          end
          # Process.exit(pid, :normal) to another non-trapping process is a no-op — it stays alive.
          def normal_noop(x) do
            child = spawn(fn -> receive do {:ping, from} -> send(from, :pong) end end)
            Process.exit(child, :normal)
            send(child, {:ping, self()})
            receive do :pong -> x end
          end
          # The real kill-by-UNWIND path: the target parks FIRST (a separate killer runs after it
          # suspends), so the kill rejects its parked JSPI stack rather than a not-yet-started child.
          def kill_after_park(x) do
            a = spawn(fn -> receive do _ -> :never end end)
            ref = Process.monitor(a)
            spawn(fn -> Process.exit(a, :boom) end)
            receive do
              {:DOWN, ^ref, :process, ^a, :boom} -> x * 3
            end
          end
        end
        """, extra: [], cases: [
          %{fn: "kill_parked", sig: {[:int], :int}, inputs: [[7]]},
          %{fn: "trap_signal", sig: {[:int], :int}, inputs: [[5]]},
          %{fn: "normal_noop", sig: {[:int], :int}, inputs: [[9]]},
          %{fn: "kill_after_park", sig: {[:int], :int}, inputs: [[8]]}
        ]},
      # ---- receive ... after: finite timeout fires; a message beats the timer; after 0 polls/drains ----
      %{cat: "recv-after", proc: true, src: """
        defmodule RecvAfter do
          # nothing ever sends :never -> the finite timer fires and the after-body runs.
          def times_out(x) do
            receive do :never -> 0 after 5 -> x * 2 end
          end
          # a message is already in the mailbox -> it wins, the 1000ms timer is cancelled.
          def message_wins(x) do
            send(self(), :go)
            receive do :go -> x + 1 after 1000 -> 0 end
          end
          # after 0 on an empty mailbox returns immediately (no blocking).
          def poll_empty(x) do
            receive do _ -> 0 after 0 -> x end
          end
          # after 0 drains all pending messages, then returns once the mailbox is empty.
          def drain(x) do
            send(self(), 10); send(self(), 20)
            do_drain(x)
          end
          defp do_drain(acc) do
            receive do n -> do_drain(acc + n) after 0 -> acc end
          end
        end
        """, extra: [], cases: [
          %{fn: "times_out", sig: {[:int], :int}, inputs: [[6]]},
          %{fn: "message_wins", sig: {[:int], :int}, inputs: [[6]]},
          %{fn: "poll_empty", sig: {[:int], :int}, inputs: [[9]]},
          %{fn: "drain", sig: {[:int], :int}, inputs: [[5]]}
        ]},
      # ---- REAL `use GenServer` on the actual OTP stack (:gen_server/:gen/:proc_lib/:sys) ----
      %{cat: "real-genserver", proc: true,
        extra: [GenServer, Keyword, Enum, Process, :gen_server, :gen, :proc_lib, :sys, :lists, :maps],
        src: """
        defmodule RealGen do
          use GenServer
          def init(n), do: {:ok, n}
          def handle_call(:get, _from, n), do: {:reply, n, n}
          def handle_cast({:add, k}, n), do: {:noreply, n + k}
          def run(start) do
            {:ok, pid} = GenServer.start_link(__MODULE__, start)
            GenServer.cast(pid, {:add, 5})
            GenServer.cast(pid, {:add, 3})
            GenServer.call(pid, :get)
          end
        end
        """, cases: [
          %{fn: "run", sig: {[:int], :int}, inputs: [[0], [10], [100]]}
        ]},
      # ---- A non-trivial app: real Supervisor + named GenServer + map state + Enum ----
      %{cat: "supervised-app", proc: true,
        extra: [GenServer, Supervisor, Keyword, Enum, Process, Map, Access,
                :gen_server, :gen, :proc_lib, :sys, :supervisor, :lists, :maps],
        src: """
        defmodule KVSup do
          use Supervisor
          def init(:ok), do: Supervisor.init([%{id: :kv, start: {KV, :start_link, [:kv]}}], strategy: :one_for_one)
          def run(base) do
            {:ok, _sup} = Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
            GenServer.cast(:kv, {:put, :a, base + 10})
            GenServer.cast(:kv, {:put, :b, base + 20})
            GenServer.cast(:kv, {:put, :c, base + 30})
            GenServer.call(:kv, {:get, :b}) + GenServer.call(:kv, :sum)
          end
        end
        defmodule KV do
          use GenServer
          def start_link(name), do: GenServer.start_link(__MODULE__, %{}, name: name)
          def init(m), do: {:ok, m}
          def handle_cast({:put, k, v}, m), do: {:noreply, Map.put(m, k, v)}
          def handle_call({:get, k}, _from, m), do: {:reply, Map.get(m, k), m}
          def handle_call(:sum, _from, m), do: {:reply, Enum.sum(Map.values(m)), m}
        end
        """, cases: [
          # one case only: the named supervisor/worker would clash on re-registration in the shared
          # VM oracle (the Wasm side gets a fresh scheduler per case, so it wouldn't).
          %{fn: "run", sig: {[:int], :int}, inputs: [[0]]}
        ]},
      # ---- REAL OTP CRASH/RESTART: a Supervisor restarts a named GenServer after abnormal exit ----
      %{cat: "supervisor-restart", proc: true,
        extra: [GenServer, Supervisor, Keyword, Enum, Process, Map, Access,
                :gen_server, :gen, :proc_lib, :sys, :supervisor, :lists, :maps],
        src: """
        defmodule SupCrash do
          use Supervisor
          def init(:ok), do: Supervisor.init([%{id: :w, start: {CrashWorker, :start_link, [:w]}}], strategy: :one_for_one)
          def run(base) do
            Process.register(self(), :tester)
            {:ok, _sup} = Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
            receive do {:started, _old} -> :ok end
            GenServer.cast(:w, {:set, base + 42})
            before = GenServer.call(:w, :get)
            GenServer.cast(:w, :boom)
            receive do {:started, _new} -> :ok end
            after_crash = GenServer.call(:w, :get)
            before * 100 + after_crash
          end
        end

        defmodule CrashWorker do
          use GenServer
          def start_link(name), do: GenServer.start_link(__MODULE__, 0, name: name)
          def init(_), do: (send(:tester, {:started, self()}); {:ok, 0})
          def handle_call(:get, _from, n), do: {:reply, n, n}
          def handle_cast({:set, x}, _), do: {:noreply, x}
          def handle_cast(:boom, _), do: exit(:boom)
        end
        """, cases: [
          %{fn: "run", sig: {[:int], :int}, inputs: [[0]]}
        ]}
    ]
  end

  # ---- type mappings ----
  defp exp_arg(:int), do: "int"
  defp exp_arg(:list), do: "list"
  defp exp_arg(:bin), do: "bin"
  defp exp_ret(:bool), do: "atom"
  defp exp_ret(:atom), do: "atom"
  defp exp_ret(t), do: Atom.to_string(t)
  defp drv_arg(:int), do: "int"
  defp drv_arg(:list), do: "list"
  defp drv_arg(:bin), do: "bin"
  defp drv_ret(t), do: Atom.to_string(t)

  # canonical string form (must match driver.mjs exactly)
  defp canon(:int, v), do: Integer.to_string(v)
  # floats: compare the exact IEEE-754 bit pattern (big-endian hex), not a formatted decimal — so a
  # 1-ULP difference can't hide behind rounding. Driver mirrors this via DataView.setFloat64.
  defp canon(:float, v), do: "f:" <> Base.encode16(<<v::float-64>>)
  defp canon(:bool, v), do: if(v, do: "true", else: "false")
  defp canon(:atom, v), do: ":" <> Atom.to_string(v)
  defp canon(:bin, v), do: "b:" <> v
  defp canon(:list, v), do: "[" <> Enum.map_join(v, ",", &Integer.to_string/1) <> "]"

  # minimal JSON encoder for the cases file
  defp json(i) when is_integer(i), do: Integer.to_string(i)
  defp json(true), do: "true"
  defp json(false), do: "false"
  defp json(a) when is_atom(a), do: json(Atom.to_string(a))
  defp json(s) when is_binary(s), do: ~s(") <> String.replace(s, ~s("), ~s(\\")) <> ~s(")
  defp json(l) when is_list(l), do: "[" <> Enum.map_join(l, ",", &json/1) <> "]"
  defp json(m) when is_map(m), do: "{" <> Enum.map_join(m, ",", fn {k, v} -> json(Atom.to_string(k)) <> ":" <> json(v) end) <> "}"

  def main(args) do
    File.mkdir_p!(@tmp)
    filter = List.first(args)
    entries = corpus() |> Enum.filter(fn e -> filter == nil or String.contains?(e.cat, filter) end)
    results = Enum.map(entries, &run_entry/1)
    report(results)
  end

  defp run_entry(%{cat: cat, src: src, cases: cases} = entry) do
    extra = Map.get(entry, :extra, [])
    proc = Map.get(entry, :proc, false)
    compiled = Code.compile_string(src)   # [{mod, bin}, …] all loaded into THIS VM (for the oracle)
    [{mod, _bin} | _] = compiled           # primary module holds the exported entry points
    flat = Enum.flat_map(cases, fn %{fn: f, sig: {argt, rett}, inputs: inputs} ->
      Enum.map(inputs, fn vals -> %{fn: f, argt: argt, rett: rett, vals: vals} end)
    end)
    # proc programs use self()/trap_exit/mailbox; run each oracle in a FRESH process so state
    # (trap_exit, leftover {:EXIT,…}) doesn't leak across cases — matching the runtime's fresh
    # scheduler per case. (Found by the harness: a leaked oracle, not a runtime bug.)
    oracles = Enum.map(flat, fn c ->
      try do
        result =
          if proc,
            do: Task.async(fn -> apply(mod, String.to_atom(c.fn), c.vals) end) |> Task.await(10_000),
            else: apply(mod, String.to_atom(c.fn), c.vals)
        canon(c.rett, result)
      rescue _ -> "ORACLE_ERR"
      catch _, _ -> "ORACLE_ERR" end
    end)

    actual =
      try do
        beams = Enum.map(compiled, fn {m, b} -> p = Path.join(@tmp, "#{m}.beam"); File.write!(p, b); p end)
        extra_beams = Enum.map(extra, fn m -> to_string(:code.which(m)) end)
        # closed-world protocol consolidation: a clean type-dispatch impl_for (no code server)
        elixir_ebin = :code.lib_dir(:elixir, :ebin)
        consol_beams = Map.get(entry, :consolidate, []) |> Enum.map(fn proto ->
          {:ok, bin} = Protocol.consolidate(proto, Protocol.extract_impls(proto, [elixir_ebin]))
          p = Path.join(@tmp, "#{proto}.beam"); File.write!(p, bin); p
        end)
        exports = cases |> Enum.uniq_by(& &1.fn) |> Enum.map_join(";", fn %{fn: f, sig: {a, r}} ->
          "#{f}:#{Enum.map_join(a, ",", &exp_arg/1)}->#{exp_ret(r)}"
        end)
        bignum_env = if Map.get(entry, :bignum, false), do: [{"BIGNUM", "1"}], else: []
        {wat, 0} = System.cmd("elixir", [@beam2wasm] ++ beams ++ consol_beams ++ extra_beams,
          env: [{"EXPORTS", exports}, {"STUB", "1"}] ++ bignum_env)
        watf = Path.join(@tmp, "#{mod}.wat")
        wasmf = Path.join(@tmp, "#{mod}.wasm")
        File.write!(watf, wat)
        {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf), stderr_to_stdout: true)

        if proc do
          # process programs: each case runs in a fresh JSPI scheduler (int args only)
          Enum.map(flat, fn c ->
            intargs = Enum.map(c.vals, &to_string/1)
            case Tooling.cmd(@node, ["--experimental-wasm-jspi", @runproc, wasmf, c.fn | intargs], stderr_to_stdout: true) do
              {out, 0} -> String.trim(out)
              {_, :timeout} -> "TIMEOUT"
              _ -> "PROC_ERR"
            end
          end)
        else
          casesf = Path.join(@tmp, "#{mod}.cases.json")
          File.write!(casesf, json(Enum.map(flat, fn c ->
            %{name: c.fn, ret: drv_ret(c.rett),
              args: Enum.zip(c.argt, c.vals) |> Enum.map(fn {t, v} -> %{type: drv_arg(t), val: v} end)}
          end)))
          case Tooling.cmd(@node, [@driver, wasmf, watf, casesf]) do
            {out, 0} -> if out == "", do: [], else: String.split(out, "\n")
            {_, :timeout} -> Enum.map(flat, fn _ -> "TIMEOUT" end)
            _ -> Enum.map(flat, fn _ -> "DRIVER_ERR" end)
          end
        end
      rescue
        _ -> Enum.map(flat, fn _ -> "BUILD_ERR" end)
      catch
        _, _ -> Enum.map(flat, fn _ -> "BUILD_ERR" end)
      end

    checks = Enum.with_index(flat) |> Enum.map(fn {c, i} ->
      got = Enum.at(actual, i, "BUILD_ERR")
      exp = Enum.at(oracles, i)
      label = "#{c.fn}(#{Enum.map_join(c.vals, ",", &inspect/1)})"
      %{label: label, pass: got == exp, got: got, exp: exp}
    end)
    %{cat: cat, checks: checks}
  end

  defp report(results) do
    IO.puts("\n══════════ CONFORMANCE: compiled Elixir (WasmGC) vs the Elixir VM ══════════\n")
    {tp, tt} = Enum.reduce(results, {0, 0}, fn %{cat: cat, checks: checks}, {ap, at} ->
      p = Enum.count(checks, & &1.pass)
      t = length(checks)
      bar = if p == t, do: "✅", else: "⚠️ "
      IO.puts("#{bar} #{String.pad_trailing(cat, 12)} #{p}/#{t}")
      for c <- checks, not c.pass do
        IO.puts("       ✗ #{c.label}  got #{inspect(c.got)}  exp #{inspect(c.exp)}")
      end
      {ap + p, at + t}
    end)
    pct = Float.round(tp * 100 / max(tt, 1), 1)
    IO.puts("\n──────────────────────────────────────────────────────────────────────────")
    IO.puts("  TOTAL: #{tp}/#{tt} cases bit-exact vs the VM  (#{pct}%)")
    IO.puts("──────────────────────────────────────────────────────────────────────────\n")
  end
end

Conf.main(System.argv())
