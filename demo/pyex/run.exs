#!/usr/bin/env elixir
# demo/pyex — PYTHON on WasmGC: the pyex interpreter (ivarvong/pyex, a Python 3 interpreter in
# pure Elixir) compiled by beam2wasm. Every battery program runs on the BEAM and on WasmGC and
# the full transcript (print output + repr of the result + error text) must be BYTE-IDENTICAL.
#
#   cd app && mix deps.get && mix compile && mix wasm.build --module PyexWasm \
#       --export "eval:bin->bin" --out wasm && cd ..
#   elixir run.exs
Code.require_file("../../tooling.exs", __DIR__)

defmodule PyDiff do
  @here Path.dirname(__ENV__.file)
  @app Path.join(@here, "app")
  @node Tooling.node!()

  # Python programs spanning the language surface the interpreter supports.
  @programs [
    {"sort", "sorted([3, 1, 2])"},
    {"genexpr", "print(sum(i*i for i in range(10)))"},
    {"fib", "def fib(n):\n    return n if n < 2 else fib(n-1) + fib(n-2)\nprint([fib(i) for i in range(15)])"},
    {"dict", "x = {'a': 1, 'b': 2}\nx['c'] = x['a'] + x['b']\nprint(sorted(x.items()))"},
    {"fstring", "print(', '.join(f'{w.upper()}!' for w in ['hello', 'wasm', 'python']))"},
    {"bignum", "print(2**100)\nprint(10**20 // 7)"},
    {"float", "print(0.1 + 0.2)\nprint(round(3.14159, 2))"},
    {"strings", "s = 'Hello, World'\nprint(s.lower(), s.split(', '), s[::-1], s[2:7])"},
    {"class", "class Point:\n    def __init__(self, x, y):\n        self.x = x\n        self.y = y\n    def dist2(self):\n        return self.x**2 + self.y**2\np = Point(3, 4)\nprint(p.dist2())"},
    {"closure", "def make_adder(n):\n    return lambda x: x + n\nadd5 = make_adder(5)\nprint(list(map(add5, [1, 2, 3])))"},
    {"except", "try:\n    1 // 0\nexcept ZeroDivisionError as e:\n    print('caught:', e)"},
    {"while", "n, acc = 10, 1\nwhile n > 1:\n    acc *= n\n    n -= 1\nprint(acc)"},
    {"setcomp", "print(sorted({x % 5 for x in range(20)}))"},
    {"unpack", "a, *rest = [1, 2, 3, 4]\nprint(a, rest)\nd = dict(zip('abc', range(3)))\nprint(d)"},
    {"slice-neg", "xs = list(range(10))\nprint(xs[-3:], xs[::2], xs[7:2:-2])"},
    {"raise-custom", "class MyErr(Exception):\n    pass\ntry:\n    raise MyErr('boom')\nexcept MyErr as e:\n    print('got', e)"}
  ]

  def main do
    wasmf = Path.join(@app, "wasm/pyex_wasm.wasm")
    unless File.exists?(wasmf), do: (IO.puts("build first: cd app && mix wasm.build ..."); System.halt(1))
    IO.puts("\n══════════ PYTHON ON WASMGC: pyex (BEAM) vs pyex (WasmGC), transcript-identical ══════════\n")

    vm = vm_runs()
    wasm = wasm_runs(wasmf)

    results =
      Enum.zip([@programs, vm, wasm])
      |> Enum.map(fn {{tag, _src}, v, w} ->
        ok = v == w
        IO.puts("  #{if ok, do: "✅", else: "❌"} #{String.pad_trailing(tag, 14)} #{String.slice(v |> String.replace("\n", " ⏎ "), 0, 76)}")
        unless ok do
          IO.puts("     vm:   #{inspect(String.slice(v, 0, 140))}")
          IO.puts("     wasm: #{inspect(String.slice(w, 0, 140))}")
        end
        ok
      end)

    pass = Enum.count(results, & &1)
    IO.puts("\n  #{pass}/#{length(@programs)} Python programs TRANSCRIPT-IDENTICAL (BEAM vs WasmGC)")
    if pass == length(results), do: :ok, else: System.halt(1)
  end

  defp vm_runs do
    progs = Enum.map(@programs, fn {_t, src} -> src end)
    code = """
    for src <- #{inspect(progs, limit: :infinity, printable_limit: :infinity)} do
      IO.puts("B64:" <> Base.encode64(PyexWasm.eval(src)))
    end
    """
    {out, 0} = System.cmd("mix", ["run", "-e", code], cd: @app, env: [{"MIX_ENV", "dev"}])
    out |> String.split("\n", trim: true) |> Enum.filter(&String.starts_with?(&1, "B64:")) |> Enum.map(fn "B64:" <> b -> Base.decode64!(b) end)
  end

  defp wasm_runs(wasmf) do
    runner = Path.join(@here, "_work/runner.mjs")
    File.mkdir_p!(Path.dirname(runner))
    File.write!(runner, """
    import fs from "node:fs";
    import nodeCrypto from "node:crypto";
    import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, makeCrypto, memFsBacking } from "#{Path.join(@here, "../../runtime/imports.mjs")}";
    const big = makeBig(), math = makeMath(); let e; const str = makeStr(() => e);
    const { proc, sched } = makeProcStubs();
    e = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[2])),
      { big, math, str, proc, sched, fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e),
        crypto: makeCrypto(() => e, nodeCrypto), http: { get: () => { throw new Error("http not wired"); } } }).exports;
    const enc = new TextEncoder(), dec = new TextDecoder();
    const toBin = (s) => { const u = enc.encode(s); const b = e.bin_alloc(u.length); for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]); return b; };
    const fromBin = (b) => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return dec.decode(u); };
    const progs = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
    for (const src of progs) {
      let out;
      try { out = fromBin(e.eval(toBin(src))); }
      catch (err) { out = "TRAP:" + String(err.message).slice(0, 80); }
      process.stdout.write(Buffer.from(out, "utf8").toString("base64") + "\\n");
    }
    """)
    progsf = Path.join(@here, "_work/progs.json")
    File.write!(progsf, "[" <> Enum.map_join(@programs, ",", fn {_t, src} -> inspect(src, printable_limit: :infinity) end) <> "]")
    {out, 0} = Tooling.cmd(@node, [runner, wasmf, progsf], timeout: 120_000)
    out |> String.trim() |> String.split("\n") |> Enum.map(&Base.decode64!/1)
  end
end

PyDiff.main()
