# Beam2Wasm — BEAM -> WasmGC compiler (consumes OTP's :beam_disasm; emits WAT). The orchestration
# + emit path; the WAT runtime library is in Beam2Wasm.Codegen.Runtime, shared leaf helpers in Beam2Wasm.Codegen.Common.
# Run via the thin CLI shim ../beam2wasm.exs, or call Beam2Wasm.run/1 from a library context.
defmodule Beam2Wasm do
  @moduledoc """
  An ahead-of-time BEAM→WasmGC compiler: feed it `.beam` files (default `mix compile`
  output — it consumes OTP's own `:beam_disasm`), get a WAT module whose behavior is
  verified bit-exact against the Elixir VM by the differential suites in the parent
  repository (`elixir verify.exs`: conformance, fuzz, generative fuzz, regex corpus,
  stdlib scoreboard, real-dependency demos).

  Most users want the Mix task: `mix wasm.build --module M --export "f:int->bin" --worker`.
  The library entry point is `run/2`.
  """

  import Beam2Wasm.Codegen.Common
  import Beam2Wasm.Codegen.Runtime
  @skip ~w(module_info __info__)a

  import Beam2Wasm.Codegen.Emit

  @doc """
  Compile beams and return a `Beam2Wasm.Result` — the WAT plus the honesty report
  (stub count, called-but-not-fed externals). Runs the build in its own process, so
  it is safe to call from anywhere.

      {:ok, %Beam2Wasm.Result{wat: wat, stubs: 0}} =
        Beam2Wasm.compile(["a.beam"], exports: "f:int->int")
  """
  def compile(beam_paths, opts \\ []) do
    Task.async(fn ->
      try do
        wat = run(beam_paths, opts)

        externals =
          Regex.scan(~r/;; stub: external ([^\s]+)/, wat)
          |> Enum.map(fn [_, name] -> name end)
          |> Enum.uniq()

        {:ok, %Beam2Wasm.Result{wat: wat, stubs: Process.get(:stubs, 0), externals: externals}}
      rescue
        e -> {:error, e}
      end
    end)
    |> Task.await(:infinity)
  end

  @doc """
  Compile a list of `.beam` file paths into a WAT module (returned as a string).

  The first beam is the *primary module* — exports resolve against it.

  ## Options

    * `:exports` — the export spec, `"name:argtype,...->ret; name2:..."` with types
      `int | bin | float | atom | list | term` (default: the legacy demo exports)
    * `:stub`    — `true` compiles unsupported constructs as COUNTED traps instead of failing
      the build; the count is the honesty meter (`0` = provably supported). Default `false`.
    * `:bignum`  — exact arbitrary-precision integers (i31 → i64 → host BigInt). Default `true`.
    * `:reds`    — reduction budget for preemptive scheduling (proc mode defaults it on)
    * `:dce`     — function-level dead-code elimination from the export seeds. Default `true`.
    * `:fuse`    — cross-op i64 chain fusion. Default `true`.

  Build state is process-local: run each build in its own process (the `mix wasm.build`
  task wraps it in `Task.async/1`).
  """
  def run(beam_paths, opts \\ []) do
    Process.put(:exports_spec, Keyword.get(opts, :exports))
    Process.put(:dce, Keyword.get(opts, :dce, true))
    Process.put(:fuse, Keyword.get(opts, :fuse, true))
    opt_reds = Keyword.get(opts, :reds)
    opt_bignum = Keyword.get(opts, :bignum, true)
    Process.put(:stub, Keyword.get(opts, :stub, false))
    beam_paths = consolidate_protocols(beam_paths)

    parsed =
      Enum.map(beam_paths, fn p ->
        {:beam_file, mod, _exp, _attr, _info, fns} = :beam_disasm.file(String.to_charlist(p))
        {mod, fns}
      end)

    mods = Enum.map(parsed, &elem(&1, 0))
    Process.put(:primary_mod, hd(mods))
    # keep each function tagged with its module so names can be module-qualified ($Mod.fun_arity)
    user_all =
      parsed
      |> Enum.flat_map(fn {mod, fns} -> Enum.map(fns, &{mod, &1}) end)
      |> Enum.reject(fn {_mod, {:function, n, _a, _e, _i}} ->
        n in @skip or String.starts_with?(Atom.to_string(n), "-inlined-")
      end)

    # Function-level DCE (smart AOT): compile only functions reachable from the exported
    # entry points — not the whole stdlib. On by default (NODCE=1 to disable). Drops the
    # STUB-as-crutch: ship only reachable code, and if it has 0 stubs it's provably supported.
    user =
      if Process.get(:dce, true) do
        reach = reachable(user_all, export_seeds(mods))
        kept = Enum.filter(user_all, fn {m, {:function, n, a, _, _}} -> MapSet.member?(reach, {m, n, a}) end)
        IO.puts(:stderr, "DCE: kept #{length(kept)} of #{length(user_all)} functions")
        kept
      else
        user_all
      end

    # processes: spawn/send/receive present? -> emit proc imports + start_process + preemption.
    proc = proc_mode?(user)
    # term_eq reads this to enable pid/ref value-equality
    Process.put(:proc, proc)
    # MFA dispatch (spawn_opt / apply/3 / make_fun) needs the generic apply helper + apply_0..8.
    mfa? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, :erlang, f, _}} when f in [:spawn_opt, :apply, :make_fun, :hibernate], op) or
            match?(
              {_, _, {:extfunc, :erlang, f, _}, _} when f in [:spawn_opt, :apply, :make_fun, :hibernate],
              op
            )
        end)
      end)

    # try/catch/raise present? -> emit the Wasm exception tag
    exc = exc_mode?(user)
    Process.put(:exc, exc)
    # Reduction-counted preemption: REDS env sets the budget; proc mode defaults it on (so the
    # scheduler is preemptive, not just cooperative). Injects a per-entry decrement + yield.
    reds =
      case opt_reds do
        nil -> if proc, do: 2000, else: nil
        n when is_integer(n) -> n
      end

    Process.put(:reds, reds)
    # Exact integers are the default: i31 fast path, host BigInt on overflow. Set BIGNUM=0 only for
    # compiler experiments that intentionally want wrapping small-int arithmetic.
    bignum = opt_bignum
    Process.put(:bignum, bignum)
    # f64 floats + :math.* present? -> emit $float box + math host imports
    flt = float_mode?(user)
    Process.put(:float, flt)
    # :stub already seeded from opts at entry
    # Regex.replace/3,4 may receive a FUNCTION replacement: pre-scan here (before the closure table is
    # sized) so the $clos1/$clos2 types it dispatches on are forced into the table's type set.
    regex_replace? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, Regex, :replace, a}} when a in [3, 4], op) or
            match?({_, _, {:extfunc, Regex, :replace, a}, _} when a in [3, 4], op)
        end)
      end)

    # Closures: scan make_fun3 to learn every closure-target function, its call arity N
    # (= total arity - num free vars) and its slot in the funcref table.
    # unique [{mod, fun, total_arity, numfree}]
    clos_refs = collect_closures(user)
    # A "dual" target is both captured AND called directly (a named capture &f/a, always
    # 0 free vars): it keeps its normal signature; the table points at a thin wrapper.
    # set of {mod, fun, arity}
    direct = MapSet.new(called_funs(user))

    clos_map =
      clos_refs
      |> Enum.with_index()
      |> Map.new(fn {{m, fun, ar, nf}, i} ->
        {{m, fun, ar}, %{n: ar - nf, f: nf, idx: i, dual: MapSet.member?(direct, {m, fun, ar})}}
      end)

    Process.put(:closures, clos_map)
    literal_funs = collect_literal_funs(user)
    # erlang:make_fun(M,F,A) creates a fun dynamically. We lower it to a per-arity TRAMPOLINE that
    # reads M,F from the fun's free vars and tail-calls apply_N. Trampolines live in the funcref table
    # right after the static closures (arity N at index base+N), so make_fun is `base + A`.
    mkfun? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, &match?({_, _, {:extfunc, :erlang, :make_fun, 3}}, &1))
      end)

    tramp_ns = if mkfun? or literal_funs != [], do: Enum.to_list(0..8), else: []
    tramp_base = length(clos_refs)
    Process.put(:tramp_base, tramp_base)
    # maps:fold/3 is shimmed (calls a $clos3 Fun) — gate it (needs $ftab+$clos3) and force $clos3.
    mapsfold? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, &match?({_, _, {:extfunc, :maps, :fold, 3}}, &1))
      end)

    Process.put(:mapsfold, mapsfold?)

    clos_ns =
      (Enum.map(clos_refs, fn {_m, _f, ar, nf} -> ar - nf end) ++
         call_fun_arities(user) ++
         tramp_ns ++
         if(mapsfold?, do: [3], else: []) ++
         if(proc, do: [0], else: []) ++
         if(regex_replace?, do: [1, 2], else: []))
      |> Enum.uniq()
      |> Enum.sort()

    trampolines =
      Enum.map_join(tramp_ns, "\n", fn nn ->
        ps =
          if nn == 0, do: "", else: " " <> Enum.map_join(0..(nn - 1), " ", &"(param $x#{&1} (ref null eq))")

        as = if nn == 0, do: "", else: " " <> Enum.map_join(0..(nn - 1), " ", &"(local.get $x#{&1})")
        arr = "(struct.get $fun 1 (ref.cast (ref $fun) (local.get $self)))"
        m = "(array.get $freevars #{arr} (i32.const 0))"
        f = "(array.get $freevars #{arr} (i32.const 1))"

        "  (func $mkfun_tramp_#{nn} (type $clos#{nn}) (param $self (ref null eq))#{ps} (result (ref null eq))\n" <>
          "    (return_call $apply_#{nn}#{as} #{m} #{f}))"
      end)

    clos_types =
      Enum.map_join(clos_ns, "\n", fn nn ->
        "  (type $clos#{nn} (func (param#{String.duplicate(" (ref null eq)", nn + 1)}) (result (ref null eq))))"
      end)

    tabname = fn m, fun, ar ->
      if MapSet.member?(direct, {m, fun, ar}), do: fq(m, fun, ar) <> "__c", else: fq(m, fun, ar)
    end

    # Table wrapper for a "dual" target (captured AND called directly). The table entry is invoked with
    # the CALL arity (= total arity − num free vars): callar call-args are passed, the nf free vars travel
    # in `self`. So the wrapper is typed $clos{callar}, reads the free vars out of self, and tail-calls the
    # real function with (call-args ++ free-vars) — free vars occupy the HIGH arg slots (the closure ABI).
    # When nf = 0 this degenerates to the simple pass-through. (Earlier this ASSUMED nf = 0 and typed the
    # wrapper $clos{total_arity}, so a dual closure WITH free vars — e.g. Enum.aggregate_by's fun-0 — was
    # called as $clos{callar} but defined as $clos{total} → "signature mismatch" trap.)
    clos_wrappers =
      clos_refs
      |> Enum.filter(fn {m, fun, ar, _} -> MapSet.member?(direct, {m, fun, ar}) end)
      |> Enum.map_join("\n", fn {m, fun, ar, nf} ->
        callar = ar - nf

        ps =
          if callar == 0,
            do: "",
            else: " " <> Enum.map_join(0..(callar - 1), " ", &"(param $x#{&1} (ref null eq))")

        callas = if callar == 0, do: [], else: Enum.map(0..(callar - 1), &"(local.get $x#{&1})")

        fvs =
          if nf == 0,
            do: [],
            else:
              Enum.map(0..(nf - 1), fn k ->
                "(array.get $freevars (struct.get $fun 1 (ref.cast (ref $fun) (local.get $self))) (i32.const #{k}))"
              end)

        allas = Enum.join(callas ++ fvs, " ")
        allas = if allas == "", do: "", else: " " <> allas

        "  (func #{fq(m, fun, ar)}__c (type $clos#{callar}) (param $self (ref null eq))#{ps} (result (ref null eq))\n" <>
          "    (return_call #{fq(m, fun, ar)}#{allas}))"
      end)

    tab_entries =
      Enum.map(clos_refs, fn {m, fun, ar, _nf} -> tabname.(m, fun, ar) end) ++
        Enum.map(tramp_ns, &"$mkfun_tramp_#{&1}")

    clos_table =
      cond do
        tab_entries != [] ->
          "  (table $ftab #{length(tab_entries)} funcref)\n  (elem (table $ftab) (i32.const 0) func " <>
            Enum.join(tab_entries, " ") <> ")"

        # A reachable-but-unexecuted call_indirect $ftab (e.g. a DCE-kept stdlib higher-order fn whose
        # closure arg is never built on the taken path) still needs the table to VALIDATE. Empty is safe.
        clos_ns != [] ->
          "  (table $ftab 0 funcref)"

        true ->
          ""
      end

    # The atom `nil` is forced and interned as a REAL atom ($atom_nil), distinct from the empty
    # list `[]` (which is the null ref). Elixir's nil is the atom nil; conflating them mis-encodes
    # nil as [] and makes is_list(nil) wrong. true/false always; signals in proc mode.
    # Req.get!/1 — a real HTTP fetch. An EFFECT: it can't be computed in the sandbox, and its transport
    # (Req→Finch→Mint→sockets) can't compile, so we draw the boundary AT Req.get! and cross to the host
    # (the host owns the socket — like the process scheduler). DCE stops here (it's a "defined" leaf), so
    # none of Req's internals are pulled in. Differential testing still applies: feed the VM and the Wasm
    # the SAME response bytes and the pure parsing on top must produce identical output.
    # Only shim Req.get! at the top when the real Req module ISN'T being compiled. If the real Req beams
    # are passed in, let the whole Req pipeline compile and override the smallest thing (the transport).
    req_in_user = Enum.any?(user, fn {m, _} -> m == Req end)
    # real Req compiled in → override ONLY the adapter (Req.Finch.run/1, the one step touching the socket);
    # the whole 3609-fn Req pipeline (request steps + response decode) runs for real on top.
    Process.put(:req_override, req_in_user)

    http_get? =
      not req_in_user and
        Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
          Enum.any?(is, fn op ->
            match?({_, _, {:extfunc, Req, :get!, 1}}, op) or match?({_, _, {:extfunc, Req, :get!, 1}, _}, op)
          end)
        end)

    # :crypto.hash/2 — an OpenSSL NIF (hashing). Native code, can't compile → cross to the host (node/
    # WebCrypto). Deterministic, so the VM (OpenSSL) and Wasm (host) compute the identical standard digest.
    crypto_hash? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, :crypto, :hash, 2}}, op) or
            match?({_, _, {:extfunc, :crypto, :hash, 2}, _}, op)
        end)
      end)

    forced =
      [
        nil,
        true,
        false,
        :ok,
        :error,
        :undefined,
        :current_stacktrace,
        :none,
        :global,
        :nomatch,
        :trim,
        :trim_all,
        :parts,
        :include_captures,
        :infinity,
        :module,
        :source,
        :opts,
        :unix,
        :linux,
        :return,
        :index,
        :badkey,
        :badarith,
        :native,
        :second,
        :millisecond,
        :microsecond,
        :nanosecond,
        :__struct__,
        Regex,
        :caseless,
        :multiline,
        :dotall,
        :extended,
        :unicode,
        :enoent,
        :eacces,
        :eio,
        :badarg,
        :short,
        :decimals,
        :compact,
        :undef,
        :utf8,
        :latin1
      ] ++
        if(http_get?, do: [:body, :status, :__struct__, Req.Response], else: []) ++
        if(req_in_user,
          do: [:__struct__, Req.Response, :status, :headers, :body, :trailers, :private],
          else: []
        ) ++
        if(proc, do: [:EXIT, :normal, :DOWN, :process, :nonode@nohost, :link, :monitor], else: []) ++
        if(exc, do: [:throw, :error, :exit, :EXIT], else: [])

    # name-sorted interning: atom index order == name order, so $term_compare on atoms (which
    # compares indices) matches Erlang's atom term order. Correct, and cheap.
    # Intern every compiled function's MODULE and NAME atom: any function (incl. anonymous stdlib
    # closures like Stream.-zip_with/2-fun-0-) can be applied via the generic apply_N dispatch, which
    # keys on (mod_idx, fun_idx) — so those atoms must be interned or the dispatch clause is dropped
    # and apply_N falls to (unreachable).
    fn_atoms = Enum.flat_map(user, fn {m, {:function, nm, _, _, _}} -> [m, nm] end)

    atoms =
      (forced ++
         fn_atoms ++
         Enum.flat_map(user, fn {_m, {:function, _, _, _, is}} -> atoms_in(is) end) ++
         Enum.flat_map(literal_funs, fn {m, f, _a} -> [m, f] end))
      |> Enum.uniq()
      |> Enum.sort_by(&Atom.to_string/1)

    # atom -> interned index
    Process.put(:atom_idx, atoms |> Enum.with_index() |> Map.new())

    atom_globals =
      atoms
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {a, i} ->
        "  (global $atom_#{sanitize(a)} (ref $atom) (struct.new $atom (i32.const #{i})))"
      end)

    # atom_to_binary needs each atom's NAME (the $atom struct only holds its index). Gated: emit a
    # parallel table of name-binaries (same sorted order = same index) only when it's reachable.
    # any call form (incl. tail calls) OR a captured `&Atom.to_string/1` (literal fun) needs the table.
    atom_names? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?(
            {_, _, {:extfunc, :erlang, f, _}}
            when f in [:atom_to_binary, :binary_to_existing_atom, :list_to_existing_atom],
            op
          ) or
            match?(
              {_, _, {:extfunc, :erlang, f, _}, _}
              when f in [:atom_to_binary, :binary_to_existing_atom, :list_to_existing_atom],
              op
            )
        end)
      end) or Enum.any?(collect_literal_funs(user), &match?({:erlang, :atom_to_binary, _}, &1)) or
        to_string?(user) or crypto_hash?

    Process.put(:atom_names, atom_names?)
    # String case mapping is genuinely table-backed -> delegate to the host (like math/big). Gated.
    strcase? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, String.Unicode, f, _}} when f in [:upcase, :downcase], op) or
            match?({_, _, {:extfunc, String.Unicode, f, _}, _} when f in [:upcase, :downcase], op)
        end)
      end)

    # Regex.split/3 — delegated to a host JS RegExp (like math/str). Gated on reachability.
    regex_split? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, Regex, :split, 3}}, op) or
            match?({_, _, {:extfunc, Regex, :split, 3}, _}, op)
        end)
      end)

    Process.put(:regex_split, regex_split?)

    regex_run3? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, Regex, :run, 3}}, op) or match?({_, _, {:extfunc, Regex, :run, 3}, _}, op)
        end)
      end)

    Process.put(:regex_run3, regex_run3?)
    # replace/3 and /4 share one impl (string- or FUNCTION-replacement; the early `regex_replace?`
    # pre-scan above already forced $clos1/$clos2 for the function case).
    regex_replace3? = regex_replace?
    Process.put(:regex_replace3, regex_replace3?)
    # the rest of the Regex surface: match?/2, scan/2, escape/1, split/2, compile/1, compile!/1,2
    regex_more? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?(
            {_, _, {:extfunc, Regex, f, a}}
            when {f, a} in [
                   {:match?, 2},
                   {:scan, 2},
                   {:escape, 1},
                   {:split, 2},
                   {:compile, 1},
                   {:compile!, 1},
                   {:compile!, 2},
                   {:named_captures, 2}
                 ],
            op
          ) or
            match?(
              {_, _, {:extfunc, Regex, f, a}, _}
              when {f, a} in [
                     {:match?, 2},
                     {:scan, 2},
                     {:escape, 1},
                     {:split, 2},
                     {:compile, 1},
                     {:compile!, 1},
                     {:compile!, 2},
                     {:named_captures, 2}
                   ],
              op
            )
        end)
      end)

    # run/2 shim is also needed when run/3 is used (run/3 delegates to it for the non-index path);
    # split/3 likewise backs split/2.
    regex_split? = regex_split? or regex_more?
    Process.put(:regex_split, regex_split?)
    # ── the effects ABI: File/IO handed to the HOST (virtual fs is a valid backing) ──
    fs? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, :file, f, _}} when f in [:read_file, :write_file], op) or
            match?({_, _, {:extfunc, :file, f, _}, _} when f in [:read_file, :write_file], op)
        end)
      end)

    io? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, IO, f, a}} when {f, a} in [{:puts, 1}, {:puts, 2}, {:warn, 1}], op) or
            match?({_, _, {:extfunc, IO, f, a}, _} when {f, a} in [{:puts, 1}, {:puts, 2}, {:warn, 1}], op)
        end)
      end)

    # :sql_host.exec/2 — a SQL database handed to the host, like :file. The backing decides:
    # node:sqlite locally, ctx.storage.sql inside a Durable Object. SQL text + JSON-encoded
    # params in, JSON-encoded rows out (the program uses real Jason on both sides of the call).
    sql? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, :sql_host, :exec, 2}}, op) or
            match?({_, _, {:extfunc, :sql_host, :exec, 2}, _}, op)
        end)
      end)

    Process.put(:fs_shim, fs?)
    Process.put(:io_shim, io?)
    Process.put(:sql_shim, sql?)
    # :unicode NF* normalization -> host (JS String.prototype.normalize — same Unicode tables)
    uninorm? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?(
            {_, _, {:extfunc, :unicode, f, 1}}
            when f in [
                   :characters_to_nfc_binary,
                   :characters_to_nfd_binary,
                   :characters_to_nfkc_binary,
                   :characters_to_nfkd_binary
                 ],
            op
          ) or
            match?(
              {_, _, {:extfunc, :unicode, f, 1}, _}
              when f in [
                     :characters_to_nfc_binary,
                     :characters_to_nfd_binary,
                     :characters_to_nfkc_binary,
                     :characters_to_nfkd_binary
                   ],
              op
            )
        end)
      end)

    Process.put(:uninorm, uninorm?)
    # float -> text (float_to_binary/list): host formatter (Ryu digits are unique; the host applies
    # Erlang's exact formatting conventions). Needs float mode for the $float type.
    fltfmt? =
      flt and
        Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
          Enum.any?(is, fn op ->
            match?({_, _, {:extfunc, :erlang, f, _}} when f in [:float_to_binary, :float_to_list], op) or
              match?({_, _, {:extfunc, :erlang, f, _}, _} when f in [:float_to_binary, :float_to_list], op)
          end)
        end)

    # text -> float: both engines do correctly-rounded decimal->double (strtod / Number),
    # so a host parse is exact. Gated like flt_fmt.
    fltparse? =
      flt and
        Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
          Enum.any?(is, fn op ->
            match?({_, _, {:extfunc, :erlang, f, 1}} when f in [:binary_to_float, :list_to_float], op) or
              match?({_, _, {:extfunc, :erlang, f, 1}, _} when f in [:binary_to_float, :list_to_float], op)
          end)
        end)

    regex_run? =
      regex_run3? or regex_more? or
        Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
          Enum.any?(is, fn op ->
            match?({_, _, {:extfunc, Regex, :run, 2}}, op) or
              match?({_, _, {:extfunc, Regex, :run, 2}, _}, op)
          end)
        end)

    # :string.titlecase/1 (String.capitalize) -> uppercase the first grapheme; delegate to the host.
    # Only shim when the real :string module ISN'T compiled in (else its body wins — its unicode_util
    # path stubs, but on the demo's executed path titlecase is never called).
    titlecase? =
      not Enum.any?(user, fn {m, _} -> m == :string end) and
        Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
          Enum.any?(is, fn op ->
            match?({_, _, {:extfunc, :string, :titlecase, 1}}, op) or
              match?({_, _, {:extfunc, :string, :titlecase, 1}, _}, op)
          end)
        end)

    atomname_global =
      cond do
        not atom_names? ->
          ""

        # V8 caps array.new_fixed at 10,000 elements; big atom tables (pyex interns ~13k)
        # build the array imperatively in the module's start function instead.
        length(atoms) > 9_999 ->
          sets =
            atoms
            |> Enum.with_index()
            |> Enum.map_join("\n", fn {a, i} ->
              "    (array.set $tuple (ref.cast (ref $tuple) (global.get $atomnames_m)) (i32.const #{i}) #{bin_literal(Atom.to_string(a))})"
            end)

          """
            (global $atomnames_m (mut (ref null eq)) (ref.null none))
            (func $init_atomnames
              (global.set $atomnames_m (array.new_default $tuple (i32.const #{length(atoms)})))
          #{sets})
            (start $init_atomnames)
            (func $atomnames_get (result (ref $tuple)) (ref.cast (ref $tuple) (global.get $atomnames_m)))
          """

        true ->
          names = Enum.map_join(atoms, " ", fn a -> bin_literal(Atom.to_string(a)) end)

          """
            (global $atomnames (ref $tuple) (array.new_fixed $tuple #{length(atoms)} #{names}))
            (func $atomnames_get (result (ref $tuple)) (global.get $atomnames))
          """
      end

    funcs = Enum.map_join(user, "\n", fn {mod, f} -> safe_compile_fun(mod, f) end)
    # completeness meter: reachable stubs (function-level OR opcode-level). 0 ⇒ provably supported.
    IO.puts(:stderr, "STUBS: #{Process.get(:stubs, 0)} unsupported reachable (0 = provably supported)")
    # Auto-stub any function that's called but not compiled in (external modules we don't
    # ship). The call traps if reached; the list fast paths never call these.
    defined = MapSet.new(user, fn {mod, {:function, n, a, _, _}} -> {mod, n, a} end)
    # BIF shims are emitted once, unconditionally (so builtin->builtin deps like
    # reverse/1 -> reverse/2 are always satisfied). Their BEAM bodies are skipped in
    # safe_compile_fun, and the stub pass skips them too.
    builtin_section = builtins() |> Map.values() |> Enum.join("\n")
    # wrappers for captured inline BIFs (&abs/1, &band/2, …) so the apply/trampoline path can call them
    capture_section = capture_wrappers(user)
    # dynamic-dispatch helpers for any apply/apply_last in the program
    apply_section = apply_arities(user) |> Enum.map_join("\n", &gen_apply(&1, user))
    # :math.* functions are provided by float_helpers (host imports), not stubbed.
    math_defined = if flt, do: MapSet.new(math_funs_used(user)), else: MapSet.new()
    # atom_to_binary/{1,2} are provided below (via the $atomnames table), not stubbed.
    extra_defined =
      (if(atom_names?,
         do: [
           {:erlang, :atom_to_binary, 1},
           {:erlang, :atom_to_binary, 2},
           {:erlang, :binary_to_existing_atom, 1},
           {:erlang, :binary_to_existing_atom, 2},
           {:erlang, :list_to_existing_atom, 1}
         ],
         else: []
       ) ++
         if(strcase?, do: [{String.Unicode, :upcase, 3}, {String.Unicode, :downcase, 3}], else: []) ++
         if(to_string?(user), do: [{String.Chars, :to_string, 1}], else: []) ++
         if(regex_split?, do: [{Regex, :split, 3}], else: []) ++
         if(regex_run?, do: [{Regex, :run, 2}], else: []) ++
         if(regex_run3?, do: [{Regex, :run, 3}], else: []) ++
         if(regex_replace3?, do: [{Regex, :replace, 3}, {Regex, :replace, 4}], else: []) ++
         if(regex_more?,
           do: [
             {Regex, :match?, 2},
             {Regex, :scan, 2},
             {Regex, :escape, 1},
             {Regex, :split, 2},
             {Regex, :compile, 1},
             {Regex, :compile!, 1},
             {Regex, :compile!, 2},
             {Regex, :named_captures, 2}
           ],
           else: []
         ) ++
         if(fs?, do: [{:file, :read_file, 1}, {:file, :write_file, 2}, {:file, :write_file, 3}], else: []) ++
         if(sql?, do: [{:sql_host, :exec, 2}], else: []) ++
         if(fltparse?, do: [{:erlang, :binary_to_float, 1}, {:erlang, :list_to_float, 1}], else: []) ++
         if(fltfmt?,
           do: [
             {:erlang, :float_to_binary, 1},
             {:erlang, :float_to_binary, 2},
             {:erlang, :float_to_list, 1},
             {:erlang, :float_to_list, 2}
           ],
           else: []
         ) ++
         if(io?, do: [{IO, :puts, 1}, {IO, :puts, 2}, {IO, :warn, 1}], else: []) ++
         if(titlecase?, do: [{:string, :titlecase, 1}], else: []) ++
         if(http_get?, do: [{Req, :get!, 1}], else: []) ++
         if(crypto_hash?, do: [{:crypto, :hash, 2}], else: []))
      |> MapSet.new()

    stubs =
      called_funs(user)
      |> Enum.reject(fn {m, f, a} ->
        MapSet.member?(defined, {m, f, a}) or Map.has_key?(builtins(), fq(m, f, a)) or
          MapSet.member?(math_defined, {m, f, a}) or MapSet.member?(extra_defined, {m, f, a})
      end)
      |> Enum.map(fn {m, f, a} -> {fq(m, f, a), a, "#{m}.#{f}"} end)
      # distinct ops can sanitize alike
      |> Enum.uniq_by(fn {name, _a, _orig} -> name end)
      |> Enum.map_join("\n", fn {name, a, orig} ->
        ps =
          if a == 0,
            do: "",
            else: " " <> (String.duplicate("(param (ref null eq)) ", a) |> String.trim_trailing())

        "  (func #{name}#{ps} (result (ref null eq)) (unreachable)) ;; stub: external #{orig}/#{a}"
      end)

    [
      "(module",
      "  ;; @atoms " <> atoms_json(atoms),
      # mut tail: TRMC hole-patching
      "  (type $cons (struct (field (ref null eq)) (field (mut (ref null eq)))))",
      # $tuple is a MUTABLE array of terms (mutability only used to BUILD new tuples in setelement/
      # insert/append BIFs — Elixir tuples are never mutated in place). It doubles as the kv-array type
      # used internally by the map flatten/compare helpers (one canonical type; kv arrays never escape
      # to user code so is_tuple on them can't be observed).
      "  (type $tuple (array (mut (ref null eq))))",
      "  (type $atom (struct (field i32)))",
      # Maps are a persistent weight-balanced BST keyed by Erlang term order: O(log n) get/put,
      # in-order = key-sorted (so $map_kv flatten preserves iteration order). Node: key,val,left,right,size.
      "  (rec (type $mnode (struct (field (ref null eq)) (field (ref null eq)) (field (ref null $mnode)) (field (ref null $mnode)) (field i32))))",
      "  (type $map (struct (field (ref null $mnode))))",
      "  (type $bytes (array (mut i8)))",
      "  (type $binary (struct (field (ref $bytes))))",
      # bytes, pos-bits, end-bits
      "  (type $mctx (struct (field (ref $bytes)) (field (mut i32)) (field i32)))",
      # sub-byte bitstring VALUE: bytes (MSB-padded), bit length
      "  (type $bitstr (struct (field (ref $bytes)) (field i32)))",
      "  (type $freevars (array (ref null eq)))",
      "  (type $fun (struct (field i32) (field (ref $freevars))))",
      # Pids and references are DISTINCT boxed types (not plain i31 integers), so is_pid/is_reference
      # are correct and a pid never compares equal to the integer with the same id. Both wrap an i32
      # id; equality/ordering go by that id (via $term_compare), not struct identity. Always emitted
      # (cheap) so the term helpers can reference them unconditionally.
      # NB: Wasm GC canonicalizes structurally-identical types, so these must NOT be `(struct (field
      # i32))` — that's $atom, and ref.test would confuse pids/refs/atoms. Distinguish by field
      # mutability (part of the type) and arity: $pid = one mutable i32, $ref = two i32.
      "  (type $pid (struct (field (mut i32))))",
      "  (type $ref (struct (field i32) (field i32)))",
      clos_types,
      if(bignum, do: "  (type $big (struct (field externref)))", else: ""),
      # i64 middle tier: integers that overflow i31 but fit 64 bits live here and are computed in
      # Wasm (no host BigInt crossing); only values exceeding i64 fall through to $big.
      if(bignum, do: "  (type $i64 (struct (field i64)))", else: ""),
      if(flt, do: "  (type $float (struct (field f64)))", else: ""),
      # NB: every (import …) must precede all non-import definitions (tags/globals/funcs). The
      # reds (global) and exc (tag) are NOT imports, so they come *after* the import block below.
      if(proc, do: proc_imports(), else: ""),
      if(reds, do: "  (import \"sched\" \"yield\" (func $yield))", else: ""),
      if(bignum, do: bignum_imports(), else: ""),
      if(flt, do: float_imports(user), else: ""),
      if(strcase?,
        do:
          "  (import \"str\" \"upcase\" (func $host_str_upcase (param (ref null eq)) (result (ref null eq))))\n  (import \"str\" \"downcase\" (func $host_str_downcase (param (ref null eq)) (result (ref null eq))))",
        else: ""
      ),
      if(regex_split?,
        do:
          "  (import \"str\" \"re_split\" (func $host_re_split (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (param i32) (param i32) (result (ref null eq))))",
        else: ""
      ),
      if(regex_run?,
        do:
          "  (import \"str\" \"re_run\" (func $host_re_run (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (result (ref null eq))))",
        else: ""
      ),
      if(regex_run3?,
        do:
          "  (import \"str\" \"re_run_index\" (func $host_re_run_index (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (result (ref null eq))))",
        else: ""
      ),
      if(regex_replace3?,
        do:
          "  (import \"str\" \"re_replace\" (func $host_re_replace (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (param i32) (result (ref null eq))))\n  (import \"str\" \"re_replace_fun\" (func $host_re_replace_fun (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (param i32) (result (ref null eq))))",
        else: ""
      ),
      if(regex_more?,
        do:
          "  (import \"str\" \"re_test\" (func $host_re_test (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (result i32)))\n  (import \"str\" \"re_scan\" (func $host_re_scan (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (result (ref null eq))))\n  (import \"str\" \"re_escape\" (func $host_re_escape (param (ref null eq)) (result (ref null eq))))\n  (import \"str\" \"re_named\" (func $host_re_named (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (result (ref null eq))))",
        else: ""
      ),
      if(fs?,
        do:
          "  (import \"fs\" \"read_file\" (func $host_fs_read (param (ref null eq)) (result (ref null eq))))\n  (import \"fs\" \"write_file\" (func $host_fs_write (param (ref null eq)) (param (ref null eq)) (result i32)))",
        else: ""
      ),
      if(sql?,
        do:
          "  (import \"sql\" \"exec\" (func $host_sql_exec (param (ref null eq)) (param (ref null eq)) (result (ref null eq))))",
        else: ""
      ),
      if(io?,
        do:
          "  (import \"io\" \"puts\" (func $host_io_puts (param (ref null eq)) (result i32)))\n  (import \"io\" \"warn\" (func $host_io_warn (param (ref null eq)) (result i32)))",
        else: ""
      ),
      if(uninorm?,
        do:
          Enum.map_join(~w(nfc nfd nfkc nfkd), "\n", fn f ->
            "  (import \"str\" \"#{f}\" (func $host_#{f} (param (ref null eq)) (result (ref null eq))))"
          end),
        else: ""
      ),
      if(fltfmt?,
        do:
          "  (import \"str\" \"flt_fmt\" (func $host_flt_fmt (param f64) (param i32) (param i32) (result (ref null eq))))",
        else: ""
      ),
      if(fltparse?,
        do:
          "  (import \"str\" \"bin_to_float\" (func $host_bin_to_float (param (ref null eq)) (result f64)))",
        else: ""
      ),
      if(titlecase?,
        do:
          "  (import \"str\" \"titlecase\" (func $host_str_titlecase (param (ref null eq)) (result (ref null eq))))\n  (import \"str\" \"upchar\" (func $host_str_upchar (param i32) (result i32)))",
        else: ""
      ),
      if(http_get? or req_in_user,
        do: "  (import \"http\" \"get\" (func $host_http_get (param (ref null eq)) (result (ref null eq))))",
        else: ""
      ),
      if(crypto_hash?,
        do:
          "  (import \"crypto\" \"hash\" (func $host_crypto_hash (param (ref null eq)) (param (ref null eq)) (result (ref null eq))))",
        else: ""
      ),
      # Wasm exception: (class, reason, stacktrace) all as terms. raise/throw/error throw it;
      # a try-containing function's dispatch loop is wrapped in a try_table that catches it.
      if(exc,
        do: "  (tag $exc (export \"exc\") (param (ref null eq)) (param (ref null eq)) (param (ref null eq)))",
        else: ""
      ),
      if(reds, do: "  (global $reds (mut i32) (i32.const #{reds}))", else: ""),
      # make_ref source: a monotonic counter (after imports)
      "  (global $refctr (mut i32) (i32.const 0))",
      # :persistent_term storage (assoc list)
      "  (global $ptermtab (mut (ref null eq)) (ref.null none))",
      # ── terms across the boundary: the host walks a RETURNED TERM GRAPH directly (no
      # serialization inside the module). Complements the is_atom/tup_get/bin_* bridge in
      # helpers(); imports.mjs termToJs() is the generic walker built on these.
      """
        (func (export "head_term") (param $l (ref null eq)) (result (ref null eq))
          (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))
        (func (export "is_map") (param $x (ref null eq)) (result i32) (ref.test (ref $map) (local.get $x)))
        (func (export "map_kv") (param $m (ref null eq)) (result (ref null eq))
          (call $map_kv (local.get $m)))
      """,
      if(bignum,
        do: """
          (func (export "is_int") (param $x (ref null eq)) (result i32)
            (i32.or (i32.or (ref.test (ref i31) (local.get $x)) (ref.test (ref $i64) (local.get $x))) (ref.test (ref $big) (local.get $x))))
          (func (export "int_val") (param $x (ref null eq)) (result externref) (call $to_extbig (local.get $x)))
        """,
        else: """
          (func (export "is_int") (param $x (ref null eq)) (result i32) (ref.test (ref i31) (local.get $x)))
        """
      ),
      if(flt,
        do: """
          (func (export "is_float") (param $x (ref null eq)) (result i32) (ref.test (ref $float) (local.get $x)))
          (func (export "float_val") (param $x (ref null eq)) (result f64) (struct.get $float 0 (ref.cast (ref $float) (local.get $x))))
        """,
        else: "  (func (export \"is_float\") (param $x (ref null eq)) (result i32) (i32.const 0))"
      ),
      if(atom_names?,
        do: """
          (func (export "atom_name") (param $a (ref null eq)) (result (ref null eq))
            (array.get $tuple (call $atomnames_get) (struct.get $atom 0 (ref.cast (ref $atom) (local.get $a)))))
        """,
        else: ""
      ),
      # erlang:monotonic_time source (monotonic, distinct)
      "  (global $monotime (mut i32) (i32.const 0))",
      atom_globals,
      atomname_global,
      # hoisted constant maps/etc., built once as constant-expr globals
      const_globals(),
      if(atom_names?,
        do: """
          (func $erlang.atom_to_binary_1 (param $x (ref null eq)) (result (ref null eq))
            (array.get $tuple (call $atomnames_get) (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x)))))
          (func $erlang.atom_to_binary_2 (param $x (ref null eq)) (param $enc (ref null eq)) (result (ref null eq))
            (return_call $erlang.atom_to_binary_1 (local.get $x)))
          (func $erlang.binary_to_existing_atom_1 (param $b (ref null eq)) (result (ref null eq))
            (local $i i32) (local $n i32)
            (local.set $n (array.len (call $atomnames_get)))
            (block $d (loop $l
              (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
              (if (i32.eqz (call $term_compare (array.get $tuple (call $atomnames_get) (local.get $i)) (local.get $b)))
                (then (return (struct.new $atom (local.get $i)))))
              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))
            (drop (call $erlang.error_1 (global.get $atom_badarg)))
            (unreachable))
          (func $erlang.binary_to_existing_atom_2 (param $b (ref null eq)) (param $enc (ref null eq)) (result (ref null eq))
            (return_call $erlang.binary_to_existing_atom_1 (local.get $b)))
          (func $erlang.list_to_existing_atom_1 (param $l (ref null eq)) (result (ref null eq))
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
            (return_call $erlang.binary_to_existing_atom_1 (struct.new $binary (local.get $d))))\
        """,
        else: ""
      ),
      # float -> text. Parse the opts list to a host-formatter mode: [] -> default 20-digit
      # scientific; :short -> shortest-round-trip Erlang format; {:decimals, D} (+ :compact).
      if(fltfmt?,
        do: """
          (func $erlang.float_to_binary_2 (param $x (ref null eq)) (param $opts (ref null eq)) (result (ref null eq))
            (local $mode i32) (local $dec i32) (local $l (ref null eq)) (local $h (ref null eq)) (local $t (ref $tuple)) (local $compact i32)
            (local.set $mode (i32.const 1))
            (local.set $l (local.get $opts))
            (block $d (loop $lp
              (br_if $d (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (local.set $h (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))
              (if (ref.eq (local.get $h) (global.get $atom_short)) (then (local.set $mode (i32.const 0))))
              (if (ref.eq (local.get $h) (global.get $atom_compact)) (then (local.set $compact (i32.const 1))))
              (if (ref.test (ref $tuple) (local.get $h)) (then
                (local.set $t (ref.cast (ref $tuple) (local.get $h)))
                (if (i32.and (i32.eq (array.len (local.get $t)) (i32.const 2))
                       (ref.eq (array.get $tuple (local.get $t) (i32.const 0)) (global.get $atom_decimals)))
                  (then (local.set $mode (i32.const 2))
                        (local.set $dec (i31.get_s (ref.cast (ref i31) (array.get $tuple (local.get $t) (i32.const 1)))))))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (if (i32.and (i32.eq (local.get $mode) (i32.const 2)) (local.get $compact)) (then (local.set $mode (i32.const 3))))
            (call $host_flt_fmt (struct.get $float 0 (ref.cast (ref $float) (local.get $x))) (local.get $mode) (local.get $dec)))
          (func $erlang.float_to_binary_1 (param $x (ref null eq)) (result (ref null eq))
            (return_call $erlang.float_to_binary_2 (local.get $x) (ref.null none)))
          (func $flt_bin_charlist (param $b (ref null eq)) (result (ref null eq))
            (local $a (ref $bytes)) (local $i i32) (local $out (ref null eq))
            (local.set $a (struct.get $binary 0 (ref.cast (ref $binary) (local.get $b))))
            (local.set $i (array.len (local.get $a)))
            (block $d (loop $l
              (br_if $d (i32.eqz (local.get $i)))
              (local.set $i (i32.sub (local.get $i) (i32.const 1)))
              (local.set $out (struct.new $cons (ref.i31 (array.get_u $bytes (local.get $a) (local.get $i))) (local.get $out)))
              (br $l)))
            (local.get $out))
          (func $erlang.float_to_list_2 (param $x (ref null eq)) (param $opts (ref null eq)) (result (ref null eq))
            (return_call $flt_bin_charlist (call $erlang.float_to_binary_2 (local.get $x) (local.get $opts))))
          (func $erlang.float_to_list_1 (param $x (ref null eq)) (result (ref null eq))
            (return_call $flt_bin_charlist (call $erlang.float_to_binary_2 (local.get $x) (ref.null none))))\
        """,
        else: ""
      ),
      # String.Chars.to_string/1 — the protocol entry for string interpolation `#{x}` and Enum.join.
      # Dispatch on the runtime type to a binary: binaries pass through; integers/atoms convert; nil → "".
      # :string.titlecase(chardata) — titlecase the first character, PRESERVING the input shape:
      #   binary → binary (host upcases first char);  list [cp|rest] → [upper(cp)|rest] (codepoints).
      # String.capitalize passes a list of codepoints and pattern-matches is_integer/is_list on the result.
      if(titlecase?,
        do:
          "      (func $string.titlecase_1 (param $x (ref null eq)) (result (ref null eq))\n" <>
            "        (if (ref.test (ref $binary) (local.get $x)) (then (return (call $host_str_titlecase (local.get $x)))))\n" <>
            "        (if (ref.test (ref $cons) (local.get $x)) (then\n" <>
            "          (if (ref.test (ref i31) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $x)))) (then\n" <>
            "            (return (struct.new $cons (ref.i31 (call $host_str_upchar (i31.get_s (ref.cast (ref i31) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $x))))))) (struct.get $cons 1 (ref.cast (ref $cons) (local.get $x)))))))))\n" <>
            "        (call $host_str_titlecase (call $erlang.iolist_to_binary_1 (local.get $x))))",
        else: ""
      ),
      # :crypto.hash(algo, data) — pass the algorithm NAME (atom→binary via the names table) + data to the
      # host, which runs the real digest (node crypto). Returns the raw digest binary, like OpenSSL.
      if(crypto_hash?,
        do:
          "      (func $crypto.hash_2 (param $algo (ref null eq)) (param $data (ref null eq)) (result (ref null eq))\n        (call $host_crypto_hash (call $erlang.atom_to_binary_1 (local.get $algo)) (local.get $data)))",
        else: ""
      ),
      # Req.get!(url) -> a %Req.Response{} whose body is the host fetch (status 200). The transport is
      # the effect; everything the program does to the body afterward is pure WasmGC.
      if(http_get?,
        do:
          "      (func #{fq(Req, :get!, 1)} (param $url (ref null eq)) (result (ref null eq))\n" <>
            "        (call $map_put (call $map_put (call $map_put (struct.new $map (ref.null $mnode))\n" <>
            "          (global.get $atom_#{sanitize(:__struct__)}) (global.get $atom_#{sanitize(Req.Response)}))\n" <>
            "          (global.get $atom_#{sanitize(:status)}) (ref.i31 (i32.const 200)))\n" <>
            "          (global.get $atom_#{sanitize(:body)}) (call $host_http_get (local.get $url))))",
        else: ""
      ),
      if(to_string?(user),
        do: """
          (func $Elixir_46_String_46_Chars.to_string_1 (param $x (ref null eq)) (result (ref null eq))
            (if (ref.test (ref $binary) (local.get $x)) (then (return (local.get $x))))
            (if #{type_test_i32(:is_integer, "(local.get $x)")} (then (return_call $erlang.integer_to_binary_1 (local.get $x))))
            (if (ref.eq (local.get $x) (global.get $atom_nil)) (then (return (struct.new $binary (array.new_default $bytes (i32.const 0))))))
            (if (ref.test (ref $atom) (local.get $x)) (then (return_call $erlang.atom_to_binary_1 (local.get $x))))
            (unreachable))\
        """,
        else: ""
      ),
      # Shared accessors for the %Regex{} struct: the host shims need BOTH :source and :opts (PCRE
      # modifiers like x/i/m/s — translated host-side to JS RegExp flags/rewrites). :opts may be
      # absent on runtime-built regexes -> empty binary.
      if(fltparse?,
        do: """
          (func $erlang.binary_to_float_1 (param $b (ref null eq)) (result (ref null eq))
            (struct.new $float (call $host_bin_to_float (local.get $b))))
          (func $erlang.list_to_float_1 (param $l (ref null eq)) (result (ref null eq))
            (struct.new $float (call $host_bin_to_float (call $erlang.iolist_to_binary_1 (local.get $l)))))
        """,
        else: ""
      ),
      if(regex_split? or regex_run? or regex_replace3? or regex_more?,
        do: """
          (func $regex_src (param $re (ref null eq)) (result (ref null eq))
            (struct.get $mnode 1 (ref.as_non_null (call $map_get (local.get $re) (global.get $atom_source)))))
          (func $regex_opts (param $re (ref null eq)) (result (ref null eq))
            (local $n (ref null $mnode)) (local $v (ref null eq)) (local $h (ref null eq)) (local $buf (ref $bytes)) (local $len i32) (local $out (ref $bytes)) (local $i i32)
            (local.set $n (call $map_get (local.get $re) (global.get $atom_opts)))
            (if (ref.is_null (local.get $n)) (then (return (struct.new $binary (array.new_default $bytes (i32.const 0))))))
            (local.set $v (struct.get $mnode 1 (ref.as_non_null (local.get $n))))
            (if (ref.test (ref $binary) (local.get $v)) (then (return (local.get $v))))
            ;; Elixir 1.13+ stores opts as a LIST OF ATOMS ([:caseless, :extended, ...]) -> canonical
            ;; single-letter flags binary for the host translator (i m s x u; unknown opts ignored).
            (local.set $buf (array.new_default $bytes (i32.const 8)))
            (block $d (loop $l2
              (br_if $d (i32.eqz (ref.test (ref $cons) (local.get $v))))
              (local.set $h (struct.get $cons 0 (ref.cast (ref $cons) (local.get $v))))
              (if (ref.eq (local.get $h) (global.get $atom_caseless)) (then (array.set $bytes (local.get $buf) (local.get $len) (i32.const 105)) (local.set $len (i32.add (local.get $len) (i32.const 1)))))
              (if (ref.eq (local.get $h) (global.get $atom_multiline)) (then (array.set $bytes (local.get $buf) (local.get $len) (i32.const 109)) (local.set $len (i32.add (local.get $len) (i32.const 1)))))
              (if (ref.eq (local.get $h) (global.get $atom_dotall)) (then (array.set $bytes (local.get $buf) (local.get $len) (i32.const 115)) (local.set $len (i32.add (local.get $len) (i32.const 1)))))
              (if (ref.eq (local.get $h) (global.get $atom_extended)) (then (array.set $bytes (local.get $buf) (local.get $len) (i32.const 120)) (local.set $len (i32.add (local.get $len) (i32.const 1)))))
              (if (ref.eq (local.get $h) (global.get $atom_unicode)) (then (array.set $bytes (local.get $buf) (local.get $len) (i32.const 117)) (local.set $len (i32.add (local.get $len) (i32.const 1)))))
              (local.set $v (struct.get $cons 1 (ref.cast (ref $cons) (local.get $v))))
              (br $l2)))
            (local.set $out (array.new_default $bytes (local.get $len)))
            (block $cd (loop $cl
              (br_if $cd (i32.ge_u (local.get $i) (local.get $len)))
              (array.set $bytes (local.get $out) (local.get $i) (array.get_u $bytes (local.get $buf) (local.get $i)))
              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $cl)))
            (struct.new $binary (local.get $out)))\
        """,
        else: ""
      ),
      # Regex.split(regex, subject, opts) — delegate the match to a host JS RegExp. The host returns a
      # framed binary <<count:32, (len:32, bytes)...>> (big-endian); we slice out each part as a sub-binary
      # and build the list, dropping empty parts when `trim: true` is in opts (Elixir's :trim semantics).
      # `parts:` (the remainder stays unsplit) and `include_captures:` are forwarded to the host.
      if(regex_split?,
        do: """
          (func $Elixir_46_Regex.split_3 (param $re (ref null eq)) (param $subj (ref null eq)) (param $opts (ref null eq)) (result (ref null eq))
            (local $fb (ref $bytes)) (local $cnt i32) (local $off i32) (local $len i32) (local $trim i32) (local $out (ref null eq))
            (local.set $fb (call $bin_bytes (call $host_re_split (call $regex_src (local.get $re)) (call $regex_opts (local.get $re)) (local.get $subj)
              (call $kw_int (local.get $opts) (global.get $atom_parts))
              (call $kw_has_true (local.get $opts) (global.get $atom_include_captures)))))
            (local.set $trim (call $kw_has_true (local.get $opts) (global.get $atom_trim)))
            (local.set $cnt (call $rdu32be (local.get $fb) (i32.const 0)))
            (local.set $off (i32.const 4))
            (block $done (loop $lp
              (br_if $done (i32.eqz (local.get $cnt)))
              (local.set $len (call $rdu32be (local.get $fb) (local.get $off)))
              (local.set $off (i32.add (local.get $off) (i32.const 4)))
              (if (i32.eqz (i32.and (local.get $trim) (i32.eqz (local.get $len))))
                (then (local.set $out (struct.new $cons (call $subbin (local.get $fb) (local.get $off) (local.get $len)) (local.get $out)))))
              (local.set $off (i32.add (local.get $off) (local.get $len)))
              (local.set $cnt (i32.sub (local.get $cnt) (i32.const 1)))
              (br $lp)))
            (return_call $lists.reverse_1 (local.get $out)))
          (func $kw_int (param $l (ref null eq)) (param $key (ref null eq)) (result i32)
            (local $h (ref $tuple))
            (block $d (loop $lp
              (br_if $d (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (if (ref.test (ref $tuple) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))
                (then
                  (local.set $h (ref.cast (ref $tuple) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))))
                  (if (i32.and (i32.ge_u (array.len (local.get $h)) (i32.const 2))
                        (i32.and #{term_eq("(array.get $tuple (local.get $h) (i32.const 0))", "(local.get $key)")}
                                 (ref.test (ref i31) (array.get $tuple (local.get $h) (i32.const 1)))))
                    (then (return (i31.get_s (ref.cast (ref i31) (array.get $tuple (local.get $h) (i32.const 1)))))))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (i32.const 0))
          (func $kw_has_true (param $l (ref null eq)) (param $key (ref null eq)) (result i32)
            (local $h (ref $tuple))
            (block $d (loop $lp
              (br_if $d (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (if (ref.test (ref $tuple) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))
                (then
                  (local.set $h (ref.cast (ref $tuple) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))))
                  (if (i32.and (i32.ge_u (array.len (local.get $h)) (i32.const 2))
                        (i32.and #{term_eq("(array.get $tuple (local.get $h) (i32.const 0))", "(local.get $key)")}
                                 (ref.eq (array.get $tuple (local.get $h) (i32.const 1)) (global.get $atom_true))))
                    (then (return (i32.const 1))))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (i32.const 0))\
        """,
        else: ""
      ),
      # Regex.run(regex, subject) — host JS RegExp `.match`. Frame: <<matched:8, count:32, (len:32, bytes)...>>
      # (a non-participating group has len = 0xFFFFFFFF → nil). matched=0 → the whole call returns nil.
      if(regex_run?,
        do: """
          (func $Elixir_46_Regex.run_2 (param $re (ref null eq)) (param $subj (ref null eq)) (result (ref null eq))
            (local $fb (ref $bytes)) (local $cnt i32) (local $off i32) (local $len i32) (local $out (ref null eq)) (local $item (ref null eq))
            (local.set $fb (call $bin_bytes (call $host_re_run (call $regex_src (local.get $re)) (call $regex_opts (local.get $re)) (local.get $subj))))
            (if (i32.eqz (array.get_u $bytes (local.get $fb) (i32.const 0))) (then (return (global.get $atom_nil))))
            (local.set $cnt (call $rdu32be (local.get $fb) (i32.const 1)))
            (local.set $off (i32.const 5))
            (block $done (loop $lp
              (br_if $done (i32.eqz (local.get $cnt)))
              (local.set $len (call $rdu32be (local.get $fb) (local.get $off)))
              (local.set $off (i32.add (local.get $off) (i32.const 4)))
              (if (i32.eq (local.get $len) (i32.const -1))
                (then (local.set $item (global.get $atom_nil)))
                (else (local.set $item (call $subbin (local.get $fb) (local.get $off) (local.get $len)))
                      (local.set $off (i32.add (local.get $off) (local.get $len)))))
              (local.set $out (struct.new $cons (local.get $item) (local.get $out)))
              (local.set $cnt (i32.sub (local.get $cnt) (i32.const 1)))
              (br $lp)))
            (return_call $lists.reverse_1 (local.get $out)))\
        """,
        else: ""
      ),
      # Regex.run(regex, subject, opts) — only the `return: :index` option differs from run/2: it returns
      # a list of {byte_offset, byte_length} tuples (a non-participating group is {-1, 0}, like :re). Any
      # other opts -> delegate to run/2 (the string form).
      if(regex_run3?,
        do: """
          (func $Elixir_46_Regex.run_3 (param $re (ref null eq)) (param $subj (ref null eq)) (param $opts (ref null eq)) (result (ref null eq))
            (local $fb (ref $bytes)) (local $cnt i32) (local $off i32) (local $o i32) (local $ln i32) (local $idx i32) (local $out (ref null eq)) (local $l (ref null eq)) (local $t (ref $tuple))
            (local.set $l (local.get $opts))
            (block $sd (loop $sl
              (br_if $sd (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (if (ref.test (ref $tuple) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))
                (then (local.set $t (ref.cast (ref $tuple) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))))
                  (if (i32.and (i32.eq (array.len (local.get $t)) (i32.const 2))
                         (i32.and (ref.eq (array.get $tuple (local.get $t) (i32.const 0)) (global.get $atom_return))
                                  (ref.eq (array.get $tuple (local.get $t) (i32.const 1)) (global.get $atom_index))))
                    (then (local.set $idx (i32.const 1))))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $sl)))
            (if (i32.eqz (local.get $idx)) (then (return_call $Elixir_46_Regex.run_2 (local.get $re) (local.get $subj))))
            (local.set $fb (call $bin_bytes (call $host_re_run_index (call $regex_src (local.get $re)) (call $regex_opts (local.get $re)) (local.get $subj))))
            (if (i32.eqz (array.get_u $bytes (local.get $fb) (i32.const 0))) (then (return (global.get $atom_nil))))
            (local.set $cnt (call $rdu32be (local.get $fb) (i32.const 1)))
            (local.set $off (i32.const 5))
            (block $done (loop $lp
              (br_if $done (i32.eqz (local.get $cnt)))
              (local.set $o (call $rdu32be (local.get $fb) (local.get $off)))
              (local.set $ln (call $rdu32be (local.get $fb) (i32.add (local.get $off) (i32.const 4))))
              (local.set $off (i32.add (local.get $off) (i32.const 8)))
              (local.set $out (struct.new $cons (array.new_fixed $tuple 2 (ref.i31 (local.get $o)) (ref.i31 (local.get $ln))) (local.get $out)))
              (local.set $cnt (i32.sub (local.get $cnt) (i32.const 1)))
              (br $lp)))
            (return_call $lists.reverse_1 (local.get $out)))\
        """,
        else: ""
      ),
      # Regex.replace(regex, subject, replacement[, opts]) — STRING replacement via host JS RegExp
      # (Elixir \\N backrefs / \\0 translated to $N / $& host-side); FUNCTION replacement via the host
      # calling back into the exported $re_fun_call, which dispatches on the closure's arity
      # (fn(match) / fn(match, cap1)). opts: only `global: false` changes behavior (default global).
      if(regex_replace3?,
        do: """
          (func $regex_replace_go (param $re (ref null eq)) (param $subj (ref null eq)) (param $repl (ref null eq)) (param $g i32) (result (ref null eq))
            (if (ref.test (ref $fun) (local.get $repl))
              (then (return_call $host_re_replace_fun (call $regex_src (local.get $re)) (call $regex_opts (local.get $re)) (local.get $subj) (local.get $repl) (local.get $g))))
            (return_call $host_re_replace (call $regex_src (local.get $re)) (call $regex_opts (local.get $re)) (local.get $subj) (local.get $repl) (local.get $g)))
          (func $Elixir_46_Regex.replace_3 (param $re (ref null eq)) (param $subj (ref null eq)) (param $repl (ref null eq)) (result (ref null eq))
            (return_call $regex_replace_go (local.get $re) (local.get $subj) (local.get $repl) (i32.const 1)))
          (func $Elixir_46_Regex.replace_4 (param $re (ref null eq)) (param $subj (ref null eq)) (param $repl (ref null eq)) (param $opts (ref null eq)) (result (ref null eq))
            (local $g i32) (local $l (ref null eq)) (local $t (ref $tuple))
            (local.set $g (i32.const 1))
            (local.set $l (local.get $opts))
            (block $sd (loop $sl
              (br_if $sd (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (if (ref.test (ref $tuple) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))
                (then (local.set $t (ref.cast (ref $tuple) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))))
                  (if (i32.and (i32.eq (array.len (local.get $t)) (i32.const 2))
                         (i32.and (ref.eq (array.get $tuple (local.get $t) (i32.const 0)) (global.get $atom_global))
                                  (ref.eq (array.get $tuple (local.get $t) (i32.const 1)) (global.get $atom_false))))
                    (then (local.set $g (i32.const 0))))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $sl)))
            (return_call $regex_replace_go (local.get $re) (local.get $subj) (local.get $repl) (local.get $g)))
          (func $re_fun_call (export "re_fun_call") (param $f (ref null eq)) (param $match (ref null eq)) (param $cap1 (ref null eq)) (param $ncaps i32) (result (ref null eq))
            (local $idx i32)
            (local.set $idx (struct.get $fun 0 (ref.cast (ref $fun) (local.get $f))))
            (if (i32.gt_s (local.get $ncaps) (i32.const 0))
              (then (if (ref.test (ref $clos2) (table.get $ftab (local.get $idx)))
                (then (return (call_indirect $ftab (type $clos2) (local.get $f) (local.get $match) (local.get $cap1) (local.get $idx)))))))
            (call_indirect $ftab (type $clos1) (local.get $f) (local.get $match) (local.get $idx)))\
        """,
        else: ""
      ),
      # match?/2, scan/2, escape/1, split/2, compile/1, compile!/1,2. A "compiled" regex under the
      # host-shim model IS its source: compile! builds %Regex{source: s} (the only field the shims read).
      if(regex_more?,
        do: """
          (func #{fq(Regex, :match?, 2)} (param $re (ref null eq)) (param $subj (ref null eq)) (result (ref null eq))
            (if (result (ref null eq)) (call $host_re_test (call $regex_src (local.get $re)) (call $regex_opts (local.get $re)) (local.get $subj))
              (then (global.get $atom_true)) (else (global.get $atom_false))))
          (func $Elixir_46_Regex.escape_1 (param $s (ref null eq)) (result (ref null eq))
            (return_call $host_re_escape (local.get $s)))
          (func $Elixir_46_Regex.split_2 (param $re (ref null eq)) (param $subj (ref null eq)) (result (ref null eq))
            (return_call $Elixir_46_Regex.split_3 (local.get $re) (local.get $subj) (ref.null none)))
          (func $regex_build (param $s (ref null eq)) (param $o (ref null eq)) (result (ref null eq))
            (call $map_put (call $map_put (call $map_put (struct.new $map (ref.null $mnode))
              (global.get $atom_#{sanitize(:__struct__)}) (global.get $atom_#{sanitize(Regex)}))
              (global.get $atom_source) (local.get $s))
              (global.get $atom_opts) (local.get $o)))
          (func #{fq(Regex, :compile!, 1)} (param $s (ref null eq)) (result (ref null eq))
            (return_call $regex_build (local.get $s) (struct.new $binary (array.new_default $bytes (i32.const 0)))))
          (func #{fq(Regex, :compile!, 2)} (param $s (ref null eq)) (param $opts (ref null eq)) (result (ref null eq))
            (return_call $regex_build (local.get $s) (local.get $opts)))
          (func $Elixir_46_Regex.compile_1 (param $s (ref null eq)) (result (ref null eq))
            (array.new_fixed $tuple 2 (global.get $atom_ok) (call $regex_build (local.get $s) (struct.new $binary (array.new_default $bytes (i32.const 0))))))
          (func $Elixir_46_Regex.scan_2 (param $re (ref null eq)) (param $subj (ref null eq)) (result (ref null eq))
            (local $fb (ref $bytes)) (local $nm i32) (local $nc i32) (local $off i32) (local $len i32) (local $out (ref null eq)) (local $caps (ref null eq))
            (local.set $fb (call $bin_bytes (call $host_re_scan (call $regex_src (local.get $re)) (call $regex_opts (local.get $re)) (local.get $subj))))
            (local.set $nm (call $rdu32be (local.get $fb) (i32.const 0)))
            (local.set $off (i32.const 4))
            (block $md (loop $ml
              (br_if $md (i32.eqz (local.get $nm)))
              (local.set $nc (call $rdu32be (local.get $fb) (local.get $off)))
              (local.set $off (i32.add (local.get $off) (i32.const 4)))
              (local.set $caps (ref.null none))
              (block $cd (loop $cl
                (br_if $cd (i32.eqz (local.get $nc)))
                (local.set $len (call $rdu32be (local.get $fb) (local.get $off)))
                (local.set $off (i32.add (local.get $off) (i32.const 4)))
                (local.set $caps (struct.new $cons (call $subbin (local.get $fb) (local.get $off) (local.get $len)) (local.get $caps)))
                (local.set $off (i32.add (local.get $off) (local.get $len)))
                (local.set $nc (i32.sub (local.get $nc) (i32.const 1)))
                (br $cl)))
              (local.set $out (struct.new $cons (call $lists.reverse_1 (local.get $caps)) (local.get $out)))
              (local.set $nm (i32.sub (local.get $nm) (i32.const 1)))
              (br $ml)))
            (return_call $lists.reverse_1 (local.get $out)))
          (func $Elixir_46_Regex.named_captures_2 (param $re (ref null eq)) (param $subj (ref null eq)) (result (ref null eq))
            ;; host frame: <<matched:8, count:32, (klen:32, k.., vlen:32, v..)*>> -> %{"k" => "v"} | nil
            (local $fb (ref $bytes)) (local $n i32) (local $off i32) (local $len i32) (local $kv (ref null eq)) (local $k (ref null eq))
            (local.set $fb (call $bin_bytes (call $host_re_named (call $regex_src (local.get $re)) (call $regex_opts (local.get $re)) (local.get $subj))))
            (if (i32.eqz (array.get_u $bytes (local.get $fb) (i32.const 0))) (then (return (global.get $atom_nil))))
            (local.set $n (call $rdu32be (local.get $fb) (i32.const 1)))
            (local.set $off (i32.const 5))
            (block $d (loop $lp
              (br_if $d (i32.eqz (local.get $n)))
              (local.set $len (call $rdu32be (local.get $fb) (local.get $off)))
              (local.set $off (i32.add (local.get $off) (i32.const 4)))
              (local.set $k (call $subbin (local.get $fb) (local.get $off) (local.get $len)))
              (local.set $off (i32.add (local.get $off) (local.get $len)))
              (local.set $len (call $rdu32be (local.get $fb) (local.get $off)))
              (local.set $off (i32.add (local.get $off) (i32.const 4)))
              (local.set $kv (struct.new $cons (array.new_fixed $tuple 2 (local.get $k) (call $subbin (local.get $fb) (local.get $off) (local.get $len))) (local.get $kv)))
              (local.set $off (i32.add (local.get $off) (local.get $len)))
              (local.set $n (i32.sub (local.get $n) (i32.const 1)))
              (br $lp)))
            (return_call $maps.from_list_1 (local.get $kv)))\
        """,
        else: ""
      ),
      # String.Unicode.upcase/downcase(string, mode, acc) -> the cased binary (mode/acc ignored: acc=[]
      # at the top-level entry, and the host does the whole string at once). Genuinely table-backed.
      if(strcase?,
        do: """
          (func $Elixir_46_String_46_Unicode.upcase_3 (param $s (ref null eq)) (param $m (ref null eq)) (param $a (ref null eq)) (result (ref null eq))
            (call $host_str_upcase (local.get $s)))
          (func $Elixir_46_String_46_Unicode.downcase_3 (param $s (ref null eq)) (param $m (ref null eq)) (param $a (ref null eq)) (result (ref null eq))
            (call $host_str_downcase (local.get $s)))\
        """,
        else: ""
      ),
      funcs,
      if(proc, do: start_process(mfa?), else: ""),
      # let the host reset a process's reduction budget on each dispatch (preemption)
      if(reds,
        do: "  (func (export \"set_reds\") (param $n i32) (global.set $reds (local.get $n)))",
        else: ""
      ),
      clos_wrappers,
      trampolines,
      builtin_section,
      capture_section,
      apply_section,
      stubs,
      clos_table,
      helpers(),
      if(bignum, do: bignum_helpers(), else: ""),
      if(bignum and Process.get(:float), do: Beam2Wasm.Codegen.Runtime.f64_to_int_helper(), else: ""),
      if(flt, do: float_helpers(user), else: ""),
      exports(mods),
      # data segments registered by big bin_literal/4 during emission
      dataseg_section(),
      ")"
    ]
    |> Enum.join("\n")
  end

  def exports(mods) do
    case Process.get(:exports_spec) do
      nil -> legacy_exports(mods)
      spec -> generic_exports(spec)
    end
  end

  # EXPORTS="name:argtype,argtype->ret; name2:...". Types: int|bin|atom|list|term.
  # Param int -> i32 boxed to i31; param bin/list/term -> (ref null eq) passed through.
  # Return int -> i32; atom -> i32 atom-index (decode via the @atoms table comment);
  # bin/list/term -> (ref null eq) (read via the bin_* / cons bridge helpers).
  def generic_exports(spec) do
    spec
    |> String.split(";", trim: true)
    |> Enum.map_join("\n", fn s ->
      [name, sig] = String.split(s, ":", parts: 2)
      [args_s, ret] = String.split(sig, "->")

      argtypes =
        if String.trim(args_s) == "",
          do: [],
          else: String.split(args_s, ",", trim: true) |> Enum.map(&String.trim/1)

      a = length(argtypes)
      name = String.trim(name)
      ret = String.trim(ret)

      params =
        argtypes
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {t, i} ->
          case t do
            "int" -> "(param $p#{i} f64)"
            "float" -> "(param $p#{i} f64)"
            _ -> "(param $p#{i} (ref null eq))"
          end
        end)

      # int args arrive as f64: a JS Number IS an f64, so the boundary is exact to 2^53 with
      # zero caller ceremony. (An i32 param silently WRAPPED a >2^31 JS Number negative — found
      # by `mix wasm.verify` on its first dogfood run. The ABI must never wrap silently.)
      int_arg = fn i ->
        if Process.get(:bignum),
          do: "(call $narrow (i64.trunc_f64_s (local.get $p#{i})))",
          else: "(ref.i31 (i32.trunc_f64_s (local.get $p#{i})))"
      end

      args =
        argtypes
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {t, i} ->
          case t do
            "int" -> int_arg.(i)
            "float" -> "(struct.new $float (local.get $p#{i}))"
            _ -> "(local.get $p#{i})"
          end
        end)

      call = "(call #{fq(Process.get(:primary_mod), name, a)} #{args})"

      {result, body} =
        case ret do
          # bignum mode: an int result may be a boxed $big, so hand it back as an externref
          # (a JS BigInt on the host side). The driver decodes either via String().
          "int" ->
            if Process.get(:bignum),
              do: {"(result externref)", "(call $to_extbig #{call})"},
              else: {"(result i32)", "(i31.get_s (ref.cast (ref i31) #{call}))"}

          "atom" ->
            {"(result i32)", "(struct.get $atom 0 (ref.cast (ref $atom) #{call}))"}

          "float" ->
            {"(result f64)", "(struct.get $float 0 (ref.cast (ref $float) #{call}))"}

          _ ->
            {"(result (ref null eq))", call}
        end

      "  (func (export \"#{name}\") #{params} #{result}\n    #{body})"
    end)
  end

  def legacy_exports(mods) do
    specs =
      Enum.flat_map(mods, fn m ->
        sp =
          case m do
            Sort -> [{:sort, 1, :list}]
            Expr -> [{:demo, 1, :int}]
            Account -> [{:demo, 1, :int}]
            AccountAbi -> [{:transition_balance, 4, :int}, {:transition_status, 4, :int}]
            Smoke -> [{:add, 2, :int}, {:dbl, 1, :int}, {:fact, 1, :int}, {:fib, 1, :int}]
            Lists -> [{:sumto, 1, :int}]
            _ -> []
          end

        Enum.map(sp, &Tuple.insert_at(&1, 0, m))
      end)

    Enum.map_join(specs, "\n", fn
      {m, n, a, :int} ->
        params = Enum.map_join(0..(a - 1), ") (param ", &"$p#{&1} i32")
        args = Enum.map_join(0..(a - 1), " ", &"(ref.i31 (local.get $p#{&1}))")

        if Process.get(:bignum) do
          "  (func (export \"#{n}\") (param #{params}) (result externref)\n" <>
            "    (call $to_extbig (call #{fq(m, n, a)} #{args})))"
        else
          "  (func (export \"#{n}\") (param #{params}) (result i32)\n" <>
            "    (i31.get_s (ref.cast (ref i31) (call #{fq(m, n, a)} #{args}))))"
        end

      {m, n, 1, :list} ->
        "  (func (export \"#{n}\") (param $l (ref null eq)) (result (ref null eq)) (call #{fq(m, n, 1)} (local.get $l)))"
    end)
  end

  # ---- closed-world protocol consolidation ----
  # An UNconsolidated protocol's impl_for falls back to runtime `Module.concat` +
  # `Code.ensure_compiled` for struct dispatch — dynamic-atom machinery we don't support (and
  # shouldn't: we have whole-program knowledge at compile time). When a fed protocol beam still
  # carries that fallback, consolidate it ourselves against the impls actually fed — exactly what
  # a mix release does — and compile the consolidated binary instead. Already-consolidated beams
  # (e.g. fed from a mix _build/consolidated dir) are detected and passed through untouched.
  def consolidate_protocols(beam_paths) do
    infos =
      Enum.map(beam_paths, fn p ->
        case :beam_lib.chunks(String.to_charlist(p), [:exports]) do
          {:ok, {mod, [exports: exps]}} -> {p, mod, exps}
          _ -> {p, nil, []}
        end
      end)

    impls_by_proto =
      for({_p, mod, exps} <- infos, {:__impl__, 1} in exps, do: mod)
      |> Enum.filter(fn m -> match?({:module, _}, Code.ensure_loaded(m)) end)
      |> Enum.group_by(fn m -> m.__impl__(:protocol) end, fn m -> m.__impl__(:for) end)

    Enum.map(infos, fn {p, mod, exps} ->
      with true <- {:__protocol__, 1} in exps,
           [_ | _] = types <- Map.get(impls_by_proto, mod, []) |> Enum.uniq(),
           true <- unconsolidated?(p),
           {:module, _} <- Code.ensure_loaded(mod),
           {:ok, bin} <- Protocol.consolidate(mod, types) do
        out = Path.join(System.tmp_dir!(), "b2w_consolidated_#{mod}.beam")
        File.write!(out, bin)
        IO.puts(:stderr, "consolidated protocol #{inspect(mod)} (#{length(types)} fed impls)")
        out
      else
        _ -> p
      end
    end)
  end

  # the unconsolidated fallback's signature: some function in the protocol beam (struct_impl_for)
  # calls Module.concat at runtime; a consolidated beam dispatches with direct clauses only.
  defp unconsolidated?(path) do
    {:beam_file, _, _, _, _, fns} = :beam_disasm.file(String.to_charlist(path))

    Enum.any?(fns, fn {:function, _n, _a, _e, is} ->
      Enum.any?(is, fn op ->
        match?({_, _, {:extfunc, Module, :concat, _}}, op) or
          match?({_, _, {:extfunc, Module, :concat, _}, _}, op)
      end)
    end)
  end

  # In STUB mode, a function using a long-tail construct we don't lower yet (try/apply,
  # float arithmetic, odd binary segments) becomes a trap stub instead of failing the build.
  # Only unexercised (non-list-fast-path) Enum functions hit this.
  def safe_compile_fun(mod, {:function, name, arity, _e, _i} = f) do
    # A BIF/NIF we shim by hand (its BEAM body is native, e.g. :lists.reverse/2 = nif_error):
    # skip its BEAM body; the builtin_section emits the shim once.
    if Map.has_key?(builtins(), fq(mod, name, arity)) do
      ""
    else
      try do
        compile_fun(mod, f)
      rescue
        e -> if Process.get(:stub), do: stub_function(mod, name, arity), else: reraise(e, __STACKTRACE__)
      end
    end
  end

  # minimal JSON array-of-strings encoder (no deps) for the @atoms table comment
  def atoms_json(atoms) do
    inner =
      Enum.map_join(atoms, ",", fn a ->
        s =
          Atom.to_string(a)
          |> String.replace("\\", "\\\\")
          |> String.replace("\"", "\\\"")
          # control characters are invalid raw inside JSON strings (atoms like :"\n" exist in stdlib
          # beams) — \u-escape them; the @atoms comment must stay one line, so \n especially.
          |> String.to_charlist()
          |> Enum.map_join(fn c ->
            if c < 0x20, do: "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0"), else: <<c::utf8>>
          end)

        "\"#{s}\""
      end)

    "[#{inner}]"
  end

  # ---- function-level DCE: reachable closure from the exported entry points ----
  def export_seeds(mods) do
    case Process.get(:exports_spec) do
      nil ->
        legacy_seeds(mods)

      spec ->
        pm = Process.get(:primary_mod)

        spec
        |> String.split(";", trim: true)
        |> Enum.map(fn s ->
          [name, sig] = String.split(s, ":", parts: 2)
          [args_s, _ret] = String.split(sig, "->")
          a = if String.trim(args_s) == "", do: 0, else: length(String.split(args_s, ",", trim: true))
          {pm, String.to_atom(String.trim(name)), a}
        end)
    end
  end

  def legacy_seeds(mods) do
    Enum.flat_map(mods, fn m ->
      sp =
        case m do
          Sort -> [{:sort, 1}]
          Expr -> [{:demo, 1}]
          Account -> [{:demo, 1}]
          AccountAbi -> [{:transition_balance, 4}, {:transition_status, 4}]
          Smoke -> [{:add, 2}, {:dbl, 1}, {:fact, 1}, {:fib, 1}]
          Lists -> [{:sumto, 1}]
          _ -> []
        end

      Enum.map(sp, fn {f, a} -> {m, f, a} end)
    end)
  end

  def reachable(user, seeds) do
    by_key = Map.new(user, fn {m, {:function, n, a, _, _} = f} -> {{m, n, a}, f} end)
    by_arity = Map.keys(by_key) |> Enum.group_by(fn {_m, _f, a} -> a end)
    do_reach(seeds, MapSet.new(), by_key, by_arity)
  end

  def do_reach([], seen, _bk, _ba), do: seen

  def do_reach([k | rest], seen, bk, ba) do
    cond do
      MapSet.member?(seen, k) or not Map.has_key?(bk, k) ->
        do_reach(rest, seen, bk, ba)

      true ->
        {:function, _, _, _, is} = Map.fetch!(bk, k)
        # edge_refs covers direct/ext calls + make_fun3; literal_funs_in covers CAPTURED funs
        # (`&Mod.f/a`, `&abs/1`) which the BEAM stores as constant fun values — also roots, else
        # their target bodies get pruned and the apply/trampoline dispatch falls to (unreachable).
        targets =
          if k in [{Req.Finch, :run, 1}],
            # Req.Finch.run/1 is overridden (the adapter) → a leaf, so the ssl/inet/pool subtree is pruned
            do: [],
            else: Enum.flat_map(is, &edge_refs/1) ++ Enum.flat_map(is, &literal_funs_in/1)

        # erlang:spawn_opt / apply / spawn(M,F,A) dispatch on a RUNTIME M:F/A, which DCE can't trace —
        # so any function could be the target. Keep them all (correct; defeats pruning for such modules).
        extra =
          if Enum.any?(is, &wild_dispatch?/1),
            do: Map.keys(bk),
            else: apply_targets(is, ba)

        do_reach(targets ++ extra ++ rest, MapSet.put(seen, k), bk, ba)
    end
  end

  # DCE targets of the BEAM `apply` instruction. `{:apply, n}` calls a function of arity n with the
  # module in x[n] and the function NAME in x[n+1]. When that name is a compile-time-constant atom
  # (the common case: Enumerable protocol dispatch moves `:reduce` into x[n+1]; GenServer moves
  # `:handle_call` etc.), only arity-n functions WITH THAT NAME can be the runtime target — so keep
  # just those, not every arity-n function (which would drag in unrelated dead code like Float.round/3).
  # If the name is set non-constantly (truly dynamic), fall back to keeping all arity-n (sound).
  def apply_targets(is, ba) do
    arities =
      Enum.flat_map(is, fn
        {:apply, n} -> [n]
        {:apply_last, n, _} -> [n]
        _ -> []
      end)
      |> Enum.uniq()

    Enum.flat_map(arities, fn n ->
      case reg_const_atoms(is, n + 1) do
        {names, true} when names != [] -> Enum.filter(Map.get(ba, n, []), fn {_m, f, _a} -> f in names end)
        _ -> Map.get(ba, n, [])
      end
    end)
  end

  # Inspect every WRITE to register x[k] in a function body. Returns {constant_atoms_written, all_const?}
  # where all_const? is true iff EVERY writer of x[k] is a move of a constant atom. Conservative: any
  # non-move writer (call result, bif dst, …) or a move from a non-atom source ⇒ all_const? = false.
  def reg_const_atoms(is, k) do
    writes = Enum.flat_map(is, &reg_writes/1) |> Enum.filter(fn {reg, _} -> reg == {:x, k} end)
    atoms = for {_reg, {:const_atom, a}} <- writes, do: a
    all_const? = writes != [] and Enum.all?(writes, fn {_reg, src} -> match?({:const_atom, _}, src) end)
    {Enum.uniq(atoms), all_const?}
  end

  # {dest_reg, source} for instructions that write a register; source is {:const_atom, a} or :other.
  def reg_writes({:move, {:atom, a}, {:x, _} = d}), do: [{d, {:const_atom, a}}]
  def reg_writes({:move, {:literal, a}, {:x, _} = d}) when is_atom(a), do: [{d, {:const_atom, a}}]
  def reg_writes({:move, _src, {:x, _} = d}), do: [{d, :other}]
  def reg_writes({:bif, _, _, _, {:x, _} = d}), do: [{d, :other}]
  def reg_writes({:gc_bif, _, _, _, _, {:x, _} = d}), do: [{d, :other}]
  def reg_writes({:get_tuple_element, _, _, {:x, _} = d}), do: [{d, :other}]
  # dests are inside the list; treat as :other below
  def reg_writes({:get_map_elements, _, _, {:list, _}} = _op), do: []

  def reg_writes(op) when is_tuple(op) do
    # any other op that names x[k] as its LAST element (the conventional dst slot) writes it non-constantly
    case :erlang.tuple_to_list(op) |> List.last() do
      {:x, _} = d -> [{d, :other}]
      _ -> []
    end
  end

  def reg_writes(_), do: []

  def edge_refs({:call, _, {m, f, a}}), do: [{m, f, a}]
  def edge_refs({:call_only, _, {m, f, a}}), do: [{m, f, a}]
  def edge_refs({:call_last, _, {m, f, a}, _}), do: [{m, f, a}]
  def edge_refs({:call_ext, _, {:extfunc, m, f, a}}), do: [{m, f, a}]
  def edge_refs({:call_ext_only, _, {:extfunc, m, f, a}}), do: [{m, f, a}]
  def edge_refs({:call_ext_last, _, {:extfunc, m, f, a}, _}), do: [{m, f, a}]
  def edge_refs({:make_fun3, {m, fun, arity}, _, _, _, _}), do: [{m, fun, arity}]
  def edge_refs(_), do: []
  # a call dispatching on a runtime M:F/A — DCE must keep all functions as potential targets
  def wild_dispatch?({_, _, {:extfunc, :erlang, f, _}}) when f in [:spawn_opt, :apply, :spawn], do: true
  def wild_dispatch?({_, _, {:extfunc, :erlang, f, _}, _}) when f in [:spawn_opt, :apply, :spawn], do: true
  def wild_dispatch?(_), do: false

  # processes present? (spawn/send/self/receive). Enables the proc imports + scheduler glue.
  def proc_mode?(user) do
    Enum.any?(user, fn {_m, {:function, _, _, _, is}} -> Enum.any?(is, &proc_op?/1) end)
  end

  def proc_op?({:call_ext, _, {:extfunc, :erlang, :spawn, _}}), do: true
  def proc_op?({:call_ext, _, {:extfunc, :erlang, :spawn_link, _}}), do: true
  def proc_op?({:call_ext, _, {:extfunc, :erlang, :send, 2}}), do: true
  def proc_op?({:bif, :self, _, _, _}), do: true
  def proc_op?({:loop_rec, _, _}), do: true
  def proc_op?(:remove_message), do: true
  def proc_op?({:wait, _}), do: true
  def proc_op?(_), do: false

  # exceptions present? (try/catch/raise) -> emit the $exc tag + wrap try-functions in try_table
  def exc_mode?(user) do
    Enum.any?(user, fn {_m, {:function, _, _, _, is}} -> Enum.any?(is, &exc_op?/1) end)
  end

  def exc_op?({:try, _, _}), do: true
  def exc_op?({:try_case, _}), do: true
  def exc_op?({:catch, _, _}), do: true
  def exc_op?({:catch_end, _}), do: true
  def exc_op?({ce, _, {:extfunc, :erlang, :throw, 1}}) when ce in [:call_ext, :call_ext_only], do: true
  def exc_op?({:call_ext_last, _, {:extfunc, :erlang, :throw, 1}, _}), do: true
  def exc_op?({ce, _, {:extfunc, :erlang, :error, _}}) when ce in [:call_ext, :call_ext_only], do: true
  def exc_op?({:call_ext_last, _, {:extfunc, :erlang, :error, _}, _}), do: true
  def exc_op?({:bif, :raise, _, _, _}), do: true
  def exc_op?(_), do: false

  # ---- floats: f64 register file + boxed $float term + :math.* via host imports ----
  # Unary :math functions that map 1:1 onto a host (JS Math) call of the same name; plus the
  # two binary ones. pi/0 is inlined by the Elixir compiler to a float literal, so never called.
  @math_unary [
    :sin,
    :cos,
    :tan,
    :asin,
    :acos,
    :atan,
    :sqrt,
    :exp,
    :log,
    :log2,
    :log10,
    :sinh,
    :cosh,
    :tanh,
    :ceil,
    :floor
  ]
  @math_binary [:atan2, :pow]
  def float_mode?(user) do
    Enum.any?(user, fn {_m, {:function, _, _, _, is}} -> Enum.any?(is, &float_op?/1) end)
  end

  def float_op?({:fconv, _, _}), do: true
  def float_op?({:fmove, _, _}), do: true
  def float_op?({:bif, op, _, _, _}) when op in [:fadd, :fsub, :fmul, :fdiv], do: true
  def float_op?({:call_ext, _, {:extfunc, :math, _, _}}), do: true
  def float_op?({:call_ext_only, _, {:extfunc, :math, _, _}}), do: true
  def float_op?({:call_ext_last, _, {:extfunc, :math, _, _}, _}), do: true
  def float_op?({:literal, t}), do: has_float_literal?(t)
  # a bare float literal operand (e.g. {:float, 0.25}) → float mode
  def float_op?(f) when is_float(f), do: true
  def float_op?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&float_op?/1)
  def float_op?(l) when is_list(l), do: Enum.any?(l, &float_op?/1)
  def float_op?(_), do: false

  def has_float_literal?(f) when is_float(f), do: true
  def has_float_literal?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&has_float_literal?/1)
  def has_float_literal?(l) when is_list(l), do: Enum.any?(l, &has_float_literal?/1)
  def has_float_literal?(m) when is_map(m), do: Enum.any?(Map.to_list(m), &has_float_literal?/1)
  def has_float_literal?(_), do: false
  # the :math functions actually called, that we know how to lower
  def math_funs_used(user) do
    known = (Enum.map(@math_unary, &{&1, 1}) ++ Enum.map(@math_binary, &{&1, 2})) |> MapSet.new()

    user
    |> Enum.flat_map(fn {_m, {:function, _, _, _, is}} -> is end)
    |> Enum.flat_map(fn
      {ce, _, {:extfunc, :math, f, a}} when ce in [:call_ext, :call_ext_only] -> [{:math, f, a}]
      {:call_ext_last, _, {:extfunc, :math, f, a}, _} -> [{:math, f, a}]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.filter(fn {:math, f, a} -> MapSet.member?(known, {f, a}) end)
  end

  def float_imports(user) do
    math_funs_used(user)
    |> Enum.map_join("\n", fn {:math, f, a} ->
      ps = String.duplicate(" f64", a)
      "  (import \"math\" \"#{f}\" (func $math_host_#{f} (param#{ps}) (result f64)))"
    end)
  end

  def float_helpers(user) do
    # term -> f64: i31 converts; $float unboxes; in bignum mode an $i64 box converts natively and a
    # true bignum goes through the host (Number(BigInt) — lossy past 2^53, like the BEAM).
    to_f64 =
      """
        (func $to_f64 (param $x (ref null eq)) (result f64)
          (if (result f64) (ref.test (ref i31) (local.get $x))
            (then (f64.convert_i32_s (i31.get_s (ref.cast (ref i31) (local.get $x)))))
            (else (if (result f64) (ref.test (ref $float) (local.get $x))
              (then (struct.get $float 0 (ref.cast (ref $float) (local.get $x))))#{if Process.get(:bignum),
        do: "
              (else (if (result f64) (call $is_i64rep (local.get $x))
                (then (f64.convert_i64_s (call $as_i64 (local.get $x))))
                (else (call $bigint_to_f64 (call $to_big (local.get $x))))))",
        else: "
              (else (f64.const 0))"}))))\
      """

    shims =
      math_funs_used(user)
      |> Enum.map_join("\n", fn {:math, f, a} ->
        params = Enum.map_join(0..(a - 1), " ", &"(param $a#{&1} (ref null eq))")
        callargs = Enum.map_join(0..(a - 1), " ", &"(call $to_f64 (local.get $a#{&1}))")

        "  (func #{fq(:math, f, a)} #{params} (result (ref null eq))\n" <>
          "    (struct.new $float (call $math_host_#{f} #{callargs})))"
      end)

    # the Erlang number tower for +/-/*: if either operand is a float, the result is a float;
    # otherwise integer. (BEAM emits a generic `gc_bif :+/:-/:*` on `t_number` operands which at
    # runtime may be either — e.g. `lat2 - lat1` on float args.)
    num =
      ["add", "sub", "mul"]
      |> Enum.map_join("\n", fn o ->
        """
          (func $num_#{o} (param $a (ref null eq)) (param $b (ref null eq)) (result (ref null eq))
            (if (result (ref null eq)) (i32.or (ref.test (ref $float) (local.get $a)) (ref.test (ref $float) (local.get $b)))
              (then (struct.new $float (f64.#{o} (call $to_f64 (local.get $a)) (call $to_f64 (local.get $b)))))
              ;; integer path: delegate to the tiered int helper (i31 fast path + i64 + bignum,
              ;; with overflow promotion). Must NOT inline an i31 cast — operands may be boxed
              ;; bignums (illegal cast) and i31+i31 can overflow (silent wrap). See fuzz/.
              (else (call $int_#{o} (local.get $a) (local.get $b)))))\
        """
      end)

    to_f64 <> "\n" <> num <> "\n" <> shims
  end

  # The host owns the scheduler (process table, mailboxes, ready queue). The compiler emits
  # calls to these imports; recv_wait is the JSPI suspend point. Pids cross as i32 (boxed to
  # i31 on the Wasm side); messages cross as opaque eq-refs round-tripped through JS.
  def proc_imports do
    """
      (import "proc" "spawn"        (func $spawn_raw (param (ref null eq)) (result i32)))
      (import "proc" "send"         (func $send_raw (param i32) (param (ref null eq)) (result (ref null eq))))
      (import "proc" "self"         (func $self_raw (result i32)))
      (import "proc" "recv_has"     (func $recv_has (result i32)))
      (import "proc" "recv_cur"     (func $recv_cur (result (ref null eq))))
      (import "proc" "recv_remove"  (func $recv_remove))
      (import "proc" "recv_advance" (func $recv_advance))
      (import "proc" "recv_wait"    (func $recv_wait))
      (import "proc" "recv_wait_timeout" (func $recv_wait_timeout (param i32) (result i32)))
      (import "proc" "spawn_link"   (func $spawn_link_raw (param (ref null eq)) (result i32)))
      (import "proc" "exit"         (func $exit_raw (param (ref null eq))))
      (import "proc" "exit2"        (func $exit2_raw (param i32) (param (ref null eq))))
      (import "proc" "set_trap_exit" (func $set_trap_exit (param i32)))
      (import "proc" "register"     (func $register_raw (param i32) (param i32)))
      (import "proc" "whereis"      (func $whereis_raw (param i32) (result i32)))
      (import "proc" "monitor"      (func $monitor_raw (param i32) (result i32)))
      (import "proc" "pdict_get"    (func $pdict_get (param (ref null eq)) (result (ref null eq))))
      (import "proc" "pdict_put"    (func $pdict_put (param (ref null eq)) (param (ref null eq)) (result (ref null eq))))
      (import "proc" "spawn_opt"    (func $spawn_opt_raw (param (ref null eq)) (param (ref null eq)) (param (ref null eq)) (param i32) (result i32)))
      (import "proc" "demonitor"    (func $demonitor_raw (param i32)))
      (import "proc" "alias_pid"    (func $alias_pid (param i32) (result i32)))\
    """
  end

  # Entry the host calls (on a JSPI promising stack) to run a spawned 0-arg closure, plus
  # constructors the host uses to build exit signals (atoms live in Wasm, not JS).
  def start_process(mfa?) do
    mfa_helpers =
      if mfa? do
        """
          ;; MFA process entry: run apply(M, F, Args). Args is a proper list; dispatch on its length.
          (func (export "start_mfa") (param $m (ref null eq)) (param $f (ref null eq)) (param $a (ref null eq)) (result (ref null eq))
            (return_call $erlang_apply_3 (local.get $m) (local.get $f) (local.get $a)))
          ;; apply(M, F, ArgsList): unpack up to 8 args from the list and tail-call the right apply_N.
          (func $erlang_apply_3 (param $m (ref null eq)) (param $f (ref null eq)) (param $a (ref null eq)) (result (ref null eq))
            (local $n i32) (local $l (ref null eq))
            (local $a0 (ref null eq)) (local $a1 (ref null eq)) (local $a2 (ref null eq)) (local $a3 (ref null eq))
            (local $a4 (ref null eq)) (local $a5 (ref null eq)) (local $a6 (ref null eq)) (local $a7 (ref null eq))
            (local.set $n (call $list_len (local.get $a)))
            (local.set $l (local.get $a))
            (if (i32.ge_s (local.get $n) (i32.const 1)) (then (local.set $a0 (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))) (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))))
            (if (i32.ge_s (local.get $n) (i32.const 2)) (then (local.set $a1 (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))) (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))))
            (if (i32.ge_s (local.get $n) (i32.const 3)) (then (local.set $a2 (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))) (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))))
            (if (i32.ge_s (local.get $n) (i32.const 4)) (then (local.set $a3 (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))) (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))))
            (if (i32.ge_s (local.get $n) (i32.const 5)) (then (local.set $a4 (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))) (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))))
            (if (i32.ge_s (local.get $n) (i32.const 6)) (then (local.set $a5 (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))) (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))))
            (if (i32.ge_s (local.get $n) (i32.const 7)) (then (local.set $a6 (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))) (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))))
            (if (i32.ge_s (local.get $n) (i32.const 8)) (then (local.set $a7 (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l)))) (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))))
            (if (i32.eq (local.get $n) (i32.const 0)) (then (return_call $apply_0 (local.get $m) (local.get $f))))
            (if (i32.eq (local.get $n) (i32.const 1)) (then (return_call $apply_1 (local.get $a0) (local.get $m) (local.get $f))))
            (if (i32.eq (local.get $n) (i32.const 2)) (then (return_call $apply_2 (local.get $a0) (local.get $a1) (local.get $m) (local.get $f))))
            (if (i32.eq (local.get $n) (i32.const 3)) (then (return_call $apply_3 (local.get $a0) (local.get $a1) (local.get $a2) (local.get $m) (local.get $f))))
            (if (i32.eq (local.get $n) (i32.const 4)) (then (return_call $apply_4 (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $m) (local.get $f))))
            (if (i32.eq (local.get $n) (i32.const 5)) (then (return_call $apply_5 (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $a4) (local.get $m) (local.get $f))))
            (if (i32.eq (local.get $n) (i32.const 6)) (then (return_call $apply_6 (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $a4) (local.get $a5) (local.get $m) (local.get $f))))
            (if (i32.eq (local.get $n) (i32.const 7)) (then (return_call $apply_7 (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $a4) (local.get $a5) (local.get $a6) (local.get $m) (local.get $f))))
            (if (i32.eq (local.get $n) (i32.const 8)) (then (return_call $apply_8 (local.get $a0) (local.get $a1) (local.get $a2) (local.get $a3) (local.get $a4) (local.get $a5) (local.get $a6) (local.get $a7) (local.get $m) (local.get $f))))
            (unreachable))\
        """
      else
        ""
      end

    """
      (func (export "start_process") (param $f (ref null eq)) (result (ref null eq))
        (call_indirect $ftab (type $clos0) (local.get $f) (struct.get $fun 0 (ref.cast (ref $fun) (local.get $f)))))
    #{mfa_helpers}
      (func (export "make_exit") (param $pid i32) (param $reason (ref null eq)) (result (ref null eq))
        (array.new_fixed $tuple 3 (global.get $atom_EXIT) (struct.new $pid (local.get $pid)) (local.get $reason)))
      (func (export "make_down") (param $ref i32) (param $pid i32) (param $reason (ref null eq)) (result (ref null eq))
        (array.new_fixed $tuple 5 (global.get $atom_DOWN) (struct.new $ref (local.get $ref) (i32.const 0)) (global.get $atom_process) (struct.new $pid (local.get $pid)) (local.get $reason)))
      (func (export "get_normal") (result (ref null eq)) (global.get $atom_normal))
      ;; send dest may be a $pid, a monitor-alias $ref (gen:reply uses one), or a registered name
      ;; (atom) -> resolve to a raw pid id.
      (func $resolve_dest (param $d (ref null eq)) (result i32)
        (if (ref.test (ref $pid) (local.get $d)) (then (return (struct.get $pid 0 (ref.cast (ref $pid) (local.get $d))))))
        (if (ref.test (ref $ref) (local.get $d)) (then (return (call $alias_pid (struct.get $ref 0 (ref.cast (ref $ref) (local.get $d)))))))
        (call $whereis_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $d)))))\
    """
  end

  # closures: every make_fun3 target as {mod, fun, total_arity, num_free_vars}, unique
  def collect_closures(user) do
    user
    |> Enum.flat_map(fn {_mod, {:function, _, _, _, is}} -> Enum.flat_map(is, &make_fun_refs/1) end)
    |> Enum.uniq()
  end

  def make_fun_refs({:make_fun3, {m, fun, arity}, _i, _h, _d, {:list, free}}),
    do: [{m, fun, arity, length(free)}]

  def make_fun_refs(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&make_fun_refs/1)
  def make_fun_refs(l) when is_list(l), do: Enum.flat_map(l, &make_fun_refs/1)
  def make_fun_refs(_), do: []

  def collect_literal_funs(user) do
    user
    |> Enum.flat_map(fn {_mod, {:function, _, _, _, is}} -> Enum.flat_map(is, &literal_funs_in/1) end)
    |> Enum.uniq()
  end

  # is String.Chars.to_string/1 (string interpolation `#{}` + Enum.join element conversion) reachable?
  def to_string?(user) do
    # only shim when the real String.Chars protocol isn't compiled in (else its body wins).
    not Enum.any?(user, fn {m, _} -> m == String.Chars end) and
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, String.Chars, :to_string, 1}}, op) or
            match?({_, _, {:extfunc, String.Chars, :to_string, 1}, _}, op)
        end)
      end)
  end

  def literal_funs_in({:literal, f}) when is_function(f), do: literal_funs_in(f)

  def literal_funs_in(f) when is_function(f) do
    info = :erlang.fun_info(f)
    [{Keyword.fetch!(info, :module), Keyword.fetch!(info, :name), Keyword.fetch!(info, :arity)}]
  end

  def literal_funs_in(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&literal_funs_in/1)
  def literal_funs_in(l) when is_list(l), do: Enum.flat_map(l, &literal_funs_in/1)
  # a fun can be nested inside a constant MAP value (e.g. Logger metadata `%{report_cb: &format_report/1}`);
  # recurse so its name atom is interned (materialize references $atom_<name>) and it's a DCE root.
  def literal_funs_in(m) when is_map(m),
    do: Map.to_list(m) |> Enum.flat_map(fn {k, v} -> literal_funs_in(k) ++ literal_funs_in(v) end)

  def literal_funs_in(_), do: []

  # A captured ext fun (e.g. `&abs/1`, `&band/2`) is an Erlang BIF lowered INLINE — it has no
  # standalone function the apply/trampoline path can tail-call. For each such captured MFA that is
  # neither a user function nor an existing builtin shim, synthesize a wrapper $Mod.fun_arity whose
  # body is the same mode-aware expression the inline lowering uses. (Used both as a callable target
  # and as an apply_N clause; see captured_ext_targets/1.)
  def captured_ext_targets(user) do
    defined = MapSet.new(user, fn {m, {:function, n, a, _, _}} -> {m, n, a} end)
    bkeys = MapSet.new(Map.keys(builtins()))

    collect_literal_funs(user)
    |> Enum.uniq()
    |> Enum.reject(fn {m, f, a} ->
      MapSet.member?(defined, {m, f, a}) or MapSet.member?(bkeys, fq(m, f, a))
    end)
    |> Enum.filter(fn mfa -> capture_wrap_body(mfa) != nil end)
  end

  def capture_wrappers(user) do
    captured_ext_targets(user)
    |> Enum.map_join("\n", fn {m, f, a} ->
      ps = if a == 0, do: "", else: " " <> Enum.map_join(0..(a - 1), " ", &"(param $x#{&1} (ref null eq))")
      "  (func #{fq(m, f, a)}#{ps} (result (ref null eq))\n    (return #{capture_wrap_body({m, f, a})}))"
    end)
  end

  # mode-aware body for a capturable inline BIF (mirrors the {:bif,...}/{:gc_bif,...} lowering); nil = unsupported.
  def x(n), do: "(local.get $x#{n})"
  def xi31(n), do: "(i31.get_s (ref.cast (ref i31) (local.get $x#{n})))"

  def capture_wrap_body({:erlang, :abs, 1}) do
    if Process.get(:bignum),
      do:
        "(if (result (ref null eq)) (i32.lt_s (call $int_cmp #{x(0)} (ref.i31 (i32.const 0))) (i32.const 0)) (then (call $int_sub (ref.i31 (i32.const 0)) #{x(0)})) (else #{x(0)}))",
      else:
        "(ref.i31 (select (i32.sub (i32.const 0) #{xi31(0)}) #{xi31(0)} (i32.lt_s #{xi31(0)} (i32.const 0))))"
  end

  def capture_wrap_body({:erlang, :byte_size, 1}),
    do: "(ref.i31 (array.len (struct.get $binary 0 (ref.cast (ref $binary) #{x(0)}))))"

  def capture_wrap_body({:erlang, :bit_size, 1}),
    do:
      "(ref.i31 (i32.shl (array.len (struct.get $binary 0 (ref.cast (ref $binary) #{x(0)}))) (i32.const 3)))"

  def capture_wrap_body({:erlang, :map_size, 1}), do: "(ref.i31 (call $map_size #{x(0)}))"

  def capture_wrap_body({:erlang, :tuple_size, 1}),
    do: "(ref.i31 (array.len (ref.cast (ref $tuple) #{x(0)})))"

  def capture_wrap_body({:erlang, :length, 1}), do: "(ref.i31 (call $list_len #{x(0)}))"
  def capture_wrap_body({:erlang, :hd, 1}), do: "(struct.get $cons 0 (ref.cast (ref $cons) #{x(0)}))"
  def capture_wrap_body({:erlang, :tl, 1}), do: "(struct.get $cons 1 (ref.cast (ref $cons) #{x(0)}))"

  def capture_wrap_body({:erlang, op, 2}) when op in [:band, :bor, :bxor, :bsl, :bsr] do
    cond do
      Process.get(:bignum) ->
        "(call $int_#{op} #{x(0)} #{x(1)})"

      op in [:band, :bor, :bxor] ->
        "(ref.i31 (i32.#{wasmop(op)} #{xi31(0)} #{xi31(1)}))"

      true ->
        "(ref.i31 (i32.wrap_i64 (i64.#{wasmop(op)} (i64.extend_i32_s #{xi31(0)}) (i64.extend_i32_s #{xi31(1)}))))"
    end
  end

  # comparison operators captured as funs (Enum.max/min/sort default comparators): &>=/2, &</2, …
  def capture_wrap_body({:erlang, op, 2}) when op in [:"=:=", :==, :"=/=", :"/=", :<, :>, :>=, :"=<"] do
    "(if (result (ref null eq)) #{bool_cmp(op, {:x, 0}, {:x, 1})} (then (global.get $atom_true)) (else (global.get $atom_false)))"
  end

  # arithmetic operators captured as funs (Enum.sum/product default reducers): &+/2, &*/2, …
  def capture_wrap_body({:erlang, op, 2}) when op in [:+, :-, :*, :div, :rem] do
    cond do
      Process.get(:float) and op in [:+, :-, :*] -> "(call $num_#{bif(op)} #{x(0)} #{x(1)})"
      Process.get(:bignum) -> "(call $int_#{bif(op)} #{x(0)} #{x(1)})"
      true -> "(ref.i31 (i32.#{wasmop(op)} #{xi31(0)} #{xi31(1)}))"
    end
  end

  # type-test BIFs captured as predicates (&is_list/1 — Stream/zip uses it via :lists.all): atom true/false
  def capture_wrap_body({:erlang, tb, 1})
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
           ] do
    "(if (result (ref null eq)) #{type_test_i32(tb, x(0))} (then (global.get $atom_true)) (else (global.get $atom_false)))"
  end

  def capture_wrap_body(_), do: nil

  # every {mod, fun, arity} reached by a direct/external call (for auto-stubbing undefined fns)
  def called_funs(user) do
    user
    |> Enum.flat_map(fn {_mod, {:function, _, _, _, is}} -> Enum.flat_map(is, &call_refs/1) end)
    |> Enum.uniq()
  end

  def call_refs({:call, _, {m, f, a}}), do: [{m, f, a}]
  def call_refs({:call_only, _, {m, f, a}}), do: [{m, f, a}]
  def call_refs({:call_last, _, {m, f, a}, _}), do: [{m, f, a}]
  def call_refs({:call_ext, _, {:extfunc, m, f, a}}), do: [{m, f, a}]
  def call_refs({:call_ext_only, _, {:extfunc, m, f, a}}), do: [{m, f, a}]
  def call_refs({:call_ext_last, _, {:extfunc, m, f, a}, _}), do: [{m, f, a}]
  def call_refs(_), do: []

  # arities used by apply/apply_last -> need a generated $apply_N dispatch
  def apply_arities(user) do
    used =
      user
      |> Enum.flat_map(fn {_m, {:function, _, _, _, is}} ->
        Enum.flat_map(is, fn
          {:apply, n} -> [n]
          {:apply_last, n, _} -> [n]
          _ -> []
        end)
      end)

    # MFA spawn (spawn_opt/4) runs procs via the generic apply/3, which dispatches into apply_0..apply_8;
    # force those arities so the dispatch targets exist.
    # spawn_opt/apply (MFA) and make_fun trampolines both dispatch into apply_0..apply_8.
    wild? =
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, :erlang, f, _}} when f in [:spawn_opt, :apply, :make_fun, :hibernate], op) or
            match?(
              {_, _, {:extfunc, :erlang, f, _}, _} when f in [:spawn_opt, :apply, :make_fun, :hibernate],
              op
            )
        end)
      end)

    (used ++ if(wild? or collect_literal_funs(user) != [], do: Enum.to_list(0..8), else: [])) |> Enum.uniq()
  end

  # $apply_N(args…, mod, fun): dispatch on (mod, fun) over every closed-world function of arity N
  # and tail-call it. Closed-world makes this exhaustive. Instead of a linear scan (O(functions) —
  # 339 clauses for Jason's arity-2 protocol dispatch, on the hot path per encoded value), we form
  # an i64 key = mod_idx*MUL + fun_idx from the interned atom indices and BINARY-SEARCH it: ~log2(N)
  # comparisons. Unknown pair falls through to unreachable.
  def gen_apply(n, user) do
    params =
      if(n == 0, do: "", else: " " <> Enum.map_join(0..(n - 1), " ", &"(param $a#{&1} (ref null eq))")) <>
        " (param $mod (ref null eq)) (param $fun (ref null eq))"

    args = if n == 0, do: "", else: " " <> Enum.map_join(0..(n - 1), " ", &"(local.get $a#{&1})")
    aidx = Process.get(:atom_idx)
    mul = 1_000_000
    # exclude pure lambdas — they have the (self, args…) closure signature, not the normal one
    # only functions whose (mod, fun) atoms are interned can be named as an apply target
    clauses =
      ((user
        |> Enum.filter(fn {_m, {:function, _nm, ar, _, _}} -> ar == n end)
        |> Enum.reject(fn {m, {:function, nm, ar, _, _}} ->
          cl = Process.get(:closures, %{}) |> Map.get({m, nm, ar})
          cl != nil and not cl.dual
        end)
        |> Enum.filter(fn {m, {:function, nm, _, _, _}} ->
          Map.has_key?(aidx, m) and Map.has_key?(aidx, nm)
        end)
        |> Enum.map(fn {m, {:function, nm, _, _, _}} ->
          {Map.fetch!(aidx, m) * mul + Map.fetch!(aidx, nm), "(return_call #{fq(m, nm, n)}#{args})"}
        end)) ++ helper_apply_clauses(n, aidx, mul, args) ++ ext_capture_clauses(n, user, aidx, mul, args))
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort_by(&elem(&1, 0))

    keyset =
      "    (local.set $key (i64.add (i64.mul (i64.extend_i32_u (struct.get $atom 0 (ref.cast (ref $atom) (local.get $mod)))) (i64.const #{mul})) (i64.extend_i32_u (struct.get $atom 0 (ref.cast (ref $atom) (local.get $fun))))))"

    "  (func $apply_#{n}#{params} (result (ref null eq)) (local $key i64)\n#{keyset}\n#{bisect_apply(clauses)}\n" <>
      "    (drop (call $erlang.error_1 (array.new_fixed $tuple 3 (global.get $atom_undef) (local.get $mod) (local.get $fun))))\n    (unreachable))"
  end

  # balanced binary-search tree over sorted {key, call} clauses; each leaf is an exact-key guard.
  def bisect_apply([]), do: ""
  def bisect_apply([{k, call}]), do: "    (if (i64.eq (local.get $key) (i64.const #{k})) (then #{call}))"

  def bisect_apply(clauses) do
    mid = div(length(clauses), 2)
    {left, right} = Enum.split(clauses, mid)
    pivot = elem(hd(right), 0)

    "    (if (i64.lt_u (local.get $key) (i64.const #{pivot}))\n      (then\n#{bisect_apply(left)})\n      (else\n#{bisect_apply(right)}))"
  end

  def helper_apply_clauses(1, aidx, mul, args) do
    for {m, f, wat} <- [
          {:erlang, :exit, "$erlang.exit_1"},
          {:maps, :from_list, "$maps.from_list_1"},
          {:binary, :copy, "$binary.copy_1"}
        ],
        Map.has_key?(aidx, m),
        Map.has_key?(aidx, f) do
      {Map.fetch!(aidx, m) * mul + Map.fetch!(aidx, f), "(return_call #{wat}#{args})"}
    end
  end

  def helper_apply_clauses(_n, _aidx, _mul, _args), do: []

  # apply_N clauses for CAPTURED ext functions (`&abs/1`, `&Tuple.to_list/1`, `&band/2`): a literal
  # fun applied via the trampoline lands in apply_N keyed on (mod,fun). Route each captured ext MFA of
  # arity n — that isn't a user function but has a builtin shim or a synthesized capture wrapper — to it.
  def ext_capture_clauses(n, user, aidx, mul, args) do
    defined = MapSet.new(user, fn {m, {:function, nm, a, _, _}} -> {m, nm, a} end)
    bkeys = MapSet.new(Map.keys(builtins()))
    wraps = MapSet.new(captured_ext_targets(user))
    # gated extras that exist as real functions when their feature flag is on (see compile/1)
    gated =
      if(Process.get(:atom_names),
        do: MapSet.new([{:erlang, :atom_to_binary, 1}, {:erlang, :atom_to_binary, 2}]),
        else: MapSet.new()
      )

    collect_literal_funs(user)
    |> Enum.uniq()
    |> Enum.filter(fn {_, _, a} -> a == n end)
    |> Enum.reject(fn mfa -> MapSet.member?(defined, mfa) end)
    |> Enum.filter(fn {m, f, _a} = mfa ->
      (MapSet.member?(bkeys, fq_b(mfa)) or MapSet.member?(wraps, mfa) or MapSet.member?(gated, mfa)) and
        Map.has_key?(aidx, m) and Map.has_key?(aidx, f)
    end)
    |> Enum.map(fn {m, f, a} ->
      {Map.fetch!(aidx, m) * mul + Map.fetch!(aidx, f), "(return_call #{fq(m, f, a)}#{args})"}
    end)
  end

  def fq_b({m, f, a}), do: fq(m, f, a)

  def call_fun_arities(user) do
    user
    |> Enum.flat_map(fn {_mod, {:function, _, _, _, is}} ->
      Enum.flat_map(is, fn
        {:call_fun, n} -> [n]
        {:call_fun2, _, n, _} -> [n]
        _ -> []
      end)
    end)
    |> Enum.uniq()
  end

  def atoms_in({:literal, term}), do: term_atoms(term)
  def atoms_in({:atom, a}), do: [a]
  def atoms_in(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&atoms_in/1)
  def atoms_in(l) when is_list(l), do: Enum.flat_map(l, &atoms_in/1)
  def atoms_in(_), do: []

  def term_atoms(a) when is_atom(a), do: [a]
  # Map.to_list (not Enum) — a struct literal (e.g. a Range) is Enumerable; Enum would iterate
  # it as a SEQUENCE, not key/value pairs. Map.to_list always treats it as a raw map.
  def term_atoms(m) when is_map(m),
    do: Map.to_list(m) |> Enum.flat_map(fn {k, v} -> term_atoms(k) ++ term_atoms(v) end)

  def term_atoms(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&term_atoms/1)
  def term_atoms(l) when is_list(l), do: Enum.flat_map(l, &term_atoms/1)
  def term_atoms(_), do: []

  def const_globals do
    Process.get(:const_defs, [])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {idx, expr} -> "  (global $const#{idx} (ref null eq) #{expr})" end)
  end
end
