defmodule Mix.Tasks.Wasm.Build do
  use Mix.Task

  @shortdoc "Compile this Mix project (and its deps) to a deployable WasmGC module"

  @moduledoc """
  Compile a pure-Elixir Mix project to WebAssembly GC — the same pipeline that runs real
  Jason + Earmark byte-identical to the BEAM in production.

      mix wasm.build --module Blog --export "render:int->bin" --export "render_md:bin->bin" --worker

  ## Options

    * `--module`  — the module the exports live on (default: the camelized app name)
    * `--export`  — repeatable, `name:argtype,...->ret` with types `int|bin|float|atom|list|term`
    * `--out`     — output directory (default `wasm/`)
    * `--worker`  — also emit a deployable Cloudflare Worker scaffold
                    (worker.mjs + imports.mjs + wrangler.toml + config.capnp for local workerd)
    * `--strict` — FAIL the build if any reachable function is unsupported (0 stubs =
                    provably supported). Default reports the count and the names: real
                    libraries usually carry a few honest traps on cold paths.
    * `--no-stdlib`   — don't feed the default stdlib surface (you feed everything yourself)

  ## What it does

  1. `mix compile` (with protocol consolidation — the compiler also self-consolidates
     any unconsolidated protocol it's fed, so dynamic dispatch is closed-world).
  2. Collects beams: your app + every dep + consolidated protocols + a broad stdlib
     surface. Function-level DCE keeps only what your exports reach.
  3. Emits WAT, assembles with Binaryen `wasm-as` (-all, debug names kept).
  4. Prints the honest report: module size, functions kept, reachable stubs (0 = provably
     supported; `--strict` enforces it), and where everything was written.

  Verify the result like the repo does: run it under `node` with the shipped
  `imports.mjs`, diff against the same calls on the VM. If it's pure Elixir, it runs.
  """

  # the broad default surface real libraries need (the exact set that builds real
  # Jason + Earmark byte-identical in demo/markdown); DCE prunes to what the exports reach.
  # NB: modules the compiler shims at the host boundary (Regex/:re/:binary/:unicode/:math/
  # :string BIFs) must NOT be fed — their beams would double-define the shimmed functions.
  @stdlib [
    Kernel,
    Exception,
    Enum,
    String,
    String.Break,
    String.Chars,
    List,
    Map,
    MapSet,
    Keyword,
    Integer,
    Float,
    Tuple,
    Range,
    Stream,
    Enumerable,
    Collectable,
    Inspect,
    Inspect.Algebra,
    Access,
    ArgumentError,
    RuntimeError,
    KeyError,
    :lists,
    :maps,
    :sets,
    :ordsets,
    :gb_sets,
    :proplists,
    :orddict,
    :erl_scan,
    :erl_anno,
    :string,
    :io_lib,
    :io_lib_format,
    :io_lib_pretty,
    Enumerable.List,
    Enumerable.Map,
    Enumerable.Range,
    Enumerable.MapSet,
    Enumerable.Function,
    Enumerable.Stream,
    Collectable.List,
    Collectable.Map,
    Collectable.MapSet,
    Collectable.BitString,
    String.Chars.Integer,
    String.Chars.Float,
    String.Chars.List,
    String.Chars.BitString,
    String.Chars.Atom,
    List.Chars.BitString,
    List.Chars.Integer,
    List.Chars.List,
    List.Chars.Atom
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          module: :string,
          export: :keep,
          out: :string,
          worker: :boolean,
          strict: :boolean,
          stdlib: :boolean
        ]
      )

    exports = Keyword.get_values(opts, :export)
    if exports == [], do: Mix.raise("at least one --export \"name:args->ret\" is required")

    Mix.Task.run("compile")
    app = Mix.Project.config()[:app]
    module = Module.concat([Keyword.get(opts, :module, Macro.camelize(to_string(app)))])
    out = Path.expand(Keyword.get(opts, :out, "wasm"), File.cwd!())
    File.mkdir_p!(out)

    beams = collect_beams(module, Keyword.get(opts, :stdlib, true))
    Mix.shell().info("collected #{length(beams)} beams (#{inspect(module)} first)")

    watf = Path.join(out, "#{app}.wat")
    wasmf = Path.join(out, "#{app}.wasm")
    {wat, compile_stubs} = compile(beams, Enum.join(exports, ";"))
    File.write!(watf, wat)

    externals = external_stubs(wat)
    assemble(watf, wasmf)

    Mix.shell().info("""

      #{wasmf}
      module:    #{Float.round(File.stat!(wasmf).size / 1024 / 1024, 2)} MB (#{File.stat!(wasmf).size} bytes)
      exports:   #{Enum.join(exports, "  ")}
      stubs:     #{compile_stubs} unsupported constructs#{if compile_stubs == 0, do: " (0 = provably supported)", else: ""}
      externals: #{length(externals)} called-but-not-fed functions (each an honest trap if reached)
    """)

    if compile_stubs > 0 or externals != [] do
      Enum.each(Enum.take(externals, 15), &Mix.shell().info("        external: #{&1}"))

      if length(externals) > 15,
        do:
          Mix.shell().info(
            "        … #{length(externals) - 15} more (`;; stub: external` markers in the .wat)"
          )

      Mix.shell().info("""

        A stub/external is an HONEST TRAP: calling it raises with the function name — it never
        returns a wrong value. Real libraries carry some on cold paths the apply-analysis keeps
        (the production markdown demo ships with 34 + #{length(externals)}, all unexercised). Verify
        the paths you actually call differentially vs the VM. --strict refuses any of either.
      """)

      if opts[:strict] do
        Mix.raise(
          "--strict: #{compile_stubs} unsupported constructs + #{length(externals)} missing externals (0/0 = provably supported)"
        )
      end
    end

    if opts[:worker], do: emit_worker(out, app, exports)
    :ok
  end

  # ---- beam collection ------------------------------------------------------------------

  defp collect_beams(module, stdlib?) do
    build_lib = Path.join(Mix.Project.build_path(), "lib")

    app_beams =
      Path.wildcard(Path.join([build_lib, "*", "ebin", "*.beam"]))
      # the compiler itself is a dep of the host project — never feed it to itself
      |> Enum.reject(&String.contains?(&1, "/beam2wasm/"))

    consolidated = Path.wildcard(Path.join(Mix.Project.consolidation_path(), "*.beam"))

    primary =
      Enum.find(app_beams, &(Path.basename(&1) == "#{module}.beam")) ||
        Mix.raise("no beam for --module #{inspect(module)} under #{build_lib}")

    stdlib_beams =
      if stdlib? do
        @stdlib
        |> Enum.map(fn m ->
          Code.ensure_loaded(m)
          to_string(:code.which(m))
        end)
        |> Enum.filter(&String.ends_with?(&1, ".beam"))
      else
        []
      end

    ([primary | app_beams -- [primary]] ++ stdlib_beams ++ consolidated)
    |> dedup_prefer_consolidated(consolidated)
  end

  # drop unconsolidated copies of modules that have a consolidated build; preserve order
  # (the first beam is the primary module the exports resolve against).
  defp dedup_prefer_consolidated(beams, consolidated) do
    cons_names = MapSet.new(consolidated, &Path.basename/1)
    cons_paths = MapSet.new(consolidated)

    {kept, _} =
      Enum.reduce(beams, {[], MapSet.new()}, fn b, {acc, seen} ->
        name = Path.basename(b)
        drop = MapSet.member?(cons_names, name) and not MapSet.member?(cons_paths, b)

        if MapSet.member?(seen, name) or drop,
          do: {acc, seen},
          else: {[b | acc], MapSet.put(seen, name)}
      end)

    Enum.reverse(kept)
  end

  # ---- compile + assemble ---------------------------------------------------------------

  defp compile(beams, exports_spec) do
    # :stub so unsupported constructs become COUNTED traps we can report (and fail on
    # under --strict) instead of aborting mid-module.
    case Beam2Wasm.compile(beams, exports: exports_spec, stub: true) do
      {:ok, %Beam2Wasm.Result{wat: wat, stubs: stubs}} -> {wat, stubs}
      {:error, e} -> Mix.raise("compile failed: " <> Exception.message(e))
    end
  end

  # functions some kept code CALLS but no fed beam DEFINES — each emitted as a named trap
  defp external_stubs(wat) do
    Regex.scan(~r/;; stub: external ([^\s]+)/, wat) |> Enum.map(fn [_, name] -> name end) |> Enum.uniq()
  end

  defp assemble(watf, wasmf) do
    case System.cmd(Beam2Wasm.Toolchain.wasm_as!(), Beam2Wasm.Toolchain.wasm_as_args(watf, wasmf),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, n} -> Mix.raise("wasm-as failed (#{n}):\n#{out}")
    end
  end

  # ---- worker scaffold ------------------------------------------------------------------

  defp emit_worker(out, app, exports) do
    manifest =
      exports
      |> Enum.map(fn spec ->
        [name, sig] = String.split(spec, ":", parts: 2)
        [args_s, ret] = String.split(sig, "->")
        args = if String.trim(args_s) == "", do: [], else: String.split(args_s, ",", trim: true)
        unsupported = Enum.filter([ret | args], &(&1 in ~w(list term atom)))

        unless unsupported == [] do
          Mix.raise(
            "--worker can wire int/bin/float signatures over HTTP; #{name} uses #{inspect(unsupported)}"
          )
        end

        ~s|"#{String.trim(name)}": {"args": [#{Enum.map_join(args, ",", &~s|"#{String.trim(&1)}"|)}], "ret": "#{String.trim(ret)}"}|
      end)
      |> Enum.join(", ")

    File.write!(Path.join(out, "worker.mjs"), worker_template(app, manifest))
    File.cp!(Path.join(:code.priv_dir(:beam2wasm), "imports.mjs"), Path.join(out, "imports.mjs"))
    File.write!(Path.join(out, "wrangler.toml"), wrangler_template(app))
    File.write!(Path.join(out, "config.capnp"), capnp_template(app))

    Mix.shell().info("""
      worker scaffold written to #{out}/:
        worker.mjs imports.mjs wrangler.toml config.capnp
      try it locally:   workerd serve #{out}/config.capnp      (POST /<export> with JSON args array)
      ship it:          cd #{out} && npx wrangler deploy
    """)
  end

  defp worker_template(app, manifest) do
    """
    // Generated by `mix wasm.build --worker` — compiled Elixir (#{app}) on Cloudflare Workers.
    // POST /<export> with a JSON array of arguments (ints/floats as numbers, bins as strings);
    // the response body is the result. GET /health lists the wired exports.
    import wasmModule from "./#{app}.wasm";
    import { makeBig, makeMath, makeStr, makeProcStubs, makeFs, makeIo, memFsBacking } from "./imports.mjs";

    const EXPORTS = { #{manifest} };

    const big = makeBig(), math = makeMath();
    let e;
    const str = makeStr(() => e);
    const { proc, sched } = makeProcStubs();
    e = new WebAssembly.Instance(wasmModule, {
      big, math, str, proc, sched, fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e),
    }).exports;

    const enc = new TextEncoder(), dec = new TextDecoder();
    const toBin = (s) => { const u = enc.encode(s); const b = e.bin_alloc(u.length); for (let i = 0; i < u.length; i++) e.bin_put(b, i, u[i]); return b; };
    const fromBin = (b) => { const n = e.bin_len(b); const u = new Uint8Array(n); for (let i = 0; i < n; i++) u[i] = e.bin_get(b, i); return dec.decode(u); };
    const encodeArg = (t, v) => t === "bin" ? toBin(String(v)) : Number(v);
    const decodeRet = (t, r) => t === "bin" ? fromBin(r) : String(r);

    export default {
      async fetch(req) {
        const url = new URL(req.url);
        const name = url.pathname.slice(1);
        if (name === "health") return new Response("ok " + Object.keys(EXPORTS).join(" "));
        const sig = EXPORTS[name];
        if (!sig || req.method !== "POST") return new Response("POST /<export> with JSON args; exports: " + Object.keys(EXPORTS).join(" "), { status: sig ? 405 : 404 });
        try {
          const raw = await req.json();
          const args = sig.args.map((t, i) => encodeArg(t, raw[i]));
          return new Response(decodeRet(sig.ret, e[name](...args)));
        } catch (err) {
          const fn = ((err.stack || "").match(/at (\\S+) \\(wasm/) || [])[1] || String(err.message);
          return new Response("wasm trap: " + fn.replace(/^Elixir_46_/, "").replace(/_46_/g, "."), { status: 500 });
        }
      },
    };
    """
  end

  defp wrangler_template(app) do
    """
    name = "#{String.replace(to_string(app), "_", "-")}-wasm"
    main = "worker.mjs"
    compatibility_date = "2026-06-01"

    [[rules]]
    type = "CompiledWasm"
    globs = ["**/*.wasm"]
    fallthrough = true
    """
  end

  defp capnp_template(app) do
    """
    using Workerd = import "/workerd/workerd.capnp";

    const config :Workerd.Config = (
      services = [ (name = "main", worker = .mainWorker) ],
      sockets = [ (name = "http", address = "127.0.0.1:8799", http = (), service = "main") ],
    );

    const mainWorker :Workerd.Worker = (
      modules = [
        (name = "worker.mjs", esModule = embed "worker.mjs"),
        (name = "imports.mjs", esModule = embed "imports.mjs"),
        (name = "#{app}.wasm", wasm = embed "#{app}.wasm"),
      ],
      compatibilityDate = "2026-06-01",
    );
    """
  end
end
