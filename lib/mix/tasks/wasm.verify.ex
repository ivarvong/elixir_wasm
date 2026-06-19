defmodule Mix.Tasks.Wasm.Verify do
  use Mix.Task

  @shortdoc "Differentially verify the compiled module against the Elixir VM"

  @moduledoc """
  The same discipline this compiler is built on, for YOUR app: run your exported functions
  on the Elixir VM and on the compiled WasmGC module with identical inputs, and diff the
  results. A mismatch is a compiler bug or an unsupported path — either way you find out
  here, not in production.

      mix wasm.verify --module Blog --export "render:int->bin" --runs 25
      mix wasm.verify --module Calc --export "f:int,int->int" --cases verify/cases.exs
      mix wasm.verify --module Api --export "handle:bin->bin" --gen verify/gen.exs --runs 1000000

  ## Options

    * `--module` / `--export` — same as `mix wasm.build` (the module is rebuilt first)
    * `--runs N` — generated cases per export (default 20), seeded and reproducible
    * `--seed N` — generation seed (default 1)
    * `--cases FILE` — an `.exs` evaluating to `%{"export_name" => [args_list, ...]}`,
      used in addition to generated cases
    * `--gen FILE` — an `.exs` evaluating to `%{"export_name" => fn index -> args_list end}`:
      a structured case generator for exports whose inputs have a shape (a JSON API, a
      protocol frame) that typed random args can't reach. `:rand` is seeded from
      `{seed, index}` before each call, so any case regenerates standalone from its index.
      Runs are batched and streamed — `--runs 1000000` works in bounded memory.

  ## How results are compared

  Both sides render results into the same typed grammar: integers exact at any size,
  **floats by IEEE-754 bit pattern** (no cross-language formatting), binaries by content,
  lists/tuples structurally, maps sorted by rendered key. Equal strings = identical terms.
  A raise on both sides counts as agreement-on-error.

  Requires Node #{24}+ (`mix wasm.doctor` checks your toolchain).
  """

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          module: :string,
          export: :keep,
          runs: :integer,
          seed: :integer,
          cases: :string,
          gen: :string,
          out: :string
        ]
      )

    exports = Keyword.get_values(opts, :export)
    if exports == [], do: Mix.raise(~s(at least one --export "name:args->ret" is required))

    Mix.Task.run("compile")
    app = Mix.Project.config()[:app]
    module = Module.concat([Keyword.get(opts, :module, Macro.camelize(to_string(app)))])
    runs = Keyword.get(opts, :runs, 20)
    seed = Keyword.get(opts, :seed, 1)
    out = Path.expand(Keyword.get(opts, :out, "wasm"), File.cwd!())

    # build (reusing wasm.build's pipeline) unless the artifact is current
    Mix.Task.run("wasm.build", [
      "--module",
      inspect(module),
      "--out",
      out | Enum.flat_map(exports, &["--export", &1])
    ])

    wasmf = Path.join(out, "#{app}.wasm")
    extra_cases = load_cases(opts[:cases])
    gens = load_gen(opts[:gen])
    node = Beam2Wasm.Toolchain.node!()

    Mix.shell().info(
      "\nverifying #{inspect(module)} on the VM vs #{Path.relative_to_cwd(wasmf)} (seed=#{seed}, runs=#{runs})\n"
    )

    {pass, fail} =
      exports
      |> Enum.map(&parse_export/1)
      |> Enum.reduce({0, 0}, fn {name, argtypes, _ret}, {p, f} ->
        case Map.get(gens, name) do
          nil ->
            cases = Map.get(extra_cases, name, []) ++ gen_cases(argtypes, runs, seed)
            {vm, wasm} = run_both(module, name, argtypes, cases, wasmf, node)

            {p2, f2} =
              Enum.zip([cases, vm, wasm])
              |> Enum.reduce({p, f}, fn {args, v, w}, {pa, fa} ->
                if v == w do
                  {pa + 1, fa}
                else
                  Mix.shell().error("  ✗ #{name}(#{Enum.map_join(args, ", ", &inspect/1)})")
                  Mix.shell().error("      vm:   #{String.slice(v, 0, 110)}")
                  Mix.shell().error("      wasm: #{String.slice(w, 0, 110)}")
                  {pa, fa + 1}
                end
              end)

            Mix.shell().info("  #{name}: #{p2 - p}/#{length(cases)} identical")
            {p2, f2}

          gen ->
            {gp, gf} = verify_gen(module, name, argtypes, gen, runs, seed, wasmf, node)
            {p + gp, f + gf}
        end
      end)

    Mix.shell().info("\n  #{pass} identical · #{fail} DIVERGENT")

    if fail == 0 do
      Mix.shell().info("  ✅ the compiled module matches the VM on every generated case")
    else
      Mix.raise("#{fail} divergent cases — a compiler bug or an unsupported path; please report it")
    end
  end

  defp parse_export(spec) do
    [name, sig] = String.split(spec, ":", parts: 2)
    [args_s, ret] = String.split(sig, "->")

    args =
      if String.trim(args_s) == "",
        do: [],
        else: String.split(args_s, ",", trim: true) |> Enum.map(&String.trim/1)

    {String.trim(name), args, String.trim(ret)}
  end

  # seeded, type-directed case generation (ints straddle the integer-tier boundaries)
  defp gen_cases(argtypes, runs, seed) do
    :rand.seed(:exsss, {seed, 271, 828})
    interesting_ints = [0, 1, -1, 7, 1_073_741_823, -1_073_741_825, 2_147_483_648]

    for _ <- 1..runs do
      Enum.map(argtypes, fn
        "int" ->
          case :rand.uniform(4) do
            1 -> Enum.random(interesting_ints)
            2 -> :rand.uniform(1000) - 500
            3 -> :rand.uniform(4_000_000_000)
            4 -> :rand.uniform(100)
          end

        "float" ->
          (:rand.uniform() - 0.5) * 1000.0

        "bin" ->
          for(_ <- 1..:rand.uniform(12), into: "", do: <<Enum.random(~c"abc XYZ09_-")>>)

        other ->
          Mix.raise("wasm.verify can generate int/float/bin args (got #{other}); supply --cases for #{other}")
      end)
    end
  end

  # ── the --gen path: structured cases at fuzzing scale, batched + streamed ──
  # Each index is independently reproducible: :rand reseeds from {seed, index} before the
  # generator runs, so a divergence report's index + seed regenerate the exact case.
  @gen_batch 25_000

  defp verify_gen(module, name, argtypes, gen, runs, seed, wasmf, node) do
    nbatch = div(runs + @gen_batch - 1, @gen_batch)

    {pass, fail, samples} =
      Enum.reduce(0..(nbatch - 1), {0, 0, []}, fn b, {pa, fa, sa} ->
        lo = b * @gen_batch
        hi = min(runs, lo + @gen_batch) - 1

        cases =
          Enum.map(lo..hi, fn i ->
            :rand.seed(:exsss, {seed, i, 9241})
            gen.(i)
          end)

        {vm, wasm} = run_both(module, name, argtypes, cases, wasmf, node)

        {bp, bf, bs} =
          [Enum.to_list(lo..hi), cases, vm, wasm]
          |> Enum.zip()
          |> Enum.reduce({0, 0, []}, fn {i, args, v, w}, {x, y, s} ->
            cond do
              v == w -> {x + 1, y, s}
              length(sa) + length(s) < 5 -> {x, y + 1, [{i, args, v, w} | s]}
              true -> {x, y + 1, s}
            end
          end)

        done = pa + fa + bp + bf
        IO.write("\r  #{name}: #{done}/#{runs}  (#{fa + bf} divergent)")
        {pa + bp, fa + bf, sa ++ Enum.reverse(bs)}
      end)

    IO.write("\n")

    Enum.each(samples, fn {i, args, v, w} ->
      Mix.shell().error("  ✗ #{name} case ##{i} (regen: seed=#{seed} index=#{i})")
      Mix.shell().error("      args: #{String.slice(Enum.map_join(args, ", ", &inspect/1), 0, 140)}")
      Mix.shell().error("      vm:   #{String.slice(v, 0, 110)}")
      Mix.shell().error("      wasm: #{String.slice(w, 0, 110)}")
    end)

    if fail > length(samples),
      do: Mix.shell().error("  … #{fail - length(samples)} more divergences not shown")

    {pass, fail}
  end

  defp load_gen(nil), do: %{}

  defp load_gen(file) do
    {gens, _} = Code.eval_file(file)

    unless is_map(gens) and Enum.all?(gens, fn {k, v} -> is_binary(k) and is_function(v, 1) end),
      do: Mix.raise("--gen file must evaluate to %{\"export\" => fn index -> [args] end}")

    gens
  end

  defp load_cases(nil), do: %{}

  defp load_cases(file) do
    {cases, _} = Code.eval_file(file)
    unless is_map(cases), do: Mix.raise("--cases file must evaluate to %{\"export\" => [args, ...]}")
    cases
  end

  defp run_both(module, name, argtypes, cases, wasmf, node) do
    fun = String.to_atom(name)

    vm =
      Enum.map(cases, fn args ->
        try do
          canonical(apply(module, fun, args))
        rescue
          _ -> "error"
        catch
          _, _ -> "error"
        end
      end)

    runner = Path.join(System.tmp_dir!(), "b2w_verify_#{System.unique_integer([:positive])}.mjs")
    casesf = runner <> ".json"
    File.write!(casesf, encode_cases(name, argtypes, cases))
    File.write!(runner, runner_js())

    {out, 0} =
      System.cmd(node, [runner, wasmf, casesf], stderr_to_stdout: false)

    File.rm(runner)
    File.rm(casesf)
    wasm = out |> String.trim() |> String.split("\n") |> Enum.map(&Base.decode64!/1)
    {vm, wasm}
  end

  # ── the comparison grammar ──
  # Both sides render results into the same typed text: ints exact at any size, FLOATS BY
  # IEEE-754 BIT PATTERN (no cross-language formatting), binaries base64, maps sorted by
  # rendered key. Equal strings = identical terms. Both-raised = "error" (agreement).
  defp canonical(v) when is_integer(v), do: "i:" <> Integer.to_string(v)

  defp canonical(v) when is_float(v) do
    <<bits::64>> = <<v::float-64>>
    "f:" <> Integer.to_string(bits, 16)
  end

  defp canonical(v) when is_binary(v), do: "b:" <> Base.encode64(v)
  defp canonical(v) when is_atom(v), do: "a:" <> Atom.to_string(v)
  defp canonical(l) when is_list(l), do: "l(" <> Enum.map_join(l, ",", &canonical/1) <> ")"

  defp canonical(t) when is_tuple(t),
    do: "t(" <> (t |> Tuple.to_list() |> Enum.map_join(",", &canonical/1)) <> ")"

  defp canonical(m) when is_map(m) and not is_struct(m) do
    inner =
      m |> Enum.map(fn {k, v} -> canonical(k) <> "=" <> canonical(v) end) |> Enum.sort() |> Enum.join(",")

    "m(" <> inner <> ")"
  end

  defp canonical(other), do: "#opaque:" <> inspect(other)

  defp encode_cases(name, argtypes, cases) do
    rows =
      Enum.map(cases, fn args ->
        encoded =
          Enum.zip(argtypes, args)
          |> Enum.map(fn
            {"bin", v} -> %{t: "bin", v: Base.encode64(v)}
            {t, v} -> %{t: t, v: v}
          end)

        %{name: name, args: encoded}
      end)

    inspect_json(rows)
  end

  # dependency-free JSON encoding for the runner's case file
  defp inspect_json(v) when is_list(v), do: "[" <> Enum.map_join(v, ",", &inspect_json/1) <> "]"

  defp inspect_json(%{} = m),
    do: "{" <> Enum.map_join(m, ",", fn {k, v} -> "#{inspect(to_string(k))}:#{inspect_json(v)}" end) <> "}"

  defp inspect_json(v) when is_binary(v), do: inspect(v)
  defp inspect_json(v) when is_number(v) or is_boolean(v), do: to_string(v)

  defp runner_js do
    host = Path.join(:code.priv_dir(:beam2wasm), "host.mjs")

    """
    import fs from "node:fs";
    import { instantiate } from #{inspect(host)};
    const m = await instantiate(process.argv[2]);
    const e = m.exports;
    const cases = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));

    // the SAME typed grammar as the VM side: ints exact, floats by IEEE bit pattern,
    // binaries base64, maps sorted by rendered key
    const fmt = (t) => {
      if (t === null) return "l()";
      if (e.is_atom(t)) return "a:" + (e.atom_name ? m.fromBin(e.atom_name(t)) : "idx" + e.atom_idx(t));
      if (e.is_int(t)) {
        const v = e.int_val ? e.int_val(t) : BigInt(e.get_int(t));
        return "i:" + v.toString();
      }
      if (e.is_float && e.is_float(t)) {
        const dv = new DataView(new ArrayBuffer(8));
        dv.setFloat64(0, e.float_val(t));
        return "f:" + dv.getBigUint64(0).toString(16).toUpperCase();
      }
      if (e.is_bin(t)) {
        const n = e.bin_len(t);
        const u = new Uint8Array(n);
        for (let i = 0; i < n; i++) u[i] = e.bin_get(t, i);
        return "b:" + Buffer.from(u).toString("base64");
      }
      if (e.is_cons(t)) {
        const parts = [];
        let l = t;
        while (l !== null && e.is_cons(l)) { parts.push(fmt(e.head_term(l))); l = e.tail(l); }
        return "l(" + parts.join(",") + ")";
      }
      if (e.is_map && e.is_map(t)) {
        const kv = e.map_kv(t);
        const n = e.tup_len(kv);
        const pairs = [];
        for (let i = 0; i < n; i += 2) pairs.push(fmt(e.tup_get(kv, i)) + "=" + fmt(e.tup_get(kv, i + 1)));
        return "m(" + pairs.sort().join(",") + ")";
      }
      if (e.is_tuple(t)) {
        const n = e.tup_len(t);
        const parts = [];
        for (let i = 0; i < n; i++) parts.push(fmt(e.tup_get(t, i)));
        return "t(" + parts.join(",") + ")";
      }
      return "#opaque";
    };

    for (const c of cases) {
      let out;
      try {
        const args = c.args.map((a) =>
          a.t === "bin" ? m.toBin(new Uint8Array(Buffer.from(a.v, "base64"))) : a.v);
        out = fmt(e[c.name](...args));
      } catch (_e) {
        out = "error";
      }
      process.stdout.write(Buffer.from(out, "utf8").toString("base64") + "\\n");
    }
    """
  end
end
