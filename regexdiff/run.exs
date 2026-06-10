#!/usr/bin/env elixir
# regexdiff — the regex-shim differential corpus: a dense matrix of PCRE patterns × subjects ×
# Regex APIs, every case run compiled-on-WasmGC AND on the real Elixir VM (PCRE2) and diffed
# bit-exact. The shim (runtime/imports.mjs pcre2js + re_*) is a documented NIF-fidelity boundary
# (LIMITATIONS §1.1) — this suite is what makes that boundary a MEASURED line instead of a hope:
#
#   expect: :exact  — must match the VM byte-for-byte (the default; a diff is a FAILURE)
#   expect: :trap   — the shim must REFUSE (honest trap), never return a different value;
#                     a matching value is fine too (promotable: the construct now works)
#   expect: :delta  — documented approximation (branch-reset/atomic-group edges): a diff is
#                     tolerated AND reported; equality is reported as promotable
#
#   elixir run.exs            # whole corpus
#   elixir run.exs lookbehind # only cases whose tag matches
Code.require_file("../tooling.exs", __DIR__)

defmodule RegexDiff do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../compiler/beam2wasm.exs")
  @tmp Path.join(@here, "_work")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()

  @corpus ~S"""
  # expect ||| tag ||| expression (compiled verbatim into the corpus module)
  # ---- literals, classes, quantifiers ----
  exact|||lit-run|||enc(Regex.run(~r/abc/, "xxabcyy"))
  exact|||lit-miss|||enc(Regex.run(~r/abc/, "xyz"))
  exact|||class-run|||enc(Regex.run(~r/[a-c]+/, "zzabccbaz"))
  exact|||negclass-scan|||enc(Regex.scan(~r/[^0-9]+/, "a1b22cc3"))
  exact|||dclass|||enc(Regex.scan(~r/\d+/, "a1 b22 c333"))
  exact|||wsplus|||enc(Regex.run(~r/\w+/, "  hi_there!"))
  exact|||space-split|||enc(Regex.split(~r/\s+/, "a b\t c\nd"))
  exact|||greedy|||enc(Regex.run(~r/a{2,3}/, "aaaa"))
  exact|||lazy|||enc(Regex.run(~r/a{2,3}?/, "aaaa"))
  exact|||lazy-star|||enc(Regex.run(~r/<.*?>/, "<a><b>"))
  exact|||opt|||enc(Regex.scan(~r/colou?r/, "color colour"))
  exact|||alt-order|||enc(Regex.scan(~r/\d+|\w+/, "abc 123 a1"))
  exact|||empty-star|||enc(Regex.run(~r/x*/, "bbb"))
  exact|||escaped-meta|||enc(Regex.run(~r/a\.b/, "a.b axb"))
  # ---- groups, captures, backrefs ----
  exact|||groups|||enc(Regex.run(~r/(\w+)@(\w+)/, "mail: user@host"))
  exact|||noncap|||enc(Regex.run(~r/(?:ab)+(c)/, "ababc"))
  exact|||nested|||enc(Regex.run(~r/((a+)(b+))c/, "aabbc"))
  exact|||nonpart-mid|||enc(Regex.run(~r/(a)(x)?(b)/, "ab"))
  exact|||nonpart-trail|||enc(Regex.run(~r/(a)(x)?/, "a"))
  exact|||backref|||enc(Regex.run(~r/(\w)\1/, "abbc"))
  exact|||named-run|||enc(Regex.run(~r/(?<y>\d{4})-(?<m>\d{2})/, "on 2026-06-09"))
  exact|||named-caps|||enc(Regex.named_captures(~r/(?<y>\d{4})-(?<m>\d{2})/, "on 2026-06-09"))
  exact|||named-pcre-syntax|||enc(Regex.run(~r/(?'y'\d{4})/, "2026"))
  exact|||named-nonpart|||enc(Regex.named_captures(~r/(?<x>\d)(?<y>[a-z])?/, "7"))
  # ---- anchors & boundaries (incl. PCRE $-before-final-newline) ----
  exact|||anchors|||enc(Regex.run(~r/^abc$/, "abc"))
  exact|||dollar-final-nl|||enc(Regex.match?(~r/abc$/, "abc\n"))
  exact|||dollar-mid-nl|||enc(Regex.match?(~r/abc$/, "abc\nx"))
  exact|||z-strict|||enc(Regex.match?(~r/abc\z/, "abc\n"))
  exact|||Z-final-nl|||enc(Regex.match?(~r/abc\Z/, "abc\n"))
  exact|||A-start|||enc(Regex.run(~r/\Aab/, "abc"))
  exact|||word-b|||enc(Regex.scan(~r/\bword\b/, "a word, wordy"))
  exact|||word-B|||enc(Regex.run(~r/\Bord/, "word"))
  exact|||multiline|||enc(Regex.scan(~r/^b.*$/m, "a\nbcd\nbe"))
  exact|||dollar-class|||enc(Regex.run(~r/[$]\d+/, "cost $42"))
  # ---- flags ----
  exact|||icase|||enc(Regex.scan(~r/he(l+)o/i, "say HeLLo"))
  exact|||dotall|||enc(Regex.run(~r/a.c/s, "a\nc"))
  exact|||dot-no-nl|||enc(Regex.run(~r/a.c/, "a\nc"))
  exact|||xmode|||enc(Regex.run(Regex.compile!("a b # comment\nc", "x"), "abc"))
  # ---- PCRE-only escapes the shim translates ----
  exact|||h-space|||enc(Regex.scan(~r/\h+/, "a \t b"))
  exact|||R-newline|||enc(Regex.split(~r/\R/, "a\r\nb\nc"))
  # ---- lookaround ----
  exact|||lookahead|||enc(Regex.scan(~r/foo(?=bar)/, "foobar foobaz"))
  exact|||neg-lookahead|||enc(Regex.scan(~r/foo(?!bar)/, "foobar foobaz"))
  exact|||lookbehind|||enc(Regex.run(~r/(?<=\$)\d+/, "pay $100 now"))
  exact|||neg-lookbehind|||enc(Regex.scan(~r/(?<!\$)\b\d+/, "$100 200"))
  # ---- split semantics (captures dropped, empties kept, parts, include_captures) ----
  exact|||split-basic|||enc(Regex.split(~r/,+/, "a,b,,c"))
  exact|||split-edges|||enc(Regex.split(~r/,/, ",a,"))
  exact|||split-capture-drop|||enc(Regex.split(~r/(,)/, "a,b"))
  exact|||split-empty-pat|||enc(Regex.split(~r//, "ab"))
  exact|||split-parts2|||enc(Regex.split(~r/,/, "a,b,c", parts: 2))
  exact|||split-parts-nomatch|||enc(Regex.split(~r/x/, "abc", parts: 2))
  exact|||split-trim|||enc(Regex.split(~r/,/, ",a,,b,", trim: true))
  exact|||split-inc-caps|||enc(Regex.split(~r/[xy]/, "axbyc", include_captures: true))
  exact|||split-inc-caps-parts|||enc(Regex.split(~r/,/, "a,b,c", parts: 2, include_captures: true))
  # ---- replace ----
  exact|||replace-all|||enc(Regex.replace(~r/a/, "banana", "X"))
  exact|||replace-first|||enc(Regex.replace(~r/a/, "banana", "X", global: false))
  exact|||replace-backref|||enc(Regex.replace(~r/(\w+)@(\w+)/, "u@h", "\\2@\\1"))
  exact|||replace-fn|||enc(Regex.replace(~r/\d+/, "a1b22", fn m -> "<" <> m <> ">" end))
  exact|||replace-nomatch|||enc(Regex.replace(~r/zz/, "abc", "X"))
  # ---- run options / misc API ----
  exact|||run-index|||enc(Regex.run(~r/b(c+)/, "abccd", return: :index))
  exact|||match-true|||enc(Regex.match?(~r/\d/, "a1"))
  exact|||match-false|||enc(Regex.match?(~r/\d/, "ab"))
  exact|||escape-rt|||enc(Regex.run(Regex.compile!(Regex.escape("a.b[c")), "xa.b[cy"))
  exact|||compile-rt|||enc(Regex.run(Regex.compile!("\\d{2,}"), "a123"))
  exact|||scan-empty-adv|||enc(Regex.scan(~r/a*/, "abaa"))
  # ---- byte-mode vs char-mode (PCRE default is BYTE mode; /u opts into Unicode) ----
  delta|||byte-dot|||enc(Regex.run(~r/./, "é"))
  delta|||byte-w|||enc(Regex.scan(~r/\w+/, "héllo"))
  exact|||uni-dot|||enc(Regex.run(~r/./u, "é"))
  exact|||ascii-on-uni-subject|||enc(Regex.scan(~r/[a-z]+/, "abc déf ghi"))
  # ---- documented fidelity edges (LIMITATIONS 1.1) ----
  exact|||atomic-no-backtrack-needed|||enc(Regex.run(~r/(?>a+)b/, "aaab"))
  delta|||atomic-backtrack|||enc(Regex.match?(~r/(?>a*)ab/, "aaab"))
  exact|||branch-reset-first-alt|||enc(Regex.run(~r/(?|(a)|(b))x/, "ax"))
  delta|||branch-reset-later-alt|||enc(Regex.run(~r/(?|(a)|(b))x/, "bx"))
  # ---- constructs with NO JS equivalent: must refuse (honest trap), never lie ----
  trap|||possessive|||enc(Regex.run(~r/a*+b/, "aaab"))
  trap|||recursion|||enc(Regex.match?(~r/\((?:[^()]|(?R))*\)/, "(a(b))"))
  trap|||K-reset|||enc(Regex.run(~r/foo\Kbar/, "foobar"))
  trap|||subroutine|||enc(Regex.run(~r/(a)(?1)/, "aa"))
  """

  def cases do
    @corpus
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn l -> l == "" or String.starts_with?(l, "#") end)
    |> Enum.map(fn line ->
      [expect, tag, src] = String.split(line, "|||", parts: 3)
      {tag, src, String.to_atom(expect)}
    end)
  end

  def main(args) do
    File.mkdir_p!(@tmp)
    filter = List.first(args)
    cs = cases() |> Enum.filter(fn {tag, _, _} -> filter == nil or String.contains?(tag, filter) end)
    IO.puts("\n══════════ REGEX DIFFERENTIAL CORPUS: the :re shim vs real PCRE2, case by case ══════════\n")
    {wasmf, mod} = build(cs)
    vm = Enum.with_index(cs) |> Enum.map(fn {_, i} -> vm_case(mod, i) end)
    wasm = wasm_cases(wasmf, length(cs))

    rows = Enum.zip([cs, vm, wasm])
    {nexact, ndelta, ntrap, fails} =
      Enum.reduce(Enum.with_index(rows), {0, 0, 0, []}, fn {{{tag, _src, expect}, v, w}, i}, {ne, nd, nt, f} ->
        case verdict(expect, v, w) do
          :exact -> {ne + 1, nd, nt, f}
          :delta -> IO.puts("  📋 #{pad(tag)} known delta   vm=#{trunc8(v)} wasm=#{trunc8(w)}"); {ne, nd + 1, nt, f}
          :trap -> IO.puts("  🛑 #{pad(tag)} honest refusal (vm=#{trunc8(v)})"); {ne, nd, nt + 1, f}
          :promotable -> IO.puts("  ⬆️  #{pad(tag)} expected delta/trap but MATCHES — promote to :exact"); {ne + 1, nd, nt, f}
          :lie -> IO.puts("  ❌ #{pad(tag)} [#{i}] LIE  vm=#{trunc8(v)} wasm=#{trunc8(w)}"); {ne, nd, nt, [tag | f]}
        end
      end)
    IO.puts("\n  " <> String.duplicate("─", 78))
    IO.puts("  #{nexact} exact · #{ndelta} documented deltas · #{ntrap} honest refusals · #{length(fails)} LIES of #{length(cs)} cases")
    if fails == [], do: IO.puts("  ZERO LIES — every divergence is classified.\n"), else: System.halt(1)
  end

  defp verdict(:exact, v, w), do: if(v == w, do: :exact, else: :lie)
  defp verdict(:delta, v, w), do: if(v == w, do: :promotable, else: :delta)
  defp verdict(:trap, v, w) do
    cond do
      String.starts_with?(w, "TRAP") -> :trap
      v == w -> :promotable
      true -> :lie
    end
  end

  defp pad(s), do: String.pad_trailing(s, 28)
  defp trunc8(s), do: (if byte_size(s) > 48, do: String.slice(s, 0, 48) <> "…", else: s) |> inspect()

  defp build(cs) do
    clauses = cs |> Enum.with_index() |> Enum.map_join("\n", fn {{_tag, src, _}, i} -> "      #{i} -> #{src}" end)
    src = """
    defmodule RxDiff do
      def t(i) do
        case i do
    #{clauses}
          _ -> "?"
        end
      end
      defp enc(nil), do: "~nil"
      defp enc(true), do: "~T"
      defp enc(false), do: "~F"
      defp enc(x) when is_binary(x), do: "<" <> x <> ">"
      defp enc(x) when is_integer(x), do: Integer.to_string(x)
      defp enc(x) when is_list(x), do: "[" <> Enum.map_join(x, ",", &enc/1) <> "]"
      defp enc({a, b}), do: "{" <> enc(a) <> "," <> enc(b) <> "}"
      defp enc(x) when is_map(x) do
        inner = x |> Map.to_list() |> List.keysort(0) |> Enum.map_join(",", fn {k, v} -> enc(k) <> "=>" <> enc(v) end)
        "%{" <> inner <> "}"
      end
    end
    """
    [{m, bin} | _] = Code.compile_string(src)
    beam = Path.join(@tmp, "#{m}.beam")
    File.write!(beam, bin)
    extra =
      [Enum, String, String.Break, List, Map, Keyword, Integer, Enumerable, Enumerable.List, :lists, :maps]
      |> Enum.map(fn x -> Code.ensure_loaded(x); to_string(:code.which(x)) end)
      |> Enum.filter(&String.ends_with?(&1, ".beam"))
    watf = Path.join(@tmp, "rxdiff.wat")
    wasmf = Path.join(@tmp, "rxdiff.wasm")
    cmd = "elixir #{inspect(@beam2wasm)} #{Enum.map_join([beam | extra], " ", &inspect/1)} > #{inspect(watf)} 2>#{inspect(watf <> ".stub")}"
    {_, 0} = System.shell(cmd, env: [{"EXPORTS", "t:int->bin"}, {"STUB", "1"}, {"BIGNUM", "1"}])
    {_, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf, ["-g"]), stderr_to_stdout: true)
    {wasmf, m}
  end

  defp vm_case(mod, i) do
    try do
      apply(mod, :t, [i])
    rescue e -> "VMERR:#{Exception.message(e) |> String.slice(0, 40)}"
    catch _, _ -> "VMERR"
    end
  end

  # one node process runs every index; a per-case trap is caught and reported as TRAP@fn.
  defp wasm_cases(wasmf, n) do
    runner = Path.join(@tmp, "rxrun.mjs")
    File.write!(runner, """
    import fs from "node:fs";
    import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, memFsBacking } from "#{Path.join(@here, "../runtime/imports.mjs")}";
    const big = makeBig(), math = makeMath(); let e; const str = makeStr(() => e);
    const { proc, sched } = makeProcStubs();
    e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[2])),
      { big, math, str, proc, sched, fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e) }).exports;
    const dec = new TextDecoder();
    const rd = (b) => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return dec.decode(u); };
    const N = Number(process.argv[3]);
    const lines = [];
    for (let i = 0; i < N; i++) {
      let r;
      try { r = rd(e.t(i)); }
      catch (err) { r = "TRAP:" + String(err.message).slice(0, 60); }
      lines.push(Buffer.from(r, "utf8").toString("base64"));
    }
    process.stdout.write(lines.join("\\n"));
    """)
    {out, 0} = Tooling.cmd(@node, [runner, wasmf, to_string(n)], timeout: 120_000)
    out |> String.trim() |> String.split("\n") |> Enum.map(&Base.decode64!/1)
  end
end

RegexDiff.main(System.argv())
