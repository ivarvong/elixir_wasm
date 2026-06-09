#!/usr/bin/env elixir
# beam2wasm — BEAM -> WasmGC compiler, in Elixir, consuming OTP's own :beam_disasm.
# No hand-rolled .beam parser/decoder: :beam_disasm gives symbolic instructions (and
# normalizes typed registers, so default Elixir output works). Emits WAT to stdout.
#   elixir beam2wasm.exs Elixir.Sort.beam > sort.wat
defmodule Beam2Wasm do
  @skip ~w(module_info __info__)a

  def run(beam_paths) do
    parsed = Enum.map(beam_paths, fn p ->
      {:beam_file, mod, _exp, _attr, _info, fns} = :beam_disasm.file(String.to_charlist(p))
      {mod, fns}
    end)
    mods = Enum.map(parsed, &elem(&1, 0))
    Process.put(:primary_mod, hd(mods))
    # keep each function tagged with its module so names can be module-qualified ($Mod.fun_arity)
    user_all = parsed
           |> Enum.flat_map(fn {mod, fns} -> Enum.map(fns, &{mod, &1}) end)
           |> Enum.reject(fn {_mod, {:function, n, _a, _e, _i}} ->
             n in @skip or String.starts_with?(Atom.to_string(n), "-inlined-")
           end)
    # Function-level DCE (smart AOT): compile only functions reachable from the exported
    # entry points — not the whole stdlib. On by default (NODCE=1 to disable). Drops the
    # STUB-as-crutch: ship only reachable code, and if it has 0 stubs it's provably supported.
    user =
      if System.get_env("NODCE") == nil do
        reach = reachable(user_all, export_seeds(mods))
        kept = Enum.filter(user_all, fn {m, {:function, n, a, _, _}} -> MapSet.member?(reach, {m, n, a}) end)
        IO.puts(:stderr, "DCE: kept #{length(kept)} of #{length(user_all)} functions")
        kept
      else
        user_all
      end
    # processes: spawn/send/receive present? -> emit proc imports + start_process + preemption.
    proc = proc_mode?(user)
    Process.put(:proc, proc)   # term_eq reads this to enable pid/ref value-equality
    # MFA dispatch (spawn_opt / apply/3 / make_fun) needs the generic apply helper + apply_0..8.
    mfa? = Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
      Enum.any?(is, fn op ->
        match?({_, _, {:extfunc, :erlang, f, _}} when f in [:spawn_opt, :apply, :make_fun, :hibernate], op) or
          match?({_, _, {:extfunc, :erlang, f, _}, _} when f in [:spawn_opt, :apply, :make_fun, :hibernate], op)
      end)
    end)
    exc = exc_mode?(user)   # try/catch/raise present? -> emit the Wasm exception tag
    Process.put(:exc, exc)
    # Reduction-counted preemption: REDS env sets the budget; proc mode defaults it on (so the
    # scheduler is preemptive, not just cooperative). Injects a per-entry decrement + yield.
    reds = case System.get_env("REDS") do
      nil -> if proc, do: 2000, else: nil
      s -> String.to_integer(s)
    end
    Process.put(:reds, reds)
    # Exact integers are the default: i31 fast path, host BigInt on overflow. Set BIGNUM=0 only for
    # compiler experiments that intentionally want wrapping small-int arithmetic.
    bignum = System.get_env("BIGNUM") != "0"
    Process.put(:bignum, bignum)
    flt = float_mode?(user)   # f64 floats + :math.* present? -> emit $float box + math host imports
    Process.put(:float, flt)
    Process.put(:stub, System.get_env("STUB") != nil)
    # Closures: scan make_fun3 to learn every closure-target function, its call arity N
    # (= total arity - num free vars) and its slot in the funcref table.
    clos_refs = collect_closures(user)   # unique [{mod, fun, total_arity, numfree}]
    # A "dual" target is both captured AND called directly (a named capture &f/a, always
    # 0 free vars): it keeps its normal signature; the table points at a thin wrapper.
    direct = MapSet.new(called_funs(user))   # set of {mod, fun, arity}
    clos_map = clos_refs |> Enum.with_index()
               |> Map.new(fn {{m, fun, ar, nf}, i} ->
                 {{m, fun, ar}, %{n: ar - nf, f: nf, idx: i, dual: MapSet.member?(direct, {m, fun, ar})}}
               end)
    Process.put(:closures, clos_map)
    literal_funs = collect_literal_funs(user)
    # erlang:make_fun(M,F,A) creates a fun dynamically. We lower it to a per-arity TRAMPOLINE that
    # reads M,F from the fun's free vars and tail-calls apply_N. Trampolines live in the funcref table
    # right after the static closures (arity N at index base+N), so make_fun is `base + A`.
    mkfun? = Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
      Enum.any?(is, &match?({_, _, {:extfunc, :erlang, :make_fun, 3}}, &1))
    end)
    tramp_ns = if mkfun? or literal_funs != [], do: Enum.to_list(0..8), else: []
    tramp_base = length(clos_refs)
    Process.put(:tramp_base, tramp_base)
    # maps:fold/3 is shimmed (calls a $clos3 Fun) — gate it (needs $ftab+$clos3) and force $clos3.
    mapsfold? = Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
      Enum.any?(is, &match?({_, _, {:extfunc, :maps, :fold, 3}}, &1))
    end)
    Process.put(:mapsfold, mapsfold?)
    clos_ns = (Enum.map(clos_refs, fn {_m, _f, ar, nf} -> ar - nf end) ++ call_fun_arities(user) ++ tramp_ns ++
               if(mapsfold?, do: [3], else: []) ++ if(proc, do: [0], else: []))
              |> Enum.uniq() |> Enum.sort()
    trampolines = Enum.map_join(tramp_ns, "\n", fn nn ->
      ps = if nn == 0, do: "", else: " " <> Enum.map_join(0..(nn - 1), " ", &"(param $x#{&1} (ref null eq))")
      as = if nn == 0, do: "", else: " " <> Enum.map_join(0..(nn - 1), " ", &"(local.get $x#{&1})")
      arr = "(struct.get $fun 1 (ref.cast (ref $fun) (local.get $self)))"
      m = "(array.get $freevars #{arr} (i32.const 0))"
      f = "(array.get $freevars #{arr} (i32.const 1))"
      "  (func $mkfun_tramp_#{nn} (type $clos#{nn}) (param $self (ref null eq))#{ps} (result (ref null eq))\n" <>
        "    (return_call $apply_#{nn}#{as} #{m} #{f}))"
    end)
    clos_types = Enum.map_join(clos_ns, "\n", fn nn ->
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
        ps = if callar == 0, do: "", else: " " <> Enum.map_join(0..(callar - 1), " ", &"(param $x#{&1} (ref null eq))")
        callas = if callar == 0, do: [], else: Enum.map(0..(callar - 1), &"(local.get $x#{&1})")
        fvs = if nf == 0, do: [], else: Enum.map(0..(nf - 1), fn k ->
          "(array.get $freevars (struct.get $fun 1 (ref.cast (ref $fun) (local.get $self))) (i32.const #{k}))"
        end)
        allas = Enum.join(callas ++ fvs, " ")
        allas = if allas == "", do: "", else: " " <> allas
        "  (func #{fq(m, fun, ar)}__c (type $clos#{callar}) (param $self (ref null eq))#{ps} (result (ref null eq))\n" <>
          "    (return_call #{fq(m, fun, ar)}#{allas}))"
      end)
    tab_entries = Enum.map(clos_refs, fn {m, fun, ar, _nf} -> tabname.(m, fun, ar) end) ++
                  Enum.map(tramp_ns, &"$mkfun_tramp_#{&1}")
    clos_table =
      cond do
        tab_entries != [] ->
          "  (table $ftab #{length(tab_entries)} funcref)\n  (elem (table $ftab) (i32.const 0) func " <>
            Enum.join(tab_entries, " ") <> ")"
        # A reachable-but-unexecuted call_indirect $ftab (e.g. a DCE-kept stdlib higher-order fn whose
        # closure arg is never built on the taken path) still needs the table to VALIDATE. Empty is safe.
        clos_ns != [] -> "  (table $ftab 0 funcref)"
        true -> ""
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
    http_get? = not req_in_user and Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
      Enum.any?(is, fn op ->
        match?({_, _, {:extfunc, Req, :get!, 1}}, op) or match?({_, _, {:extfunc, Req, :get!, 1}, _}, op)
      end)
    end)
    # :crypto.hash/2 — an OpenSSL NIF (hashing). Native code, can't compile → cross to the host (node/
    # WebCrypto). Deterministic, so the VM (OpenSSL) and Wasm (host) compute the identical standard digest.
    crypto_hash? = Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
      Enum.any?(is, fn op ->
        match?({_, _, {:extfunc, :crypto, :hash, 2}}, op) or match?({_, _, {:extfunc, :crypto, :hash, 2}, _}, op)
      end)
    end)
    forced = [nil, true, false, :ok, :error, :undefined, :current_stacktrace, :none, :global, :nomatch, :trim, :infinity, :module, :source, :unix, :linux] ++
             (if http_get?, do: [:body, :status, :__struct__, Req.Response], else: []) ++
             (if req_in_user, do: [:__struct__, Req.Response, :status, :headers, :body, :trailers, :private], else: []) ++ if(proc, do: [:EXIT, :normal, :DOWN, :process, :"nonode@nohost", :link, :monitor], else: []) ++
             if(exc, do: [:throw, :error, :exit, :EXIT], else: [])
    # name-sorted interning: atom index order == name order, so $term_compare on atoms (which
    # compares indices) matches Erlang's atom term order. Correct, and cheap.
    # Intern every compiled function's MODULE and NAME atom: any function (incl. anonymous stdlib
    # closures like Stream.-zip_with/2-fun-0-) can be applied via the generic apply_N dispatch, which
    # keys on (mod_idx, fun_idx) — so those atoms must be interned or the dispatch clause is dropped
    # and apply_N falls to (unreachable).
    fn_atoms = Enum.flat_map(user, fn {m, {:function, nm, _, _, _}} -> [m, nm] end)
    atoms = (forced ++ fn_atoms ++ Enum.flat_map(user, fn {_m, {:function, _, _, _, is}} -> atoms_in(is) end) ++ Enum.flat_map(literal_funs, fn {m, f, _a} -> [m, f] end))
            |> Enum.uniq() |> Enum.sort_by(&Atom.to_string/1)
    Process.put(:atom_idx, atoms |> Enum.with_index() |> Map.new())   # atom -> interned index
    atom_globals = atoms |> Enum.with_index() |> Enum.map_join("\n", fn {a, i} ->
      "  (global $atom_#{sanitize(a)} (ref $atom) (struct.new $atom (i32.const #{i})))"
    end)
    # atom_to_binary needs each atom's NAME (the $atom struct only holds its index). Gated: emit a
    # parallel table of name-binaries (same sorted order = same index) only when it's reachable.
    # any call form (incl. tail calls) OR a captured `&Atom.to_string/1` (literal fun) needs the table.
    atom_names? = Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
      Enum.any?(is, fn op ->
        match?({_, _, {:extfunc, :erlang, :atom_to_binary, _}}, op) or
          match?({_, _, {:extfunc, :erlang, :atom_to_binary, _}, _}, op)
      end)
    end) or Enum.any?(collect_literal_funs(user), &match?({:erlang, :atom_to_binary, _}, &1)) or to_string?(user) or crypto_hash?
    Process.put(:atom_names, atom_names?)
    # String case mapping is genuinely table-backed -> delegate to the host (like math/big). Gated.
    strcase? = Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
      Enum.any?(is, fn op ->
        match?({_, _, {:extfunc, String.Unicode, f, _}} when f in [:upcase, :downcase], op) or
          match?({_, _, {:extfunc, String.Unicode, f, _}, _} when f in [:upcase, :downcase], op)
      end)
    end)
    # Regex.split/3 — delegated to a host JS RegExp (like math/str). Gated on reachability.
    regex_split? = Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
      Enum.any?(is, fn op ->
        match?({_, _, {:extfunc, Regex, :split, 3}}, op) or match?({_, _, {:extfunc, Regex, :split, 3}, _}, op)
      end)
    end)
    Process.put(:regex_split, regex_split?)
    regex_run? = Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
      Enum.any?(is, fn op ->
        match?({_, _, {:extfunc, Regex, :run, 2}}, op) or match?({_, _, {:extfunc, Regex, :run, 2}, _}, op)
      end)
    end)
    # :string.titlecase/1 (String.capitalize) -> uppercase the first grapheme; delegate to the host.
    # Only shim when the real :string module ISN'T compiled in (else its body wins — its unicode_util
    # path stubs, but on the demo's executed path titlecase is never called).
    titlecase? = not Enum.any?(user, fn {m, _} -> m == :string end) and
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, :string, :titlecase, 1}}, op) or match?({_, _, {:extfunc, :string, :titlecase, 1}, _}, op)
        end)
      end)
    atomname_global =
      if atom_names? do
        names = Enum.map_join(atoms, " ", fn a -> bin_literal(Atom.to_string(a)) end)
        "  (global $atomnames (ref $tuple) (array.new_fixed $tuple #{length(atoms)} #{names}))"
      else
        ""
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
      (if atom_names?, do: [{:erlang, :atom_to_binary, 1}, {:erlang, :atom_to_binary, 2}], else: []) ++
      (if strcase?, do: [{String.Unicode, :upcase, 3}, {String.Unicode, :downcase, 3}], else: []) ++
      (if to_string?(user), do: [{String.Chars, :to_string, 1}], else: []) ++
      (if regex_split?, do: [{Regex, :split, 3}], else: []) ++
      (if regex_run?, do: [{Regex, :run, 2}], else: []) ++
      (if titlecase?, do: [{:string, :titlecase, 1}], else: []) ++
      (if http_get?, do: [{Req, :get!, 1}], else: []) ++
      (if crypto_hash?, do: [{:crypto, :hash, 2}], else: [])
      |> MapSet.new()
    stubs =
      called_funs(user)
      |> Enum.reject(fn {m, f, a} -> MapSet.member?(defined, {m, f, a}) or Map.has_key?(builtins(), fq(m, f, a)) or MapSet.member?(math_defined, {m, f, a}) or MapSet.member?(extra_defined, {m, f, a}) end)
      |> Enum.map(fn {m, f, a} -> {fq(m, f, a), a, "#{m}.#{f}"} end)
      |> Enum.uniq_by(fn {name, _a, _orig} -> name end)   # distinct ops can sanitize alike
      |> Enum.map_join("\n", fn {name, a, orig} ->
        ps = if a == 0, do: "", else: " " <> (String.duplicate("(param (ref null eq)) ", a) |> String.trim_trailing())
        "  (func #{name}#{ps} (result (ref null eq)) (unreachable)) ;; stub: external #{orig}/#{a}"
      end)
    [
      "(module",
      "  ;; @atoms " <> atoms_json(atoms),
      "  (type $cons (struct (field (ref null eq)) (field (ref null eq))))",
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
      "  (type $mctx (struct (field (ref $bytes)) (field (mut i32))))",
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
      if(strcase?, do: "  (import \"str\" \"upcase\" (func $host_str_upcase (param (ref null eq)) (result (ref null eq))))\n  (import \"str\" \"downcase\" (func $host_str_downcase (param (ref null eq)) (result (ref null eq))))", else: ""),
      if(regex_split?, do: "  (import \"str\" \"re_split\" (func $host_re_split (param (ref null eq)) (param (ref null eq)) (result (ref null eq))))", else: ""),
      if(regex_run?, do: "  (import \"str\" \"re_run\" (func $host_re_run (param (ref null eq)) (param (ref null eq)) (result (ref null eq))))", else: ""),
      if(titlecase?, do: "  (import \"str\" \"titlecase\" (func $host_str_titlecase (param (ref null eq)) (result (ref null eq))))\n  (import \"str\" \"upchar\" (func $host_str_upchar (param i32) (result i32)))", else: ""),
      if(http_get? or req_in_user, do: "  (import \"http\" \"get\" (func $host_http_get (param (ref null eq)) (result (ref null eq))))", else: ""),
      if(crypto_hash?, do: "  (import \"crypto\" \"hash\" (func $host_crypto_hash (param (ref null eq)) (param (ref null eq)) (result (ref null eq))))", else: ""),
      # Wasm exception: (class, reason, stacktrace) all as terms. raise/throw/error throw it;
      # a try-containing function's dispatch loop is wrapped in a try_table that catches it.
      if(exc, do: "  (tag $exc (param (ref null eq)) (param (ref null eq)) (param (ref null eq)))", else: ""),
      if(reds, do: "  (global $reds (mut i32) (i32.const #{reds}))", else: ""),
      "  (global $refctr (mut i32) (i32.const 0))",   # make_ref source: a monotonic counter (after imports)
      "  (global $monotime (mut i32) (i32.const 0))",  # erlang:monotonic_time source (monotonic, distinct)
      atom_globals,
      atomname_global,
      const_globals(),   # hoisted constant maps/etc., built once as constant-expr globals
      if(atom_names?, do: """
        (func $erlang.atom_to_binary_1 (param $x (ref null eq)) (result (ref null eq))
          (array.get $tuple (global.get $atomnames) (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x)))))
        (func $erlang.atom_to_binary_2 (param $x (ref null eq)) (param $enc (ref null eq)) (result (ref null eq))
          (return_call $erlang.atom_to_binary_1 (local.get $x)))\
      """, else: ""),
      # String.Chars.to_string/1 — the protocol entry for string interpolation `#{x}` and Enum.join.
      # Dispatch on the runtime type to a binary: binaries pass through; integers/atoms convert; nil → "".
      # :string.titlecase(chardata) — titlecase the first character, PRESERVING the input shape:
      #   binary → binary (host upcases first char);  list [cp|rest] → [upper(cp)|rest] (codepoints).
      # String.capitalize passes a list of codepoints and pattern-matches is_integer/is_list on the result.
      if(titlecase?, do: "      (func $string.titlecase_1 (param $x (ref null eq)) (result (ref null eq))\n" <>
        "        (if (ref.test (ref $binary) (local.get $x)) (then (return (call $host_str_titlecase (local.get $x)))))\n" <>
        "        (if (ref.test (ref $cons) (local.get $x)) (then\n" <>
        "          (if (ref.test (ref i31) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $x)))) (then\n" <>
        "            (return (struct.new $cons (ref.i31 (call $host_str_upchar (i31.get_s (ref.cast (ref i31) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $x))))))) (struct.get $cons 1 (ref.cast (ref $cons) (local.get $x)))))))))\n" <>
        "        (call $host_str_titlecase (call $erlang.iolist_to_binary_1 (local.get $x))))", else: ""),
      # :crypto.hash(algo, data) — pass the algorithm NAME (atom→binary via the names table) + data to the
      # host, which runs the real digest (node crypto). Returns the raw digest binary, like OpenSSL.
      if(crypto_hash?, do: "      (func $crypto.hash_2 (param $algo (ref null eq)) (param $data (ref null eq)) (result (ref null eq))\n        (call $host_crypto_hash (call $erlang.atom_to_binary_1 (local.get $algo)) (local.get $data)))", else: ""),
      # Req.get!(url) -> a %Req.Response{} whose body is the host fetch (status 200). The transport is
      # the effect; everything the program does to the body afterward is pure WasmGC.
      if(http_get?, do: "      (func #{fq(Req, :get!, 1)} (param $url (ref null eq)) (result (ref null eq))\n" <>
        "        (call $map_put (call $map_put (call $map_put (struct.new $map (ref.null $mnode))\n" <>
        "          (global.get $atom_#{sanitize(:__struct__)}) (global.get $atom_#{sanitize(Req.Response)}))\n" <>
        "          (global.get $atom_#{sanitize(:status)}) (ref.i31 (i32.const 200)))\n" <>
        "          (global.get $atom_#{sanitize(:body)}) (call $host_http_get (local.get $url))))", else: ""),
      if(to_string?(user), do: """
        (func $Elixir_46_String_46_Chars.to_string_1 (param $x (ref null eq)) (result (ref null eq))
          (if (ref.test (ref $binary) (local.get $x)) (then (return (local.get $x))))
          (if #{type_test_i32(:is_integer, "(local.get $x)")} (then (return_call $erlang.integer_to_binary_1 (local.get $x))))
          (if (ref.eq (local.get $x) (global.get $atom_nil)) (then (return (struct.new $binary (array.new_default $bytes (i32.const 0))))))
          (if (ref.test (ref $atom) (local.get $x)) (then (return_call $erlang.atom_to_binary_1 (local.get $x))))
          (unreachable))\
      """, else: ""),
      # Regex.split(regex, subject, opts) — delegate the match to a host JS RegExp. The host returns a
      # framed binary <<count:32, (len:32, bytes)...>> (big-endian); we slice out each part as a sub-binary
      # and build the list, dropping empty parts when `trim: true` is in opts (Elixir's :trim semantics).
      if(regex_split?, do: """
        (func $Elixir_46_Regex.split_3 (param $re (ref null eq)) (param $subj (ref null eq)) (param $opts (ref null eq)) (result (ref null eq))
          (local $fb (ref $bytes)) (local $cnt i32) (local $off i32) (local $len i32) (local $trim i32) (local $out (ref null eq))
          (local.set $fb (call $bin_bytes (call $host_re_split (struct.get $mnode 1 (ref.as_non_null (call $map_get (local.get $re) (global.get $atom_source)))) (local.get $subj))))
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
      """, else: ""),
      # Regex.run(regex, subject) — host JS RegExp `.match`. Frame: <<matched:8, count:32, (len:32, bytes)...>>
      # (a non-participating group has len = 0xFFFFFFFF → nil). matched=0 → the whole call returns nil.
      if(regex_run?, do: """
        (func $Elixir_46_Regex.run_2 (param $re (ref null eq)) (param $subj (ref null eq)) (result (ref null eq))
          (local $fb (ref $bytes)) (local $cnt i32) (local $off i32) (local $len i32) (local $out (ref null eq)) (local $item (ref null eq))
          (local.set $fb (call $bin_bytes (call $host_re_run (struct.get $mnode 1 (ref.as_non_null (call $map_get (local.get $re) (global.get $atom_source)))) (local.get $subj))))
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
      """, else: ""),
      # String.Unicode.upcase/downcase(string, mode, acc) -> the cased binary (mode/acc ignored: acc=[]
      # at the top-level entry, and the host does the whole string at once). Genuinely table-backed.
      if(strcase?, do: """
        (func $Elixir_46_String_46_Unicode.upcase_3 (param $s (ref null eq)) (param $m (ref null eq)) (param $a (ref null eq)) (result (ref null eq))
          (call $host_str_upcase (local.get $s)))
        (func $Elixir_46_String_46_Unicode.downcase_3 (param $s (ref null eq)) (param $m (ref null eq)) (param $a (ref null eq)) (result (ref null eq))
          (call $host_str_downcase (local.get $s)))\
      """, else: ""),
      funcs,
      if(proc, do: start_process(mfa?), else: ""),
      # let the host reset a process's reduction budget on each dispatch (preemption)
      if(reds, do: "  (func (export \"set_reds\") (param $n i32) (global.set $reds (local.get $n)))", else: ""),
      clos_wrappers,
      trampolines,
      builtin_section,
      capture_section,
      apply_section,
      stubs,
      clos_table,
      helpers(),
      if(bignum, do: bignum_helpers(), else: ""),
      if(flt, do: float_helpers(user), else: ""),
      exports(mods),
      ")"
    ] |> Enum.join("\n")
  end

  # JS<->Wasm bridge for list terms (build/walk cons cells from the harness)
  defp helpers do
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
  defp bignum_imports do
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
      (import "big" "bit_length" (func $bigint_bit_length (param externref) (result i32)))#{if Process.get(:float), do: "\n      (import \"big\" \"to_f64\"    (func $bigint_to_f64 (param externref) (result f64)))", else: ""}\
    """
  end

  defp bignum_helpers do
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

  defp exports(mods) do
    case System.get_env("EXPORTS") do
      nil -> legacy_exports(mods)
      spec -> generic_exports(spec)
    end
  end

  # EXPORTS="name:argtype,argtype->ret; name2:...". Types: int|bin|atom|list|term.
  # Param int -> i32 boxed to i31; param bin/list/term -> (ref null eq) passed through.
  # Return int -> i32; atom -> i32 atom-index (decode via the @atoms table comment);
  # bin/list/term -> (ref null eq) (read via the bin_* / cons bridge helpers).
  defp generic_exports(spec) do
    spec
    |> String.split(";", trim: true)
    |> Enum.map_join("\n", fn s ->
      [name, sig] = String.split(s, ":", parts: 2)
      [args_s, ret] = String.split(sig, "->")
      argtypes = if String.trim(args_s) == "", do: [], else: String.split(args_s, ",", trim: true) |> Enum.map(&String.trim/1)
      a = length(argtypes)
      name = String.trim(name)
      ret = String.trim(ret)
      params = argtypes |> Enum.with_index() |> Enum.map_join(" ", fn {t, i} ->
        case t do "int" -> "(param $p#{i} i32)"; "float" -> "(param $p#{i} f64)"; _ -> "(param $p#{i} (ref null eq))" end
      end)
      # int args: in bignum mode narrow through i64 so values above the i31 range (|x| > 2^30,
      # which an i32 param can carry) become a boxed $big instead of being truncated to 31 bits.
      int_arg = fn i ->
        if Process.get(:bignum),
          do: "(call $narrow (i64.extend_i32_s (local.get $p#{i})))",
          else: "(ref.i31 (local.get $p#{i}))"
      end
      args = argtypes |> Enum.with_index() |> Enum.map_join(" ", fn {t, i} ->
        case t do "int" -> int_arg.(i); "float" -> "(struct.new $float (local.get $p#{i}))"; _ -> "(local.get $p#{i})" end
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
          "atom" -> {"(result i32)", "(struct.get $atom 0 (ref.cast (ref $atom) #{call}))"}
          "float" -> {"(result f64)", "(struct.get $float 0 (ref.cast (ref $float) #{call}))"}
          _      -> {"(result (ref null eq))", call}
        end
      "  (func (export \"#{name}\") #{params} #{result}\n    #{body})"
    end)
  end

  defp legacy_exports(mods) do
    specs = Enum.flat_map(mods, fn m ->
      sp = case m do
        Sort  -> [{:sort, 1, :list}]
        Expr  -> [{:demo, 1, :int}]
        Account -> [{:demo, 1, :int}]
        AccountAbi -> [{:transition_balance, 4, :int}, {:transition_status, 4, :int}]
        Smoke -> [{:add, 2, :int}, {:dbl, 1, :int}, {:fact, 1, :int}, {:fib, 1, :int}]
        Lists -> [{:sumto, 1, :int}]
        _     -> []
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

  # In STUB mode, a function using a long-tail construct we don't lower yet (try/apply,
  # float arithmetic, odd binary segments) becomes a trap stub instead of failing the build.
  # Only unexercised (non-list-fast-path) Enum functions hit this.
  defp safe_compile_fun(mod, {:function, name, arity, _e, _i} = f) do
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

  # Hand-written WAT for native BIFs/NIFs the BEAM implements in C. Keyed by $Mod.fun_arity.
  # These override the (nif_error) BEAM body when the module is compiled in, and fill the
  # gap when it isn't. The ROADMAP's "BIF shims" — grown as real programs need them.
  defp builtins do
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
      # binary:split(Subject, Pattern[, Opts]) — Opts with :global splits on every occurrence.
      "$binary.split_2" =>
        """
          (func $binary.split_2 (param $subj (ref null eq)) (param $pat (ref null eq)) (result (ref null eq))
            (return_call $bsplit (local.get $subj) (local.get $pat) (i32.const 0)))\
        """,
      "$binary.split_3" =>
        """
          (func $binary.split_3 (param $subj (ref null eq)) (param $pat (ref null eq)) (param $opts (ref null eq)) (result (ref null eq))
            (return_call $bsplit (local.get $subj) (local.get $pat) (call $list_has_atom (local.get $opts) (global.get $atom_global))))\
        """,
      "$bsplit" =>
        """
          (func $bsplit (param $subj (ref null eq)) (param $pat (ref null eq)) (param $glob i32) (result (ref null eq))
            (local $s (ref $bytes)) (local $p (ref $bytes)) (local $pn i32) (local $sn i32) (local $prev i32) (local $i i32) (local $parts (ref null eq))
            (local.set $s (call $bin_bytes (local.get $subj))) (local.set $p (call $bin_bytes (local.get $pat)))
            (local.set $pn (array.len (local.get $p))) (local.set $sn (array.len (local.get $s)))
            (block $done (loop $lp
              (local.set $i (call $bin_find (local.get $s) (local.get $prev) (local.get $p)))
              (br_if $done (i32.lt_s (local.get $i) (i32.const 0)))
              (local.set $parts (struct.new $cons (call $subbin (local.get $s) (local.get $prev) (i32.sub (local.get $i) (local.get $prev))) (local.get $parts)))
              (local.set $prev (i32.add (local.get $i) (local.get $pn)))
              (br_if $done (i32.eqz (local.get $glob)))
              (br $lp)))
            (local.set $parts (struct.new $cons (call $subbin (local.get $s) (local.get $prev) (i32.sub (local.get $sn) (local.get $prev))) (local.get $parts)))
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
            (local.set $parts (call $bsplit (local.get $subj) (local.get $pat) (call $list_has_atom (local.get $opts) (global.get $atom_global))))
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
      "$erlang.integer_to_list_1" =>
        """
          (func $erlang.integer_to_list_1 (param $n (ref null eq)) (result (ref null eq))
            (ref.null none))\
        """,
      "$erlang.list_to_integer_1" =>
        """
          (func $erlang.list_to_integer_1 (param $l (ref null eq)) (result (ref null eq))
            (local $neg i32) (local $acc (ref null eq)) (local $c i32)
            (local.set $acc (ref.i31 (i32.const 0)))
            (if (ref.test (ref $cons) (local.get $l)) (then
              (local.set $c (i31.get_s (ref.cast (ref i31) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))))
              (if (i32.eq (local.get $c) (i32.const 45))
                (then (local.set $neg (i32.const 1)) (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))))))
            (block $done (loop $lp
              (br_if $done (i32.eqz (ref.test (ref $cons) (local.get $l))))
              (local.set $c (i31.get_s (ref.cast (ref i31) (struct.get $cons 0 (ref.cast (ref $cons) (local.get $l))))))
              (local.set $acc (call $int_add (call $int_mul (local.get $acc) (ref.i31 (i32.const 10))) (ref.i31 (i32.sub (local.get $c) (i32.const 48)))))
              (local.set $l (struct.get $cons 1 (ref.cast (ref $cons) (local.get $l))))
              (br $lp)))
            (if (result (ref null eq)) (local.get $neg) (then (call $int_sub (ref.i31 (i32.const 0)) (local.get $acc))) (else (local.get $acc))))\
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
      "$erlang.binary_to_integer_1" =>
        """
          (func $erlang.binary_to_integer_1 (param $bin (ref null eq)) (result (ref null eq))
            (local $b (ref $bytes)) (local $n i32) (local $i i32) (local $neg i32) (local $acc i32) (local $c i32)
            (local.set $b (struct.get $binary 0 (ref.cast (ref $binary) (local.get $bin))))
            (local.set $n (array.len (local.get $b)))
            (if (i32.eqz (local.get $n)) (then (unreachable)))
            (if (i32.eq (array.get_u $bytes (local.get $b) (i32.const 0)) (i32.const 45))
              (then (local.set $neg (i32.const 1)) (local.set $i (i32.const 1))))
            (block $done (loop $lp
              (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
              (local.set $c (array.get_u $bytes (local.get $b) (local.get $i)))
              (if (i32.or (i32.lt_u (local.get $c) (i32.const 48)) (i32.gt_u (local.get $c) (i32.const 57))) (then (unreachable)))
              (local.set $acc (i32.add (i32.mul (local.get $acc) (i32.const 10)) (i32.sub (local.get $c) (i32.const 48))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $lp)))
            (if (local.get $neg) (then (local.set $acc (i32.sub (i32.const 0) (local.get $acc)))))
            (ref.i31 (local.get $acc)))\
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
      if Process.get(:float), do: Map.merge(base, float_builtins()), else: base
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

  defp float_builtins do
    for f <- ["floor", "ceil", "round"], into: %{} do
      body =
        if f == "round",
          do: "(f64.trunc (f64.add (call $to_f64 (local.get $x)) (f64.copysign (f64.const 0.5) (call $to_f64 (local.get $x)))))",
          else: "(f64.#{f} (call $to_f64 (local.get $x)))"
      {"$Elixir_46_Float.#{f}_2",
        """
          (func $Elixir_46_Float.#{f}_2 (param $x (ref null eq)) (param $p (ref null eq)) (result (ref null eq))
            (if (i32.eqz (ref.eq (local.get $p) (ref.i31 (i32.const 0)))) (then (unreachable)))
            (struct.new $float #{body}))\
        """}
    end
  end

  defp stub_function(mod, name, arity) do
    Process.put(:stubs, (Process.get(:stubs) || 0) + 1)
    cl = Process.get(:closures, %{}) |> Map.get({mod, name, arity})
    if cl && not cl.dual do
      n = cl.n
      ps = if n == 0, do: "", else: " " <> Enum.map_join(0..(n - 1), " ", &"(param $x#{&1} (ref null eq))")
      "  (func #{fq(mod, name, arity)} (type $clos#{n}) (param $self (ref null eq))#{ps} (result (ref null eq)) (unreachable)) ;; STUB fn"
    else
      ps = if arity == 0, do: "", else: " " <> Enum.map_join(0..(arity - 1), " ", &"(param $x#{&1} (ref null eq))")
      "  (func #{fq(mod, name, arity)}#{ps} (result (ref null eq)) (unreachable)) ;; STUB fn"
    end
  end

  # ---- per-function compilation ----
  defp compile_fun(mod, {:function, name, arity, entry, instrs}) do
    blocks = partition(instrs) |> Enum.map(fn {l, ops} -> {l, resolve_trims(ops)} end)
    idx = blocks |> Enum.with_index() |> Map.new(fn {{l, _}, i} -> {l, i} end)
    entry_idx = Map.fetch!(idx, entry)
    n = length(blocks)
    {maxx0, maxy} = max_regs(Enum.flat_map(blocks, fn {_l, o} -> o end), arity)
    # A function containing try/try_case lowers onto a Wasm `try_table` wrapping its
    # whole dispatch loop. The catch handler stages class/reason/trace into x0/x1/x2,
    # so those three registers must exist even when arity < 3.
    has_try = Enum.any?(blocks, fn {_l, ops} ->
      Enum.any?(ops, fn op -> match?({:try, _, _}, op) or match?({:try_case, _}, op) or
        match?({:catch, _, _}, op) or match?({:catch_end, _}, op) end)
    end)
    # Calls land their result implicitly in x0; a 0-arity function whose only use of x0 is as a
    # call result (e.g. `def f, do: g() |> h()`) never names {:x,0} as an operand, so max_regs
    # misses it. Ensure x0 exists whenever the body makes any call (for arity>0, x0 is a param).
    has_call? = Enum.any?(blocks, fn {_l, ops} ->
      Enum.any?(ops, fn op -> match?({:call, _, _}, op) or match?({:call_only, _, _}, op) or
        match?({:call_last, _, _, _}, op) or match?({:call_ext, _, _}, op) or
        match?({:call_ext_only, _, _}, op) or match?({:call_ext_last, _, _, _}, op) or
        match?({:call_fun, _}, op) or match?({:call_fun2, _, _, _}, op) or
        match?({:apply, _}, op) or match?({:apply_last, _, _}, op) end)
    end)
    maxx0 = if arity == 0 and has_call?, do: max(maxx0, 0), else: maxx0
    maxx = if has_try, do: max(maxx0, 2), else: maxx0
    # f64 float registers ($fr0..$frN): highest {:fr, n} referenced anywhere in the function.
    maxfr =
      blocks |> Enum.flat_map(fn {_l, o} -> o end) |> Enum.flat_map(&fr_indices/1)
      |> Enum.max(fn -> -1 end)
    fn_name = fq(mod, name, arity)

    blk = fn l -> Map.fetch!(idx, l) end
    jump = fn l -> "(local.set $blk (i32.const #{blk.(l)})) (br $dispatch)" end
    val = &operand/1
    i32v = &i32val/1
    set = fn {t, k}, e -> "(local.set $#{t}#{k} #{e})" end
    cargs = fn a -> if a == 0, do: "", else: Enum.map_join(0..(a - 1), " ", &"(local.get $x#{&1})") end
    frval = fn {:fr, k} -> "(local.get $fr#{k})" end   # a float-register read (f64)
    # spawn_opt/{4,5}: M/F/A/Opts at x[o..o+3] (o=1 skips Node for /5). link/monitor from Opts.
    spawn_opt_expr = fn ar ->
      o = if ar == 4, do: 0, else: 1
      opts = "(local.get $x#{o + 3})"
      "(block (result (ref null eq)) (local.set $midx (call $spawn_opt_raw (local.get $x#{o}) (local.get $x#{o + 1}) (local.get $x#{o + 2}) (call $list_has_atom #{opts} (global.get $atom_link)))) (if (result (ref null eq)) (call $list_has_atom #{opts} (global.get $atom_monitor)) (then (array.new_fixed $tuple 2 (struct.new $pid (local.get $midx)) (struct.new $ref (call $monitor_raw (local.get $midx)) (i32.const 0)))) (else (struct.new $pid (local.get $midx)))))"
    end

    emit = fn op ->
      case op do
        {:move, s, d} -> {[set.(d, val.(s))], false}
        {:gc_bif, o, _f, _l, [a1, a2], d} ->
          ab = if o in [:+, :-, :*], do: arith_bounds(o, a1, a2), else: nil
          e = cond do
            # SPECIALIZED: result provably fits i31 -> inline i32, no helper call / no box (i31 immediate).
            ab != nil and fits_i31?(ab) -> "(ref.i31 (i32.#{wasmop(o)} #{i32val(a1)} #{i32val(a2)}))"
            # SPECIALIZED: both operands proven integer (not float) -> the int helper directly, skipping
            # the float-capable $num_ path's runtime float test.
            Process.get(:bignum) and o in [:+, :-, :*] and int_typed?(a1) and int_typed?(a2) -> "(call $int_#{bif(o)} #{val.(a1)} #{val.(a2)})"
            Process.get(:float) and o in [:+, :-, :*] -> "(call $num_#{bif(o)} #{val.(a1)} #{val.(a2)})"
            Process.get(:bignum) and o in [:+, :-, :*, :div, :rem] -> "(call $int_#{bif(o)} #{val.(a1)} #{val.(a2)})"
            # bitwise: in bignum mode route through the tiered helper (i31 fast path + arbitrary-
            # precision host fallback), so boxed operands don't `illegal cast` and results don't
            # silently truncate at 31 bits (e.g. `1 bsl 40`). Otherwise the i64 fast path.
            Process.get(:bignum) and o in [:band, :bor, :bxor, :bsl, :bsr] -> "(call $int_#{o} #{val.(a1)} #{val.(a2)})"
            o in [:band, :bor, :bxor, :bsl, :bsr] -> "(ref.i31 (i32.wrap_i64 (i64.#{wasmop(o)} #{i64val(a1)} #{i64val(a2)})))"
            true -> "(ref.i31 (i32.#{wasmop(o)} #{i32v.(a1)} #{i32v.(a2)}))"
          end
          {[set.(d, e)], false}
        {:gc_bif, :-, _f, _l, [a], d} ->
          e = if Process.get(:bignum), do: "(call $int_sub (ref.i31 (i32.const 0)) #{val.(a)})", else: "(ref.i31 (i32.sub (i32.const 0) #{i32v.(a)}))"
          {[set.(d, e)], false}
        {:gc_bif, :+, _f, _l, [a], d} -> {[set.(d, val.(a))], false}
        # comparison bifs used as VALUES (not tests) -> the atom true/false
        {:bif, op, _f, [a, b], d} when op in [:"=:=", :==, :"=/=", :"/=", :<, :>, :">=", :"=<"] ->
          {[set.(d, "(if (result (ref null eq)) #{bool_cmp(op, a, b)} (then (global.get $atom_true)) (else (global.get $atom_false)))")], false}
        {:gc_bif, :length, _f, _l, [a], d} -> {[set.(d, "(ref.i31 (call $list_len #{val.(a)}))")], false}
        # abs / min / max — integer fast path (general term ordering is a TODO)
        {gop, :abs, _f, _l, [a], d} when gop in [:gc_bif, :bif] ->
          x = i32v.(a)
          e = if Process.get(:bignum),
            do: "(if (result (ref null eq)) (i32.lt_s (call $int_cmp #{val.(a)} (ref.i31 (i32.const 0))) (i32.const 0)) (then (call $int_sub (ref.i31 (i32.const 0)) #{val.(a)})) (else #{val.(a)}))",
            else: "(ref.i31 (select (i32.sub (i32.const 0) #{x}) #{x} (i32.lt_s #{x} (i32.const 0))))"
          {[set.(d, e)], false}
        {:bif, :abs, _f, [a], d} ->
          x = i32v.(a)
          e = if Process.get(:bignum),
            do: "(if (result (ref null eq)) (i32.lt_s (call $int_cmp #{val.(a)} (ref.i31 (i32.const 0))) (i32.const 0)) (then (call $int_sub (ref.i31 (i32.const 0)) #{val.(a)})) (else #{val.(a)}))",
            else: "(ref.i31 (select (i32.sub (i32.const 0) #{x}) #{x} (i32.lt_s #{x} (i32.const 0))))"
          {[set.(d, e)], false}
        {gop, mm, _f, _l, [a, b], d} when gop in [:gc_bif, :bif] and mm in [:min, :max] ->
          x = i32v.(a); y = i32v.(b); c = if mm == :min, do: "i32.lt_s", else: "i32.gt_s"
          e = if Process.get(:bignum),
            do: "(if (result (ref null eq)) (#{if mm == :min, do: "i32.lt_s", else: "i32.gt_s"} (call $int_cmp #{val.(a)} #{val.(b)}) (i32.const 0)) (then #{val.(a)}) (else #{val.(b)}))",
            else: "(ref.i31 (select #{x} #{y} (#{c} #{x} #{y})))"
          {[set.(d, e)], false}
        {:bif, mm, _f, [a, b], d} when mm in [:min, :max] ->
          x = i32v.(a); y = i32v.(b); c = if mm == :min, do: "i32.lt_s", else: "i32.gt_s"
          e = if Process.get(:bignum),
            do: "(if (result (ref null eq)) (#{if mm == :min, do: "i32.lt_s", else: "i32.gt_s"} (call $int_cmp #{val.(a)} #{val.(b)}) (i32.const 0)) (then #{val.(a)}) (else #{val.(b)}))",
            else: "(ref.i31 (select #{x} #{y} (#{c} #{x} #{y})))"
          {[set.(d, e)], false}
        {:gc_bif, :hd, _f, _l, [a], d} -> {[set.(d, "(struct.get $cons 0 (ref.cast (ref $cons) #{val.(a)}))")], false}
        {:gc_bif, :tl, _f, _l, [a], d} -> {[set.(d, "(struct.get $cons 1 (ref.cast (ref $cons) #{val.(a)}))")], false}
        {:bif, :hd, _f, [a], d} -> {[set.(d, "(struct.get $cons 0 (ref.cast (ref $cons) #{val.(a)}))")], false}
        {:bif, :tl, _f, [a], d} -> {[set.(d, "(struct.get $cons 1 (ref.cast (ref $cons) #{val.(a)}))")], false}
        {:gc_bif, :map_size, _f, _l, [a], d} ->
          {[set.(d, "(ref.i31 (call $map_size #{val.(a)}))")], false}
        {:bif, :map_get, _f, [key, m], d} ->
          {["(local.set $mn (call $map_get #{val.(m)} #{val.(key)}))",
            set.(d, "(struct.get $mnode 1 (ref.as_non_null (local.get $mn)))")], false}
        {:bif, :is_map_key, _f, [key, m], d} ->
          {[set.(d, "(if (result (ref null eq)) (call $map_has #{val.(m)} #{val.(key)}) (then (global.get $atom_true)) (else (global.get $atom_false)))")], false}
        {:gc_bif, :byte_size, _f, _l, [a], d} ->
          # byte_size works on a binary OR a match context (remaining bytes = total - position/8).
          {[set.(d, "(ref.i31 (if (result i32) (ref.test (ref $mctx) #{val.(a)}) " <>
            "(then (i32.sub (array.len (struct.get $mctx 0 (ref.cast (ref $mctx) #{val.(a)}))) (i32.div_u (struct.get $mctx 1 (ref.cast (ref $mctx) #{val.(a)})) (i32.const 8)))) " <>
            "(else (array.len (struct.get $binary 0 (ref.cast (ref $binary) #{val.(a)}))))))")], false}
        {:gc_bif, :bit_size, _f, _l, [a], d} ->
          {[set.(d, "(ref.i31 (i32.shl (array.len (struct.get $binary 0 (ref.cast (ref $binary) #{val.(a)}))) (i32.const 3)))")], false}
        {:test, eq, {:f, f}, [a, b]} when eq in [:is_eq_exact, :is_eq] -> {["(if (i32.eqz #{term_eq(val.(a), val.(b))}) (then #{jump.(f)}))"], false}
        {:test, ne, {:f, f}, [a, b]} when ne in [:is_ne_exact, :is_ne] -> {["(if #{term_eq(val.(a), val.(b))} (then #{jump.(f)}))"], false}
        # ordering tests use the real Erlang term order ($term_compare), not integer-only compare
        {:test, :is_lt, {:f, f}, [a, b]} -> {["(if (i32.ge_s #{cmp3(a, b)} (i32.const 0)) (then #{jump.(f)}))"], false}
        {:test, :is_ge, {:f, f}, [a, b]} -> {["(if (i32.lt_s #{cmp3(a, b)} (i32.const 0)) (then #{jump.(f)}))"], false}
        {:test, :is_le, {:f, f}, [a, b]} -> {["(if (i32.gt_s #{cmp3(a, b)} (i32.const 0)) (then #{jump.(f)}))"], false}
        {:test, :is_gt, {:f, f}, [a, b]} -> {["(if (i32.le_s #{cmp3(a, b)} (i32.const 0)) (then #{jump.(f)}))"], false}
        {:test, :is_nonempty_list, {:f, f}, [s]} -> {["(if (i32.eqz (ref.test (ref $cons) #{val.(s)})) (then #{jump.(f)}))"], false}
        {:test, :is_nil, {:f, f}, [s]} -> {["(if (i32.eqz (ref.is_null #{val.(s)})) (then #{jump.(f)}))"], false}
        {:test, :is_tuple, {:f, f}, [s]} -> {["(if (i32.eqz (ref.test (ref $tuple) #{val.(s)})) (then #{jump.(f)}))"], false}
        {:test, :test_arity, {:f, f}, [s, n2]} -> {["(if (i32.ne (array.len (ref.cast (ref $tuple) #{val.(s)})) (i32.const #{n2})) (then #{jump.(f)}))"], false}
        {:test, :is_map, {:f, f}, [s]} -> {["(if (i32.eqz (ref.test (ref $map) #{val.(s)})) (then #{jump.(f)}))"], false}
        {:test, :is_atom, {:f, f}, [s]} -> {["(if (i32.eqz (ref.test (ref $atom) #{val.(s)})) (then #{jump.(f)}))"], false}
        {:test, :is_binary, {:f, f}, [s]} -> {["(if (i32.eqz (ref.test (ref $binary) #{val.(s)})) (then #{jump.(f)}))"], false}
        {:test, :is_bitstring, {:f, f}, [s]} -> {["(if (i32.eqz (ref.test (ref $binary) #{val.(s)})) (then #{jump.(f)}))"], false}
        {:test, :is_boolean, {:f, f}, [s]} -> {["(if (i32.and (i32.eqz (ref.eq #{val.(s)} (global.get $atom_true))) (i32.eqz (ref.eq #{val.(s)} (global.get $atom_false)))) (then #{jump.(f)}))"], false}
        {:test, :is_function, {:f, f}, [s]} -> {["(if (i32.eqz (ref.test (ref $fun) #{val.(s)})) (then #{jump.(f)}))"], false}
        {:test, :is_function2, {:f, f}, [s, _arity]} -> {["(if (i32.eqz (ref.test (ref $fun) #{val.(s)})) (then #{jump.(f)}))"], false}
        {:test, :is_list, {:f, f}, [s]} ->
          {["(if (i32.and (i32.eqz (ref.is_null #{val.(s)})) (i32.eqz (ref.test (ref $cons) #{val.(s)}))) (then #{jump.(f)}))"], false}
        {:test, :is_integer, {:f, f}, [s]} ->
          test = if Process.get(:bignum),
            do: "(i32.and (i32.and (i32.eqz (ref.test (ref i31) #{val.(s)})) (i32.eqz (ref.test (ref $i64) #{val.(s)}))) (i32.eqz (ref.test (ref $big) #{val.(s)})))",
            else: "(i32.eqz (ref.test (ref i31) #{val.(s)}))"
          {["(if #{test} (then #{jump.(f)}))"], false}
        {:test, :is_float, {:f, f}, [s]} ->
          test = if Process.get(:float), do: "(ref.test (ref $float) #{val.(s)})", else: "(i32.const 0)"
          {["(if (i32.eqz #{test}) (then #{jump.(f)}))"], false}
        # is_number = integer (any tier) OR float
        {:test, :is_number, {:f, f}, [s]} ->
          {["(if (i32.eqz (i32.or #{type_test_i32(:is_integer, val.(s))} #{type_test_i32(:is_float, val.(s))})) (then #{jump.(f)}))"], false}
        {:test, :is_bitstr, {:f, f}, [s]} -> {["(if (i32.eqz (ref.test (ref $binary) #{val.(s)})) (then #{jump.(f)}))"], false}
        # floor/1 (and ceil) -> integer floor of a number. Needs the f64 path when floats are present.
        {:gc_bif, fc, _f, _l, [a], d} when fc in [:floor, :ceil] ->
          if Process.get(:float),
            do: {[set.(d, f64_to_int("(f64.#{fc} (call $to_f64 #{val.(a)}))"))], false},
            else: {[set.(d, val.(a))], false}
        # float/1 -> the float value of a number (int converts, float is identity).
        {gop, :float, _f, _l, [a], d} when gop in [:gc_bif, :bif] ->
          if Process.get(:float),
            do: {[set.(d, "(struct.new $float (call $to_f64 #{val.(a)}))")], false},
            else: {[set.(d, val.(a))], false}
        # trunc/1 (toward zero) and round/1 (half away from zero, like Erlang) -> an INTEGER. An
        # already-integer arg is returned unchanged (so bignums survive); a float is converted.
        {gop, tr, _f, _l, [a], d} when gop in [:gc_bif, :bif] and tr in [:trunc, :round] ->
          if Process.get(:float) do
            fx = "(struct.get $float 0 (ref.cast (ref $float) #{val.(a)}))"
            inner = if tr == :trunc, do: fx, else: "(f64.add #{fx} (f64.copysign (f64.const 0.5) #{fx}))"
            {[set.(d, "(if (result (ref null eq)) (ref.test (ref $float) #{val.(a)}) (then #{f64_to_int(inner)}) (else #{val.(a)}))")], false}
          else
            {[set.(d, val.(a))], false}
          end
        # boolean not/xor (value form): operands are the atoms true/false.
        {:bif, :not, _f, [a], d} ->
          {[set.(d, "(if (result (ref null eq)) (ref.eq #{val.(a)} (global.get $atom_true)) (then (global.get $atom_false)) (else (global.get $atom_true)))")], false}
        {:bif, :xor, _f, [a, b], d} ->
          {[set.(d, "(if (result (ref null eq)) (i32.ne (ref.eq #{val.(a)} (global.get $atom_true)) (ref.eq #{val.(b)} (global.get $atom_true))) (then (global.get $atom_true)) (else (global.get $atom_false)))")], false}
        {:bif, bop, _f, [a, b], d} when bop in [:and, :or] ->
          op = if bop == :and, do: "i32.and", else: "i32.or"
          {[set.(d, "(if (result (ref null eq)) (#{op} (ref.eq #{val.(a)} (global.get $atom_true)) (ref.eq #{val.(b)} (global.get $atom_true))) (then (global.get $atom_true)) (else (global.get $atom_false)))")], false}
        # type-test BIFs as VALUES (the atom true/false). The same predicates as the `test` forms.
        {:bif, tb, _f, [a], d} when tb in [:is_atom, :is_binary, :is_bitstring, :is_tuple, :is_map, :is_pid, :is_reference, :is_function, :is_float, :is_port, :is_integer, :is_list, :is_boolean] ->
          t = case tb do
            :is_atom -> "(ref.test (ref $atom) #{val.(a)})"
            tt when tt in [:is_binary, :is_bitstring] -> "(ref.test (ref $binary) #{val.(a)})"
            :is_tuple -> "(ref.test (ref $tuple) #{val.(a)})"
            :is_map -> "(ref.test (ref $map) #{val.(a)})"
            :is_pid -> "(ref.test (ref $pid) #{val.(a)})"
            :is_reference -> "(ref.test (ref $ref) #{val.(a)})"
            :is_function -> "(ref.test (ref $fun) #{val.(a)})"
            :is_float -> if(Process.get(:float), do: "(ref.test (ref $float) #{val.(a)})", else: "(i32.const 0)")
            :is_port -> "(i32.const 0)"
            :is_integer -> if(Process.get(:bignum), do: "(i32.or (i32.or (ref.test (ref i31) #{val.(a)}) (ref.test (ref $i64) #{val.(a)})) (ref.test (ref $big) #{val.(a)}))", else: "(ref.test (ref i31) #{val.(a)})")
            :is_list -> "(i32.or (ref.is_null #{val.(a)}) (ref.test (ref $cons) #{val.(a)}))"
            :is_boolean -> "(i32.or (ref.eq #{val.(a)} (global.get $atom_true)) (ref.eq #{val.(a)} (global.get $atom_false)))"
          end
          {[set.(d, "(if (result (ref null eq)) #{t} (then (global.get $atom_true)) (else (global.get $atom_false)))")], false}
        {:test, :has_map_fields, {:f, fail}, src, {:list, keys}} ->
          {Enum.map(keys, fn key -> "(if (i32.eqz (call $map_has #{val.(src)} #{val.(key)})) (then #{jump.(fail)}))" end), false}
        {:get_map_elements, {:f, fail}, src, {:list, pairs}} ->
          lines = pairs |> Enum.chunk_every(2) |> Enum.flat_map(fn [key, dst] ->
            ["(local.set $mn (call $map_get #{val.(src)} #{val.(key)}))",
             "(if (ref.is_null (local.get $mn)) (then #{jump.(fail)}))",
             set.(dst, "(struct.get $mnode 1 (ref.as_non_null (local.get $mn)))")]
          end)
          {lines, false}
        {:put_map_assoc, _f, src, dst, _l, {:list, kvs}} ->
          {[set.(dst, build_map(src, kvs, val))], false}
        {:put_map_exact, _f, src, dst, _l, {:list, kvs}} ->
          {[set.(dst, build_map(src, kvs, val))], false}
        {:get_list, s, h, t} -> {["(local.set $tmpc (ref.cast (ref $cons) #{val.(s)}))", set.(h, "(struct.get $cons 0 (local.get $tmpc))"), set.(t, "(struct.get $cons 1 (local.get $tmpc))")], false}
        {:get_hd, s, d} -> {[set.(d, "(struct.get $cons 0 (ref.cast (ref $cons) #{val.(s)}))")], false}
        {:get_tl, s, d} -> {[set.(d, "(struct.get $cons 1 (ref.cast (ref $cons) #{val.(s)}))")], false}
        {:bs_create_bin, _f, _heap, _live, _unit, dst, {:list, flat}} ->
          segs = Enum.chunk_every(flat, 6)
          {lines, expr} = create_bin_lines(segs, val)
          {lines ++ [set.(dst, expr)], false}
        # --- binary matching (modern OTP bs_match family) ---
        {:test, :bs_start_match3, {:f, fail}, _live, [src], dst} ->
          # src is EITHER the original binary (start at bit 0) OR an existing match
          # context threaded through a recursive call (reuse it, keep its position).
          {["(if (ref.test (ref $mctx) #{val.(src)})",
            "  (then #{set.(dst, val.(src))})",
            "  (else",
            "    (if (i32.eqz (ref.test (ref $binary) #{val.(src)})) (then #{jump.(fail)}))",
            "    #{set.(dst, "(struct.new $mctx (struct.get $binary 0 (ref.cast (ref $binary) #{val.(src)})) (i32.const 0))")}))"], false}
        # bs_start_match4: same as match3 but `fail` may be :no_fail/:resume (src provably matchable).
        {:bs_start_match4, fail, _live, src, dst} ->
          failbr = case fail do
            {:f, l} -> ["(if (i32.eqz (i32.or (ref.test (ref $mctx) #{val.(src)}) (ref.test (ref $binary) #{val.(src)}))) (then #{jump.(l)}))"]
            _ -> []
          end
          {failbr ++
           ["(if (ref.test (ref $mctx) #{val.(src)})",
            "  (then #{set.(dst, val.(src))})",
            "  (else #{set.(dst, "(struct.new $mctx (struct.get $binary 0 (ref.cast (ref $binary) #{val.(src)})) (i32.const 0))")}))"], false}
        # binary_part(Subject, Start, Length) -> a sub-binary (Subject may be a binary or match ctx).
        {:gc_bif, :binary_part, _f, _l, [src, start, len], d} ->
          {[set.(d, "(call $binary_part #{val.(src)} #{i32v.(start)} #{i32v.(len)})")], false}
        # bs_get_utf8: decode one UTF-8 codepoint from the ctx (advancing it); fail on invalid/short.
        {:test, :bs_get_utf8, {:f, fail}, [ctx, _live, _flags, dst]} ->
          {["(local.set $midx (call $mctx_get_utf8 #{val.(ctx)}))",
            "(if (i32.lt_s (local.get $midx) (i32.const 0)) (then #{jump.(fail)}))",
            set.(dst, "(ref.i31 (local.get $midx))")], false}
        # bs_skip_utf8: same, but discard the codepoint (just advance).
        {:test, :bs_skip_utf8, {:f, fail}, [ctx, _live, _flags]} ->
          {["(if (i32.lt_s (call $mctx_get_utf8 #{val.(ctx)}) (i32.const 0)) (then #{jump.(fail)}))"], false}
        {:test, :bs_match_string, {:f, fail}, [ctx, bits, {:string, s}]} ->
          checks = bit_chunks(s, bits) |> Enum.map(fn {off, n, v} ->
            "(if (i32.ne (call $bits_read (local.get $bsrc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{off})) (i32.const #{n})) (i32.const #{i32_const(v)})) (then #{jump.(fail)}))"
          end)
          {[
             "(local.set $mc (ref.cast (ref $mctx) #{val.(ctx)}))",
             "(if (i32.lt_s (i32.sub (i32.shl (array.len (struct.get $mctx 0 (local.get $mc))) (i32.const 3)) (struct.get $mctx 1 (local.get $mc))) (i32.const #{bits})) (then #{jump.(fail)}))",
             "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))"
           ] ++ checks ++
           ["(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{bits})))"], false}
        # bs_get_binary2 (older form): extract `size` units (unit bits each) as a sub-binary, advancing
        # the ctx. Byte-aligned in practice (unit=8). size=:all (or {:atom,:all}) takes the rest.
        {:test, :bs_get_binary2, {:f, fail}, _live, [ctx, size, unit, _flags], dst} ->
          rest? = size == :all or match?({:atom, :all}, size)
          setup = ["(local.set $mc (ref.cast (ref $mctx) #{val.(ctx)}))",
                   "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
                   "(local.set $boff (i32.div_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8)))"]
          tail =
            if rest? do
              ["(local.set $blen (i32.sub (array.len (local.get $bsrc)) (local.get $boff)))",
               "(struct.set $mctx 1 (local.get $mc) (i32.shl (array.len (local.get $bsrc)) (i32.const 3)))"]
            else
              nbits = "(i32.mul #{i32v.(size)} (i32.const #{unit}))"
              ["(if (i32.lt_s (i32.sub (i32.shl (array.len (local.get $bsrc)) (i32.const 3)) (struct.get $mctx 1 (local.get $mc))) #{nbits}) (then #{jump.(fail)}))",
               "(local.set $blen (i32.div_u #{nbits} (i32.const 8)))",
               "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) #{nbits}))"]
            end
          {setup ++ tail ++
           ["(local.set $bdst (array.new_default $bytes (local.get $blen)))",
            "(array.copy $bytes $bytes (local.get $bdst) (i32.const 0) (local.get $bsrc) (local.get $boff) (local.get $blen))",
            set.(dst, "(struct.new $binary (ref.as_non_null (local.get $bdst)))")], false}
        # bs_get_float2 (older form): read a `bits`-wide big-endian IEEE float (default flags), advancing.
        {:test, :bs_get_float2, {:f, fail}, _live, [ctx, sz, _unit, _flags], dst} ->
          bits = case sz do {:integer, n} -> n; {:tr, {:integer, n}, _} -> n; _ -> 64 end
          if Process.get(:float) do
            {["(local.set $mc (ref.cast (ref $mctx) #{val.(ctx)}))",
              "(if (i32.lt_s (i32.sub (i32.shl (array.len (struct.get $mctx 0 (local.get $mc))) (i32.const 3)) (struct.get $mctx 1 (local.get $mc))) (i32.const #{bits})) (then #{jump.(fail)}))",
              "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
              "(local.set $boff (i32.div_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8)))",
              set.(dst, "(struct.new $float (call $read_f64_be (ref.as_non_null (local.get $bsrc)) (local.get $boff)))"),
              "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{bits})))"], false}
          else
            Process.put(:stubs, (Process.get(:stubs) || 0) + 1)
            {["(unreachable) ;; STUB test.bs_get_float2"], true}
          end
        # bs_init_writable: start an empty growable binary (the result lands in x0). Subsequent
        # `<<acc::binary, …>>` appends compile to bs_create_bin with a :private_append segment, which we
        # already lower by copying — so a plain empty $binary is a correct seed.
        op0 when op0 == :bs_init_writable ->
          {[set.({:x, 0}, "(struct.new $binary (array.new_default $bytes (i32.const 0)))")], false}
        {:bs_init_writable} ->
          {[set.({:x, 0}, "(struct.new $binary (array.new_default $bytes (i32.const 0)))")], false}
        {:bs_get_position, ctx, dst, _live} ->
          {[set.(dst, "(ref.i31 (struct.get $mctx 1 (ref.cast (ref $mctx) #{val.(ctx)})))")], false}
        {:bs_set_position, ctx, pos} ->
          {["(struct.set $mctx 1 (ref.cast (ref $mctx) #{val.(ctx)}) #{i32v.(pos)})"], false}
        {:bs_get_tail, ctx, dst, _live} ->
          {["(local.set $mc (ref.cast (ref $mctx) #{val.(ctx)}))",
            "(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
            "(local.set $boff (i32.div_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8)))",
            "(local.set $blen (i32.sub (array.len (local.get $bsrc)) (local.get $boff)))",
            "(local.set $bdst (array.new_default $bytes (local.get $blen)))",
            "(array.copy $bytes $bytes (local.get $bdst) (i32.const 0) (local.get $bsrc) (local.get $boff) (local.get $blen))",
            set.(dst, "(struct.new $binary (ref.as_non_null (local.get $bdst)))")], false}
        {:bs_match, {:f, fail}, ctx, {:commands, cmds}} ->
          setup = ["(local.set $mc (ref.cast (ref $mctx) #{val.(ctx)}))"]
          lines = Enum.flat_map(cmds, fn
            {:ensure_at_least, bits, _unit} ->
              ["(if (i32.lt_s (i32.sub (i32.shl (array.len (struct.get $mctx 0 (local.get $mc))) (i32.const 3)) (struct.get $mctx 1 (local.get $mc))) (i32.const #{bits})) (then #{jump.(fail)}))"]
            {:ensure_exactly, bits} ->
              ["(if (i32.ne (i32.sub (i32.shl (array.len (struct.get $mctx 0 (local.get $mc))) (i32.const 3)) (struct.get $mctx 1 (local.get $mc))) (i32.const #{bits})) (then #{jump.(fail)}))"]
            {:skip, bits} ->
              ["(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{bits})))"]
            {:integer, _live, _flags, size, unit, dst} ->
              nbits = size * unit
              ["(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
               set.(dst, "(ref.i31 (call $bits_read (local.get $bsrc) (struct.get $mctx 1 (local.get $mc)) (i32.const #{nbits})))"),
               "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{nbits})))"]
            {:binary, _live, _flags, size, unit, dst} ->
              nbits = size * unit
              nbytes = div(nbits, 8)
              ["(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
               "(local.set $boff (i32.div_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8)))",
               "(local.set $bdst (array.new_default $bytes (i32.const #{nbytes})))",
               "(array.copy $bytes $bytes (local.get $bdst) (i32.const 0) (local.get $bsrc) (local.get $boff) (i32.const #{nbytes}))",
               set.(dst, "(struct.new $binary (ref.as_non_null (local.get $bdst)))"),
               "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{nbits})))"]
            {:"=:=", _, bits, value} ->
              ["(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
               "(if (i32.ne (call $bits_read (local.get $bsrc) (struct.get $mctx 1 (local.get $mc)) (i32.const #{bits})) (i32.const #{i32_const(value)})) (then #{jump.(fail)}))",
               "(struct.set $mctx 1 (local.get $mc) (i32.add (struct.get $mctx 1 (local.get $mc)) (i32.const #{bits})))"]
            {:get_tail, _live, _unit, dst} ->
              ["(local.set $bsrc (struct.get $mctx 0 (local.get $mc)))",
               "(local.set $boff (i32.div_u (struct.get $mctx 1 (local.get $mc)) (i32.const 8)))",
               "(local.set $blen (i32.sub (array.len (local.get $bsrc)) (local.get $boff)))",
               "(local.set $bdst (array.new_default $bytes (local.get $blen)))",
               "(array.copy $bytes $bytes (local.get $bdst) (i32.const 0) (local.get $bsrc) (local.get $boff) (local.get $blen))",
               set.(dst, "(struct.new $binary (ref.as_non_null (local.get $bdst)))")]
            other -> raise "bs_match cmd in #{mod}.#{name}/#{arity}: #{inspect(other)} (unsupported bitstring match; set STUB=1 to compile this to a trap and continue)"
          end)
          {setup ++ lines, false}
        {:badmatch, _} -> {["(unreachable)"], true}
        {:case_end, _} -> {["(unreachable)"], true}
        :if_end -> {["(unreachable)"], true}
        {:put_list, h, t, d} -> {[set.(d, "(struct.new $cons #{val.(h)} #{val.(t)})")], false}
        {:put_tuple2, d, {:list, elems}} -> {[set.(d, "(array.new_fixed $tuple #{length(elems)} #{Enum.map_join(elems, " ", val)})")], false}
        # update_record (OTP 27): a new Size-element tuple = source tuple with the listed 1-indexed fields
        # overwritten. Tuples are immutable, so build it in one array.new_fixed (indices are constants).
        {:update_record, _hint, size, src, dst, {:list, updates}} ->
          upd = updates |> Enum.chunk_every(2) |> Map.new(fn [idx, v] -> {idx - 1, val.(v)} end)
          elems = Enum.map_join(0..(size - 1), " ", fn i ->
            Map.get(upd, i, "(array.get $tuple (ref.cast (ref $tuple) #{val.(src)}) (i32.const #{i}))")
          end)
          {[set.(dst, "(array.new_fixed $tuple #{size} #{elems})")], false}
        {:try_case_end, _} -> {["(unreachable)"], true}   # no try-clause matched (error path)
        {:get_tuple_element, s, i, d} -> {[set.(d, "(array.get $tuple (ref.cast (ref $tuple) #{val.(s)}) (i32.const #{i}))")], false}
        # element(N, Tuple) — 1-indexed tuple access (BIF form)
        {:bif, :element, _f, [{:integer, n}, src], d} -> {[set.(d, "(array.get $tuple (ref.cast (ref $tuple) #{val.(src)}) (i32.const #{n - 1}))")], false}
        {:bif, :element, _f, [idx, src], d} -> {[set.(d, "(array.get $tuple (ref.cast (ref $tuple) #{val.(src)}) (i32.sub #{i32v.(idx)} (i32.const 1)))")], false}
        {:bif, :tuple_size, _f, [src], d} -> {[set.(d, "(ref.i31 (array.len (ref.cast (ref $tuple) #{val.(src)})))")], false}
        # --- closures ---
        {:make_fun3, {m, fun, far}, _idx, _hash, dst, {:list, free}} ->
          %{idx: cidx} = Map.fetch!(Process.get(:closures), {m, fun, far})
          fvs = if free == [], do: "", else: " " <> Enum.map_join(free, " ", val)
          {[set.(dst, "(struct.new $fun (i32.const #{cidx}) (array.new_fixed $freevars #{length(free)}#{fvs}))")], false}
        {:call_fun, nn} ->
          funref = "(local.get $x#{nn})"
          args = if nn == 0, do: "", else: " " <> Enum.map_join(0..(nn - 1), " ", &"(local.get $x#{&1})")
          {[set.({:x, 0}, "(call_indirect $ftab (type $clos#{nn}) #{funref}#{args} (struct.get $fun 0 (ref.cast (ref $fun) #{funref})))")], false}
        {:call_fun2, _tag, nn, funreg} ->
          funref = val.(funreg)
          args = if nn == 0, do: "", else: " " <> Enum.map_join(0..(nn - 1), " ", &"(local.get $x#{&1})")
          {[set.({:x, 0}, "(call_indirect $ftab (type $clos#{nn}) #{funref}#{args} (struct.get $fun 0 (ref.cast (ref $fun) #{funref})))")], false}
        # --- processes (spawn/send/self/receive) --- (incl. tail-call variants)
        {:call_ext, _ar, {:extfunc, :erlang, :spawn, 1}} ->
          {["(local.set $x0 (struct.new $pid (call $spawn_raw (local.get $x0))))"], false}
        {ce, _ar, {:extfunc, :erlang, :spawn, 1}} when ce in [:call_ext_only] ->
          {["(return (struct.new $pid (call $spawn_raw (local.get $x0))))"], true}
        {:call_ext_last, _ar, {:extfunc, :erlang, :spawn, 1}, _d} ->
          {["(return (struct.new $pid (call $spawn_raw (local.get $x0))))"], true}
        {:call_ext, _ar, {:extfunc, :erlang, :send, 2}} ->
          {["(local.set $x0 (call $send_raw (call $resolve_dest (local.get $x0)) (local.get $x1)))"], false}
        # send(Dest, Msg, Opts) -> like send/2 (options like noconnect/nosuspend are no-ops here); returns ok.
        {:call_ext, _ar, {:extfunc, :erlang, :send, 3}} ->
          {["(call $send_raw (call $resolve_dest (local.get $x0)) (local.get $x1))", set.({:x, 0}, "(global.get $atom_ok)")], false}
        {:call_ext_only, _ar, {:extfunc, :erlang, :send, 2}} ->
          {["(return_call $send_raw (call $resolve_dest (local.get $x0)) (local.get $x1))"], true}
        {:call_ext_last, _ar, {:extfunc, :erlang, :send, 2}, _d} ->
          {["(return_call $send_raw (call $resolve_dest (local.get $x0)) (local.get $x1))"], true}
        # registry + monitors. Process.register(pid, name): x0=pid, x1=name (note arg order).
        # Process.whereis(name): x0=name. :erlang.monitor(:process, pid): x0=:process, x1=pid.
        {:call_ext, _ar, {:extfunc, Process, :register, 2}} ->
          {["(call $register_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x1))) (struct.get $pid 0 (ref.cast (ref $pid) (local.get $x0))))",
            set.({:x, 0}, "(global.get $atom_true)")], false}
        # erlang:register(Name, Pid) -> register a name (note: (Name, Pid) order, unlike Process.register).
        {:call_ext, _ar, {:extfunc, :erlang, :register, 2}} ->
          {["(call $register_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0))) (struct.get $pid 0 (ref.cast (ref $pid) (local.get $x1))))",
            set.({:x, 0}, "(global.get $atom_true)")], false}
        {:call_ext, _ar, {:extfunc, Process, :whereis, 1}} ->
          {["(local.set $x0 (struct.new $pid (call $whereis_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0))))))"], false}
        # erlang:whereis(Name) -> the registered pid, or the atom `undefined` (pid id 0 = not found).
        {ce, _ar, {:extfunc, :erlang, :whereis, 1}} when ce in [:call_ext, :call_ext_only] ->
          e = "(if (result (ref null eq)) (i32.eqz (call $whereis_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0))))) (then (global.get $atom_undefined)) (else (struct.new $pid (call $whereis_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0)))))))"
          if ce == :call_ext, do: {[set.({:x, 0}, e)], false}, else: {["(return #{e})"], true}
        {:call_ext_last, _ar, {:extfunc, :erlang, :whereis, 1}, _} ->
          {["(return (if (result (ref null eq)) (i32.eqz (call $whereis_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0))))) (then (global.get $atom_undefined)) (else (struct.new $pid (call $whereis_raw (struct.get $atom 0 (ref.cast (ref $atom) (local.get $x0))))))))"], true}
        {ce, _ar, {:extfunc, :erlang, :monitor, ma}} when ce in [:call_ext] and ma in [2, 3] ->
          {["(local.set $x0 (struct.new $ref (call $monitor_raw (struct.get $pid 0 (ref.cast (ref $pid) (local.get $x1)))) (i32.const 0)))"], false}
        # demonitor(Ref[, Opts]) -> drop the monitor (and flush a pending DOWN); returns true.
        {ce, _ar, {:extfunc, :erlang, :demonitor, _da}} when ce in [:call_ext, :call_ext_only, :call_ext_last] ->
          {["(call $demonitor_raw (struct.get $ref 0 (ref.cast (ref $ref) (local.get $x0))))",
            set.({:x, 0}, "(global.get $atom_true)")], false}
        # spawn_opt(M, F, Args, Opts) -> a process running apply(M,F,Args). `link` bidir-links; `monitor`
        # makes the result `{Pid, MonRef}` (and sets up the monitor) instead of a bare Pid — proc_lib
        # relies on this. spawn_opt/5 (Node, M, F, Args, Opts) ignores Node. All call forms incl. tails.
        {ce, _ar, {:extfunc, :erlang, :spawn_opt, ar}} when ce in [:call_ext, :call_ext_only] and ar in [4, 5] ->
          e = spawn_opt_expr.(ar)
          if ce == :call_ext, do: {[set.({:x, 0}, e)], false}, else: {["(return #{e})"], true}
        {:call_ext_last, _ar, {:extfunc, :erlang, :spawn_opt, ar}, _} when ar in [4, 5] ->
          {["(return #{spawn_opt_expr.(ar)})"], true}
        # make_fun(M, F, Arity) -> a fun whose table slot is the arity-A trampoline (base+A), capturing M,F.
        {:call_ext, _ar, {:extfunc, :erlang, :make_fun, 3}} ->
          {[set.({:x, 0}, "(struct.new $fun (i32.add (i32.const #{Process.get(:tramp_base)}) (i31.get_s (ref.cast (ref i31) (local.get $x2)))) (array.new_fixed $freevars 2 (local.get $x0) (local.get $x1)))")], false}
        # hibernate(M, F, A): suspend the process; on the next message, resume via apply(M,F,A).
        {_ce, _ar, {:extfunc, :erlang, :hibernate, 3}} ->
          {["(local.set $hmod (local.get $x0))", "(local.set $hfun (local.get $x1))", "(local.set $hargs (local.get $x2))",
            "(call $recv_wait)", "(return_call $erlang_apply_3 (local.get $hmod) (local.get $hfun) (local.get $hargs))"], true}
        {:call_ext_last, _ar, {:extfunc, :erlang, :hibernate, 3}, _} ->
          {["(local.set $hmod (local.get $x0))", "(local.set $hfun (local.get $x1))", "(local.set $hargs (local.get $x2))",
            "(call $recv_wait)", "(return_call $erlang_apply_3 (local.get $hmod) (local.get $hfun) (local.get $hargs))"], true}
        # apply(M, F, ArgsList): dispatch on list length to apply_N (the generic apply helper).
        {ce, _ar, {:extfunc, :erlang, :apply, 3}} when ce in [:call_ext, :call_ext_only] ->
          if ce == :call_ext,
            do: {[set.({:x, 0}, "(call $erlang_apply_3 (local.get $x0) (local.get $x1) (local.get $x2))")], false},
            else: {["(return_call $erlang_apply_3 (local.get $x0) (local.get $x1) (local.get $x2))"], true}
        {:call_ext_last, _ar, {:extfunc, :erlang, :apply, 3}, _} ->
          {["(return_call $erlang_apply_3 (local.get $x0) (local.get $x1) (local.get $x2))"], true}
        {:call_ext, _ar, {:extfunc, :erlang, :spawn_link, 1}} ->
          {["(local.set $x0 (struct.new $pid (call $spawn_link_raw (local.get $x0))))"], false}
        {:call_ext_only, _ar, {:extfunc, :erlang, :spawn_link, 1}} ->
          {["(return (struct.new $pid (call $spawn_link_raw (local.get $x0))))"], true}
        {:call_ext, _ar, {:extfunc, :erlang, :exit, 1}} -> {["(call $exit_raw (local.get $x0))", "(unreachable)"], true}
        {:call_ext_last, _ar, {:extfunc, :erlang, :exit, 1}, _d} -> {["(call $exit_raw (local.get $x0))", "(unreachable)"], true}
        {:call_ext_only, _ar, {:extfunc, :erlang, :exit, 1}} -> {["(call $exit_raw (local.get $x0))", "(unreachable)"], true}
        # process_flag(:trap_exit, v) — only flag we support; returns old value (assume false)
        {:call_ext, _ar, {:extfunc, :erlang, :process_flag, 2}} ->
          {["(call $set_trap_exit (ref.eq (local.get $x1) (global.get $atom_true)))",
            set.({:x, 0}, "(global.get $atom_false)")], false}
        {:bif, :self, _f, [], d} -> {[set.(d, "(struct.new $pid (call $self_raw))")], false}
        # the `send` opcode (Pid ! Msg): dest in x0, message in x1; result (the message) -> x0.
        :send -> {["(local.set $x0 (call $send_raw (call $resolve_dest (local.get $x0)) (local.get $x1)))"], false}
        # process dictionary: get(K) (absent -> the atom `undefined`), put(K,V) (returns old or undefined),
        # erase(K) (not yet — falls through). Keys are interned atoms => stable identity in the host Map.
        {:bif, :get, _f, [k], d} ->
          {["(local.set $tmp (call $pdict_get #{val.(k)}))",
            set.(d, "(if (result (ref null eq)) (ref.is_null (local.get $tmp)) (then (global.get $atom_undefined)) (else (local.get $tmp)))")], false}
        {ce, _ar, {:extfunc, :erlang, :get, 1}} when ce in [:call_ext] ->
          {["(local.set $x0 (call $pdict_get (local.get $x0)))",
            set.({:x, 0}, "(if (result (ref null eq)) (ref.is_null (local.get $x0)) (then (global.get $atom_undefined)) (else (local.get $x0)))")], false}
        {ce, _ar, {:extfunc, :erlang, :put, 2}} when ce in [:call_ext] ->
          {["(local.set $x0 (call $pdict_put (local.get $x0) (local.get $x1)))",
            set.({:x, 0}, "(if (result (ref null eq)) (ref.is_null (local.get $x0)) (then (global.get $atom_undefined)) (else (local.get $x0)))")], false}
        # monotonic_time([Unit]) -> a monotonically increasing integer (a counter; the supervisor only
        # uses it to compare restart times within a window, so the source just needs to be monotonic).
        {ce, _ar, {:extfunc, :erlang, mt, _n}} when ce in [:call_ext, :call_ext_only] and mt in [:monotonic_time, :system_time, :unique_integer] ->
          e = "(block (result (ref null eq)) (global.set $monotime (i32.add (global.get $monotime) (i32.const 1))) (ref.i31 (global.get $monotime)))"
          if ce == :call_ext, do: {[set.({:x, 0}, e)], false}, else: {["(return #{e})"], true}
        {:call_ext_last, _ar, {:extfunc, :erlang, mt, _n}, _} when mt in [:monotonic_time, :system_time, :unique_integer] ->
          {["(return (block (result (ref null eq)) (global.set $monotime (i32.add (global.get $monotime) (i32.const 1))) (ref.i31 (global.get $monotime))))"], true}
        # node()/node(_) -> the single node we run on. (No distribution.)
        {gop, :node, _f, _l, _args, d} when gop in [:gc_bif, :bif] -> {[set.(d, "(global.get $atom_#{sanitize(:"nonode@nohost")})")], false}
        {:bif, :node, _f, _args, d} -> {[set.(d, "(global.get $atom_#{sanitize(:"nonode@nohost")})")], false}
        {ce, _ar, {:extfunc, :erlang, :node, n}} when ce in [:call_ext] and n in [0, 1] ->
          {[set.({:x, 0}, "(global.get $atom_#{sanitize(:"nonode@nohost")})")], false}
        # pids and references are distinct boxed types
        {:test, :is_pid, {:f, f}, [s]} -> {["(if (i32.eqz (ref.test (ref $pid) #{val.(s)})) (then #{jump.(f)}))"], false}
        {:test, :is_reference, {:f, f}, [s]} -> {["(if (i32.eqz (ref.test (ref $ref) #{val.(s)})) (then #{jump.(f)}))"], false}
        {:test, :is_port, {:f, f}, [_s]} -> {[jump.(f)], true}
        {gop, :make_ref, _f, _l, [], d} when gop in [:gc_bif, :bif] ->
          {["(global.set $refctr (i32.add (global.get $refctr) (i32.const 1)))", set.(d, "(struct.new $ref (global.get $refctr) (i32.const 0))")], false}
        {:bif, :make_ref, _f, [], d} ->
          {["(global.set $refctr (i32.add (global.get $refctr) (i32.const 1)))", set.(d, "(struct.new $ref (global.get $refctr) (i32.const 0))")], false}
        {:call_ext, _ar, {:extfunc, :erlang, :make_ref, 0}} ->
          {["(global.set $refctr (i32.add (global.get $refctr) (i32.const 1)))", set.({:x, 0}, "(struct.new $ref (global.get $refctr) (i32.const 0))")], false}
        # --- exceptions ---  ($htgt = active handler's block index; -1 = disarmed)
        # Nesting is handled via a handler "stack" threaded through BEAM's per-try Y register:
        # `try` saves the parent handler into Y and arms its own; `try_end` (success path) and
        # `try_case` (exception-landing path) both restore the parent. So a throw inside a catch
        # body unwinds to the enclosing try, exactly like BEAM's catch stack.
        {:try, {:y, k}, {:f, l}} ->
          {["(local.set $y#{k} (ref.i31 (local.get $htgt)))", "(local.set $htgt (i32.const #{blk.(l)}))"], false}
        {:try_end, {:y, k}} ->
          {["(local.set $htgt (i31.get_s (ref.cast (ref i31) (local.get $y#{k}))))"], false}
        {:try_case, {:y, k}} ->   # first op of the handler block; x0/x1/x2 already = class/reason/trace
          {["(local.set $excf (i32.const 0))", "(local.set $htgt (i31.get_s (ref.cast (ref i31) (local.get $y#{k}))))"], false}
        # old-style `catch Expr`: like try, but catch_end runs on BOTH the normal and exception paths.
        # $excf (set by the footer) tells catch_end which; on exception it transforms (class,reason,trace)
        # into the catch value (throw→reason, exit→{'EXIT',reason}, error→{'EXIT',{reason,trace}}).
        {:catch, {:y, k}, {:f, l}} ->
          {["(local.set $y#{k} (ref.i31 (local.get $htgt)))", "(local.set $htgt (i32.const #{blk.(l)}))"], false}
        {:catch_end, {:y, k}} ->
          {["(if (local.get $excf) (then (local.set $excf (i32.const 0)) (local.set $x0 " <>
              "(if (result (ref null eq)) (ref.eq (local.get $x0) (global.get $atom_throw)) (then (local.get $x1)) " <>
              "(else (if (result (ref null eq)) (ref.eq (local.get $x0) (global.get $atom_exit)) " <>
              "(then (array.new_fixed $tuple 2 (global.get $atom_EXIT) (local.get $x1))) " <>
              "(else (array.new_fixed $tuple 2 (global.get $atom_EXIT) (array.new_fixed $tuple 2 (local.get $x1) (local.get $x2))))))))))",
            "(local.set $htgt (i31.get_s (ref.cast (ref i31) (local.get $y#{k}))))"], false}
        {ce, _ar, {:extfunc, :erlang, :throw, 1}} when ce in [:call_ext, :call_ext_only] ->
          {["(throw $exc (global.get $atom_throw) (local.get $x0) (ref.null none))"], true}
        {:call_ext_last, _ar, {:extfunc, :erlang, :throw, 1}, _} ->
          {["(throw $exc (global.get $atom_throw) (local.get $x0) (ref.null none))"], true}
        {ce, _ar, {:extfunc, :erlang, :error, _ea}} when ce in [:call_ext, :call_ext_only] ->
          {["(throw $exc (global.get $atom_error) (local.get $x0) (ref.null none))"], true}
        {:call_ext_last, _ar, {:extfunc, :erlang, :error, _ea}, _} ->
          {["(throw $exc (global.get $atom_error) (local.get $x0) (ref.null none))"], true}
        {:bif, :raise, _f, _args, _d} ->   # re-raise the caught exception (x0/x1/x2)
          {["(throw $exc (local.get $x0) (local.get $x1) (local.get $x2))"], true}
        # build_stacktrace: materialize the stacktrace into x0. We don't track stacktraces, so [] (a
        # valid empty stacktrace). raw_raise: re-raise class/reason/stacktrace (x0/x1/x2) as $exc.
        :build_stacktrace -> {[set.({:x, 0}, "(ref.null none)")], false}
        :raw_raise -> {["(throw $exc (local.get $x0) (local.get $x1) (local.get $x2))"], true}
        # --- floats: f64 register file ($fr0..), boxed as a $float term in x/y registers ---
        {:fconv, src, {:fr, n}} -> {["(local.set $fr#{n} (call $to_f64 #{val.(src)}))"], false}
        {:fmove, {:float, lit}, {:fr, n}} -> {["(local.set $fr#{n} (f64.const #{float_lit(lit)}))"], false}
        {:fmove, {:fr, a}, {:fr, b}} -> {["(local.set $fr#{b} #{frval.({:fr, a})})"], false}
        {:fmove, {:fr, n}, dst} -> {[set.(dst, "(struct.new $float #{frval.({:fr, n})})")], false}
        {:fmove, src, {:fr, n}} -> {["(local.set $fr#{n} (call $to_f64 #{val.(src)}))"], false}
        {:bif, fop, _f, [a, b], {:fr, n}} when fop in [:fadd, :fsub, :fmul, :fdiv] ->
          o = case fop do :fadd -> "add"; :fsub -> "sub"; :fmul -> "mul"; :fdiv -> "div" end
          {["(local.set $fr#{n} (f64.#{o} #{frval.(a)} #{frval.(b)}))"], false}
        {:loop_rec, {:f, e}, dst} ->
          {["(if (i32.eqz (call $recv_has)) (then #{jump.(e)}))", set.(dst, "(call $recv_cur)")], false}
        :remove_message -> {["(call $recv_remove)"], false}
        {:loop_rec_end, {:f, l}} -> {["(call $recv_advance)", jump.(l)], true}
        {:wait, {:f, l}} -> {["(call $recv_wait)", jump.(l)], true}
        # receive…after: block for a message then re-scan (label l). The finite timeout is NOT yet
        # honored (no timer) — correct for `after :infinity` and any path where a message arrives.
        {:wait_timeout, {:f, l}, _timeout} -> {["(call $recv_wait)", jump.(l)], true}
        :timeout -> {[], false}          # timeout-fired landing (unreached while we always block)
        {:timeout, _} -> {[], false}
        # selective-receive markers (OTP 26+ optimization): no-ops for our linear mailbox scan.
        {:recv_marker_reserve, _} -> {[], false}
        {:recv_marker_bind, _, _} -> {[], false}
        {:recv_marker_use, _} -> {[], false}
        {:recv_marker_clear, _} -> {[], false}
        {:test, :is_tagged_tuple, {:f, f}, [s, ar, {:atom, tag}]} ->
          {["(if (i32.eqz (ref.test (ref $tuple) #{val.(s)})) (then #{jump.(f)}))",
            "(if (i32.ne (array.len (ref.cast (ref $tuple) #{val.(s)})) (i32.const #{ar})) (then #{jump.(f)}))",
            "(if (i32.eqz (ref.eq (array.get $tuple (ref.cast (ref $tuple) #{val.(s)}) (i32.const 0)) (global.get $atom_#{sanitize(tag)}))) (then #{jump.(f)}))"], false}
        # tail calls -> real Wasm `return_call` (NOT `(return (call …))`, which grows the stack).
        # Load-bearing: deep tail recursion (and the ~5KB JSPI process-stack floor) depend on it.
        # dynamic dispatch: mod.fun(args) -> apply_last/apply. args x0..x[N-1], mod x[N], fun x[N+1].
        # Routed through a generated $apply_N that switches on (mod, fun) over closed-world functions.
        {:apply, n} -> {["(local.set $x0 (call $apply_#{n} #{Enum.map_join(0..(n + 1), " ", &"(local.get $x#{&1})")}))"], false}
        {:apply_last, n, _d} -> {["(return_call $apply_#{n} #{Enum.map_join(0..(n + 1), " ", &"(local.get $x#{&1})")})"], true}
        {:call, _ar, {m, f, a}} -> {["(local.set $x0 (call #{fq(m, f, a)} #{cargs.(a)}))"], false}
        {:call_only, _ar, {m, f, a}} -> {["(return_call #{fq(m, f, a)} #{cargs.(a)})"], true}
        {:call_last, _ar, {m, f, a}, _d} -> {["(return_call #{fq(m, f, a)} #{cargs.(a)})"], true}
        {:call_ext, _ar, {:extfunc, m, f, a}} -> {["(local.set $x0 (call #{fq(m, f, a)} #{cargs.(a)}))"], false}
        {:call_ext_only, _ar, {:extfunc, m, f, a}} -> {["(return_call #{fq(m, f, a)} #{cargs.(a)})"], true}
        {:call_ext_last, _ar, {:extfunc, m, f, a}, _d} -> {["(return_call #{fq(m, f, a)} #{cargs.(a)})"], true}
        :return -> {["(return (local.get $x0))"], true}
        {:jump, {:f, f}} -> {[jump.(f)], true}
        {:select_val, src, {:f, fail}, {:list, pairs}} ->
          chunks = Enum.chunk_every(pairs, 2)
          sb = int_bounds(src)
          # SPECIALIZE: integer src with bounded i31 range + all-integer cases (e.g. Jason's per-byte
          # switch) -> a direct i32.eq chain (src cast ONCE into $midx). No term_eq/term_compare storm.
          sel =
            if sb && fits_i31?(sb) && Enum.all?(chunks, fn [v, _] -> match?({:integer, _}, v) end) do
              ["(local.set $midx #{i32v.(src)})"] ++
                Enum.map(chunks, fn [{:integer, n}, {:f, l}] -> "(if (i32.eq (local.get $midx) (i32.const #{n})) (then #{jump.(l)}))" end)
            else
              Enum.map(chunks, fn [v, {:f, l}] -> "(if #{term_eq(val.(src), val.(v))} (then #{jump.(l)}))" end)
            end
          {sel ++ [jump.(fail)], true}
        {:select_tuple_arity, src, {:f, fail}, {:list, pairs}} ->
          sel = pairs |> Enum.chunk_every(2) |> Enum.map(fn [ar, {:f, l}] ->
            "(if (if (result i32) (ref.test (ref $tuple) #{val.(src)}) (then (i32.eq (array.len (ref.cast (ref $tuple) #{val.(src)})) (i32.const #{ar}))) (else (i32.const 0))) (then #{jump.(l)}))"
          end)
          {sel ++ [jump.(fail)], true}
        {:swap, a, b} -> {["(local.set $tmp #{val.(a)})", set.(a, val.(b)), set.(b, "(local.get $tmp)")], false}
        {:func_info, _, _, _} -> {["(unreachable)"], true}
        {:allocate, _, _} -> {[], false}
        {:allocate_zero, _, _} -> {[], false}
        {:allocate_heap, _, _, _} -> {[], false}
        {:init_yregs, _} -> {[], false}
        {:trim, _, _} -> {[], false}
        {:deallocate, _} -> {[], false}
        {:test_heap, _, _} -> {[], false}
        {:line, _} -> {[], false}
        :int_code_end -> {[], false}
        other ->
          # STUB mode: lower an unsupported opcode to a trap so the whole module still
          # compiles. Only unexercised paths (non-list Enum fns, try/apply/float) hit it.
          if Process.get(:stub) do
            tag =
              case other do
                {t, op, _, _, _, _} when t in [:gc_bif] -> "#{t}.#{op}"
                {t, op, _, _, _} when t in [:bif] -> "#{t}.#{op}"
                {:test, op, _, _} -> "test.#{op}"
                {:test, op, _, _, _} -> "test.#{op}"
                {:test, op, _, _, _, _} -> "test.#{op}"
                t when is_tuple(t) -> elem(t, 0)
                t -> t
              end
            Process.put(:stubs, (Process.get(:stubs) || 0) + 1)
            {["(unreachable) ;; STUB #{tag}"], true}
          else
            raise "unhandled opcode in #{mod}.#{name}/#{arity}: #{inspect(other)} (set STUB=1 to compile this to a trap and continue)"
          end
      end
    end

    # A closure target takes (self, call-args…); free vars travel in `self` and are
    # copied into the high registers x[N..] by the prologue. A normal function takes its
    # args directly. call_arity N = total arity - num free vars.
    # Only a pure lambda (captured, never called directly) uses the (self, args…) form
    # with a free-var prologue. A dual target keeps its normal signature + a wrapper.
    cl = Process.get(:closures, %{}) |> Map.get({mod, name, arity})
    clos = if cl && not cl.dual, do: cl, else: nil
    call_arity = if clos, do: clos.n, else: arity
    xstart = call_arity
    func_decl =
      if clos do
        ps = if call_arity > 0, do: Enum.map_join(0..(call_arity - 1), "", &" (param $x#{&1} (ref null eq))"), else: ""
        "  (func #{fn_name} (type $clos#{call_arity}) (param $self (ref null eq))#{ps} (result (ref null eq))"
      else
        params = if arity == 0, do: "", else: " " <> Enum.map_join(0..(arity - 1), " ", &"(param $x#{&1} (ref null eq))")
        "  (func #{fn_name}#{params} (result (ref null eq))"
      end
    prologue =
      if clos && clos.f > 0 do
        Enum.map(0..(clos.f - 1), fn i ->
          "    (local.set $x#{call_arity + i} (array.get $freevars (struct.get $fun 1 (ref.cast (ref $fun) (local.get $self))) (i32.const #{i})))"
        end)
      else
        []
      end

    nexts = (tl(blocks) ++ [nil])
    # try-mode: wrap the dispatch loop in `(loop $reenter (block $caught (try_table …)))`.
    # An armed `try` sets $htgt to its catch block index; a thrown $exc lands in $caught,
    # which stages (class,reason,trace)→(x0,x1,x2) and either re-dispatches to $htgt or re-throws.
    loop_open =
      if has_try do
        ["    (loop $reenter",
         "      (block $caught (result (ref null eq) (ref null eq) (ref null eq))",
         "      (try_table (catch $exc $caught)",
         "    (loop $dispatch", "      (block $b_default"]
      else
        ["    (loop $dispatch", "      (block $b_default"]
      end
    header =
      [func_decl] ++
        (if maxx >= xstart, do: Enum.map(xstart..maxx, &"    (local $x#{&1} (ref null eq))"), else: []) ++
        (if maxy >= 0, do: Enum.map(0..maxy, &"    (local $y#{&1} (ref null eq))"), else: []) ++
        ["    (local $blk i32) (local $tmpc (ref null $cons)) (local $tmp (ref null eq)) (local $midx i32) (local $mn (ref null $mnode))",
         "    (local $boff i32) (local $blen i32) (local $bdst (ref null $bytes)) (local $bsrc (ref null $bytes)) (local $mc (ref null $mctx))",
         "    (local $tmptup (ref null $tuple)) (local $hmod (ref null eq)) (local $hfun (ref null eq)) (local $hargs (ref null eq))"] ++
        (if has_try, do: ["    (local $htgt i32) (local $excf i32)"], else: []) ++
        (if maxfr >= 0, do: Enum.map(0..maxfr, &"    (local $fr#{&1} f64)"), else: []) ++
        (case Process.get(:reds) do
           nil -> []
           b -> ["    (global.set $reds (i32.sub (global.get $reds) (i32.const 1)))",
                 "    (if (i32.le_s (global.get $reds) (i32.const 0)) (then (call $yield) (global.set $reds (i32.const #{b}))))"]
         end) ++
        prologue ++
        (if has_try, do: ["    (local.set $htgt (i32.const -1))"], else: []) ++
        ["    (local.set $blk (i32.const #{entry_idx}))"] ++
        loop_open ++
        Enum.map((n - 1)..0, &"      (block $b#{&1}") ++
        ["        (br_table " <> Enum.map_join(0..(n - 1), " ", &"$b#{&1}") <> " $b_default (local.get $blk)))"]

    body =
      Enum.zip([blocks, nexts, 0..(n - 1)]) |> Enum.flat_map(fn {{label, ops}, next, bi} ->
        {lines, term} =
          Enum.reduce_while(ops, {[], false}, fn op, {acc, _} ->
            {ls, t} = emit.(op)
            if t, do: {:halt, {acc ++ ls, true}}, else: {:cont, {acc ++ ls, false}}
          end)
        lines = if term, do: lines, else: lines ++ [(if next, do: jump.(elem(next, 0)), else: "(unreachable)")]
        ["      ;; --- block #{bi} (label #{label}) ---"] ++ Enum.map(lines, &("      " <> &1)) ++ ["      )"]
      end)

    footer =
      if has_try do
        ["      (unreachable)",          # default-block body (dead)
         "    )",                        # close (loop $dispatch
         "      )",                      # close (try_table
         "      (unreachable)",          # try body never falls through; satisfies $caught result
         "      )",                      # close (block $caught — lands here on a thrown $exc
         "      (local.set $x2) (local.set $x1) (local.set $x0)",  # trace, reason, class (stack top→down)
         "      (if (i32.ge_s (local.get $htgt) (i32.const 0))",
         "        (then (local.set $excf (i32.const 1)) (local.set $blk (local.get $htgt)) (br $reenter))",  # mark exception; try_case/catch_end consume $excf
         "        (else (throw $exc (local.get $x0) (local.get $x1) (local.get $x2))))",
         "    )",                        # close (loop $reenter
         "    (unreachable))"]           # close (func
      else
        ["      (unreachable)", "    )", "    (unreachable))"]
      end

    (header ++ body ++ footer) |> Enum.join("\n")
  end

  # operand -> term-valued WAT
  defp operand({:tr, reg, _}), do: operand(reg)
  defp operand({:x, n}), do: "(local.get $x#{n})"
  defp operand({:y, n}), do: "(local.get $y#{n})"
  defp operand({:integer, n}), do: int_literal(n)
  # a bare float literal used as a VALUE (function arg, list/tuple element) → a boxed $float. (Float
  # literals in arithmetic go through fconv/fmove + float registers; this is the non-register path.)
  defp operand({:float, f}), do: "(struct.new $float (f64.const #{float_lit(f)}))"
  defp operand(nil), do: "(ref.null none)"                       # bare nil operand = the empty list []
  defp operand({:atom, nil}), do: "(global.get $atom_nil)"       # the atom nil (Elixir's nil) — distinct
  defp operand({:atom, a}), do: "(global.get $atom_#{sanitize(a)})"
  defp operand({:literal, term}), do: materialize(term)
  defp operand(o) do
    if Process.get(:stub) do
      # Unknown operand SHAPE under STUB mode: emit a trap and COUNT it, exactly like an
      # opcode-level stub. Never emit a usable nil (the old "(ref.null none)") — that would
      # flow on as a silent wrong value, turning a miscompile into a lie instead of an honest
      # trap (and it would not increment the STUBS meter, so it'd hide as "0 stubs"). The
      # block comment is inert; a ;; line comment would swallow the enclosing expression.
      Process.put(:stubs, (Process.get(:stubs) || 0) + 1)
      "(unreachable) (; STUB operand ;)"
    else
      raise "operand: #{inspect(o)} — unsupported operand shape (set STUB=1 to trap+count instead)"
    end
  end

  # ── type-driven specialization, from beam_disasm's typed registers ──
  # `{:tr, reg, {:t_integer, {lo,hi}}}` is a bounded integer; `{:integer, n}` a literal (point bound);
  # `{:t_integer, :any}` an unbounded integer; `{:t_number, _}` could be a float (NOT specializable).
  @i31_lo -1_073_741_824
  @i31_hi 1_073_741_823
  defp int_bounds({:integer, n}), do: {n, n}
  defp int_bounds({:tr, _, {:t_integer, {lo, hi}}}) when is_integer(lo) and is_integer(hi), do: {lo, hi}
  defp int_bounds(_), do: nil
  defp int_typed?({:integer, _}), do: true
  defp int_typed?({:tr, _, {:t_integer, _}}), do: true
  defp int_typed?(_), do: false
  # result interval of +/-/* on two integer intervals; nil unless BOTH operands are bounded.
  defp arith_bounds(o, a1, a2) do
    case {int_bounds(a1), int_bounds(a2)} do
      {{lo1, hi1}, {lo2, hi2}} ->
        case o do
          :+ -> {lo1 + lo2, hi1 + hi2}
          :- -> {lo1 - hi2, hi1 - lo2}
          :* -> ps = for x <- [lo1, hi1], y <- [lo2, hi2], do: x * y
                {Enum.min(ps), Enum.max(ps)}
          _ -> nil
        end
      _ -> nil
    end
  end
  # provably representable as a bare i31 immediate (so the op can be inline i32, no helper, no box).
  defp fits_i31?({lo, hi}), do: lo >= @i31_lo and hi <= @i31_hi
  defp fits_i31?(_), do: false

  defp i32val({:integer, n}), do: "(i32.const #{n})"
  defp i32val({:tr, reg, _}), do: i32val(reg)
  defp i32val(reg), do: "(i31.get_s (ref.cast (ref i31) #{operand(reg)}))"

  # i64-valued operand: integer literals (which may exceed 32 bits) as i64.const; a register
  # is an i31 term sign-extended to i64. For bitwise ops that need >32-bit width.
  defp i64val({:integer, n}), do: "(i64.const #{n})"
  defp i64val({:tr, reg, _}), do: i64val(reg)
  defp i64val(reg), do: "(i64.extend_i32_s (i31.get_s (ref.cast (ref i31) #{operand(reg)})))"

  # Erlang `==`/`=:=` as an i32 (1/0), given two already-rendered term operands. In bignum mode
  # two equal-valued integers may be *distinct* boxed $big structs, so a bare ref.eq false-negatives:
  # treat them equal if ref.eq OR (both integers AND $int_cmp == 0). Non-integer terms collapse
  # back to ref.eq (unchanged behavior, and the non-bignum default).
  defp term_eq(a, b) do
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

  # f64 expression -> integer term. In bignum mode use the i64 tier ($narrow boxes to i31/$i64; traps
  # honestly past 2^63 rather than producing a wrong i32-truncated value). Otherwise the i32 fast path.
  defp f64_to_int(fexpr) do
    if Process.get(:bignum),
      do: "(call $narrow (i64.trunc_f64_s #{fexpr}))",
      else: "(ref.i31 (i32.trunc_f64_s #{fexpr}))"
  end

  defp bif(:+), do: "add"
  defp bif(:-), do: "sub"
  defp bif(:*), do: "mul"
  defp bif(:div), do: "div"
  defp bif(:rem), do: "rem"
  defp bif(o), do: raise("bif #{o}")

  # comparison op -> an i32 (1/0) expression, for the boolean-valued bif form
  # type-specialized 3-way compare (<0/0/>0). Bounded small ints -> inline i32 sign (no call);
  # proven integers -> $int_cmp; otherwise the generic $term_compare. Hot: byte/guard comparisons.
  defp cmp3(a, b) do
    ba = int_bounds(a); bb = int_bounds(b)
    cond do
      ba && bb && fits_i31?(ba) && fits_i31?(bb) ->
        "(i32.sub (i32.gt_s #{i32val(a)} #{i32val(b)}) (i32.lt_s #{i32val(a)} #{i32val(b)}))"
      int_typed?(a) and int_typed?(b) -> "(call $int_cmp #{operand(a)} #{operand(b)})"
      true -> "(call $term_compare #{operand(a)} #{operand(b)})"
    end
  end

  defp bool_cmp(op, a, b) do
    eq = term_eq(operand(a), operand(b))
    case op do
      o when o in [:"=:=", :==] -> eq
      o when o in [:"=/=", :"/="] -> "(i32.eqz #{eq})"
      :< -> "(i32.lt_s #{cmp3(a, b)} (i32.const 0))"
      :> -> "(i32.gt_s #{cmp3(a, b)} (i32.const 0))"
      :">=" -> "(i32.ge_s #{cmp3(a, b)} (i32.const 0))"
      :"=<" -> "(i32.le_s #{cmp3(a, b)} (i32.const 0))"
    end
  end

  # full WAT i32 instruction suffix for each gc_bif arithmetic/bitwise op
  defp wasmop(:+), do: "add"
  defp wasmop(:-), do: "sub"
  defp wasmop(:*), do: "mul"
  defp wasmop(:div), do: "div_s"
  defp wasmop(:rem), do: "rem_s"
  defp wasmop(:band), do: "and"
  defp wasmop(:bor), do: "or"
  defp wasmop(:bxor), do: "xor"
  defp wasmop(:bsl), do: "shl"
  defp wasmop(:bsr), do: "shr_s"
  defp wasmop(o), do: raise("wasmop #{o}")

  defp sanitize(name) when is_atom(name), do: sanitize(Atom.to_string(name))
  # injective: keep [A-Za-z0-9_]; escape every other char as _<code>_ so distinct atoms
  # (e.g. :+, :-, :*) get distinct names (no global-name / function-name collisions).
  defp sanitize(name) when is_binary(name) do
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
  defp atoms_json(atoms) do
    inner = Enum.map_join(atoms, ",", fn a ->
      s = Atom.to_string(a) |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
      "\"#{s}\""
    end)
    "[#{inner}]"
  end

  defp partition(instrs) do
    {blocks, last} =
      Enum.reduce(instrs, {[], nil}, fn
        {:label, l}, {bs, cur} -> {push(bs, cur), {l, []}}
        _i, {bs, nil} -> {bs, nil}
        i, {bs, {l, ops}} -> {bs, {l, [i | ops]}}
      end)
    push(blocks, last) |> Enum.reverse() |> Enum.map(fn {l, ops} -> {l, Enum.reverse(ops)} end)
  end
  defp push(bs, nil), do: bs
  defp push(bs, b), do: [b | bs]

  defp max_regs(instrs, arity) do
    regs = Enum.flat_map(instrs, &regs_in/1)
    {Enum.reduce(regs, arity - 1, fn {:x, n}, m -> max(m, n); _, m -> m end),
     Enum.reduce(regs, -1, fn {:y, n}, m -> max(m, n); _, m -> m end)}
  end
  # trim N renumbers Y registers (logical yK becomes physical y(K+shift)). Resolve
  # statically per block: drop each trim, shift subsequent Y references down.
  defp resolve_trims(ops) do
    {rev, _} =
      Enum.reduce(ops, {[], 0}, fn
        {:trim, k, _}, {acc, shift} -> {acc, shift + k}
        op, {acc, 0} -> {[op | acc], 0}
        op, {acc, shift} -> {[shift_y(op, shift) | acc], shift}
      end)
    Enum.reverse(rev)
  end
  defp shift_y({:y, k}, s), do: {:y, k + s}
  defp shift_y({:literal, _} = l, _), do: l
  defp shift_y(t, s) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&shift_y(&1, s)) |> List.to_tuple()
  defp shift_y(l, s) when is_list(l), do: Enum.map(l, &shift_y(&1, s))
  defp shift_y(x, _), do: x

  # ---- function-level DCE: reachable closure from the exported entry points ----
  defp export_seeds(mods) do
    case System.get_env("EXPORTS") do
      nil -> legacy_seeds(mods)
      spec ->
        pm = Process.get(:primary_mod)
        spec |> String.split(";", trim: true) |> Enum.map(fn s ->
          [name, sig] = String.split(s, ":", parts: 2)
          [args_s, _ret] = String.split(sig, "->")
          a = if String.trim(args_s) == "", do: 0, else: length(String.split(args_s, ",", trim: true))
          {pm, String.to_atom(String.trim(name)), a}
        end)
    end
  end
  defp legacy_seeds(mods) do
    Enum.flat_map(mods, fn m ->
      sp = case m do
        Sort -> [{:sort, 1}]; Expr -> [{:demo, 1}]; Account -> [{:demo, 1}]
        AccountAbi -> [{:transition_balance, 4}, {:transition_status, 4}]
        Smoke -> [{:add, 2}, {:dbl, 1}, {:fact, 1}, {:fib, 1}]; Lists -> [{:sumto, 1}]
        _ -> []
      end
      Enum.map(sp, fn {f, a} -> {m, f, a} end)
    end)
  end

  defp reachable(user, seeds) do
    by_key = Map.new(user, fn {m, {:function, n, a, _, _} = f} -> {{m, n, a}, f} end)
    by_arity = Map.keys(by_key) |> Enum.group_by(fn {_m, _f, a} -> a end)
    do_reach(seeds, MapSet.new(), by_key, by_arity)
  end
  defp do_reach([], seen, _bk, _ba), do: seen
  defp do_reach([k | rest], seen, bk, ba) do
    cond do
      MapSet.member?(seen, k) or not Map.has_key?(bk, k) -> do_reach(rest, seen, bk, ba)
      true ->
        {:function, _, _, _, is} = Map.fetch!(bk, k)
        # edge_refs covers direct/ext calls + make_fun3; literal_funs_in covers CAPTURED funs
        # (`&Mod.f/a`, `&abs/1`) which the BEAM stores as constant fun values — also roots, else
        # their target bodies get pruned and the apply/trampoline dispatch falls to (unreachable).
        # Float.floor/ceil/round at precision 0 are shimmed as LEAVES (see float_builtins), so don't
        # follow their BEAM edges into the IEEE bit-decomposition machinery (Float.round/3 etc.).
        targets =
          if k in [{Float, :floor, 2}, {Float, :ceil, 2}, {Float, :round, 2}, {Req.Finch, :run, 1}],
            do: [],   # Req.Finch.run/1 is overridden (the adapter) → a leaf, so the ssl/inet/pool subtree is pruned
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
  defp apply_targets(is, ba) do
    arities = Enum.flat_map(is, fn {:apply, n} -> [n]; {:apply_last, n, _} -> [n]; _ -> [] end) |> Enum.uniq()
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
  defp reg_const_atoms(is, k) do
    writes = Enum.flat_map(is, &reg_writes/1) |> Enum.filter(fn {reg, _} -> reg == {:x, k} end)
    atoms = for {_reg, {:const_atom, a}} <- writes, do: a
    all_const? = writes != [] and Enum.all?(writes, fn {_reg, src} -> match?({:const_atom, _}, src) end)
    {Enum.uniq(atoms), all_const?}
  end
  # {dest_reg, source} for instructions that write a register; source is {:const_atom, a} or :other.
  defp reg_writes({:move, {:atom, a}, {:x, _} = d}), do: [{d, {:const_atom, a}}]
  defp reg_writes({:move, {:literal, a}, {:x, _} = d}) when is_atom(a), do: [{d, {:const_atom, a}}]
  defp reg_writes({:move, _src, {:x, _} = d}), do: [{d, :other}]
  defp reg_writes({:bif, _, _, _, {:x, _} = d}), do: [{d, :other}]
  defp reg_writes({:gc_bif, _, _, _, _, {:x, _} = d}), do: [{d, :other}]
  defp reg_writes({:get_tuple_element, _, _, {:x, _} = d}), do: [{d, :other}]
  defp reg_writes({:get_map_elements, _, _, {:list, _}} = _op), do: []   # dests are inside the list; treat as :other below
  defp reg_writes(op) when is_tuple(op) do
    # any other op that names x[k] as its LAST element (the conventional dst slot) writes it non-constantly
    case :erlang.tuple_to_list(op) |> List.last() do
      {:x, _} = d -> [{d, :other}]
      _ -> []
    end
  end
  defp reg_writes(_), do: []

  defp edge_refs({:call, _, {m, f, a}}), do: [{m, f, a}]
  defp edge_refs({:call_only, _, {m, f, a}}), do: [{m, f, a}]
  defp edge_refs({:call_last, _, {m, f, a}, _}), do: [{m, f, a}]
  defp edge_refs({:call_ext, _, {:extfunc, m, f, a}}), do: [{m, f, a}]
  defp edge_refs({:call_ext_only, _, {:extfunc, m, f, a}}), do: [{m, f, a}]
  defp edge_refs({:call_ext_last, _, {:extfunc, m, f, a}, _}), do: [{m, f, a}]
  defp edge_refs({:make_fun3, {m, fun, arity}, _, _, _, _}), do: [{m, fun, arity}]
  defp edge_refs(_), do: []
  # a call dispatching on a runtime M:F/A — DCE must keep all functions as potential targets
  defp wild_dispatch?({_, _, {:extfunc, :erlang, f, _}}) when f in [:spawn_opt, :apply, :spawn], do: true
  defp wild_dispatch?({_, _, {:extfunc, :erlang, f, _}, _}) when f in [:spawn_opt, :apply, :spawn], do: true
  defp wild_dispatch?(_), do: false

  # module-qualified WAT function name: $Mod.fun_arity ('.' separates module from fun;
  # sanitize only emits [A-Za-z0-9_], so the single '.' is an unambiguous boundary).
  defp fq(m, f, a), do: "$#{sanitize(m)}.#{sanitize(f)}_#{a}"

  # processes present? (spawn/send/self/receive). Enables the proc imports + scheduler glue.
  defp proc_mode?(user) do
    Enum.any?(user, fn {_m, {:function, _, _, _, is}} -> Enum.any?(is, &proc_op?/1) end)
  end
  defp proc_op?({:call_ext, _, {:extfunc, :erlang, :spawn, _}}), do: true
  defp proc_op?({:call_ext, _, {:extfunc, :erlang, :spawn_link, _}}), do: true
  defp proc_op?({:call_ext, _, {:extfunc, :erlang, :send, 2}}), do: true
  defp proc_op?({:bif, :self, _, _, _}), do: true
  defp proc_op?({:loop_rec, _, _}), do: true
  defp proc_op?(:remove_message), do: true
  defp proc_op?({:wait, _}), do: true
  defp proc_op?(_), do: false

  # exceptions present? (try/catch/raise) -> emit the $exc tag + wrap try-functions in try_table
  defp exc_mode?(user) do
    Enum.any?(user, fn {_m, {:function, _, _, _, is}} -> Enum.any?(is, &exc_op?/1) end)
  end
  defp exc_op?({:try, _, _}), do: true
  defp exc_op?({:try_case, _}), do: true
  defp exc_op?({:catch, _, _}), do: true
  defp exc_op?({:catch_end, _}), do: true
  defp exc_op?({ce, _, {:extfunc, :erlang, :throw, 1}}) when ce in [:call_ext, :call_ext_only], do: true
  defp exc_op?({:call_ext_last, _, {:extfunc, :erlang, :throw, 1}, _}), do: true
  defp exc_op?({ce, _, {:extfunc, :erlang, :error, _}}) when ce in [:call_ext, :call_ext_only], do: true
  defp exc_op?({:call_ext_last, _, {:extfunc, :erlang, :error, _}, _}), do: true
  defp exc_op?({:bif, :raise, _, _, _}), do: true
  defp exc_op?(_), do: false

  # ---- floats: f64 register file + boxed $float term + :math.* via host imports ----
  # Unary :math functions that map 1:1 onto a host (JS Math) call of the same name; plus the
  # two binary ones. pi/0 is inlined by the Elixir compiler to a float literal, so never called.
  @math_unary [:sin, :cos, :tan, :asin, :acos, :atan, :sqrt, :exp, :log, :log2, :log10,
               :sinh, :cosh, :tanh, :ceil, :floor]
  @math_binary [:atan2, :pow]
  # f64 literal -> a WAT-valid float token (shortest round-trippable; e-notation is fine in WAT)
  defp float_lit(x) when is_float(x), do: Float.to_string(x)
  defp float_lit(x) when is_integer(x), do: Float.to_string(x * 1.0)
  defp float_mode?(user) do
    Enum.any?(user, fn {_m, {:function, _, _, _, is}} -> Enum.any?(is, &float_op?/1) end)
  end
  defp float_op?({:fconv, _, _}), do: true
  defp float_op?({:fmove, _, _}), do: true
  defp float_op?({:bif, op, _, _, _}) when op in [:fadd, :fsub, :fmul, :fdiv], do: true
  defp float_op?({:call_ext, _, {:extfunc, :math, _, _}}), do: true
  defp float_op?({:call_ext_only, _, {:extfunc, :math, _, _}}), do: true
  defp float_op?({:call_ext_last, _, {:extfunc, :math, _, _}, _}), do: true
  defp float_op?({:literal, t}), do: has_float_literal?(t)
  defp float_op?(f) when is_float(f), do: true   # a bare float literal operand (e.g. {:float, 0.25}) → float mode
  defp float_op?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&float_op?/1)
  defp float_op?(l) when is_list(l), do: Enum.any?(l, &float_op?/1)
  defp float_op?(_), do: false

  defp has_float_literal?(f) when is_float(f), do: true
  defp has_float_literal?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&has_float_literal?/1)
  defp has_float_literal?(l) when is_list(l), do: Enum.any?(l, &has_float_literal?/1)
  defp has_float_literal?(m) when is_map(m), do: Enum.any?(Map.to_list(m), &has_float_literal?/1)
  defp has_float_literal?(_), do: false
  # the :math functions actually called, that we know how to lower
  defp math_funs_used(user) do
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
  defp float_imports(user) do
    math_funs_used(user)
    |> Enum.map_join("\n", fn {:math, f, a} ->
      ps = String.duplicate(" f64", a)
      "  (import \"math\" \"#{f}\" (func $math_host_#{f} (param#{ps}) (result f64)))"
    end)
  end
  defp float_helpers(user) do
    # term -> f64: i31 converts; $float unboxes; in bignum mode an $i64 box converts natively and a
    # true bignum goes through the host (Number(BigInt) — lossy past 2^53, like the BEAM).
    to_f64 =
      """
        (func $to_f64 (param $x (ref null eq)) (result f64)
          (if (result f64) (ref.test (ref i31) (local.get $x))
            (then (f64.convert_i32_s (i31.get_s (ref.cast (ref i31) (local.get $x)))))
            (else (if (result f64) (ref.test (ref $float) (local.get $x))
              (then (struct.get $float 0 (ref.cast (ref $float) (local.get $x))))#{if Process.get(:bignum), do: "
              (else (if (result f64) (call $is_i64rep (local.get $x))
                (then (f64.convert_i64_s (call $as_i64 (local.get $x))))
                (else (call $bigint_to_f64 (call $to_big (local.get $x))))))", else: "
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
  defp proc_imports do
    """
      (import "proc" "spawn"        (func $spawn_raw (param (ref null eq)) (result i32)))
      (import "proc" "send"         (func $send_raw (param i32) (param (ref null eq)) (result (ref null eq))))
      (import "proc" "self"         (func $self_raw (result i32)))
      (import "proc" "recv_has"     (func $recv_has (result i32)))
      (import "proc" "recv_cur"     (func $recv_cur (result (ref null eq))))
      (import "proc" "recv_remove"  (func $recv_remove))
      (import "proc" "recv_advance" (func $recv_advance))
      (import "proc" "recv_wait"    (func $recv_wait))
      (import "proc" "spawn_link"   (func $spawn_link_raw (param (ref null eq)) (result i32)))
      (import "proc" "exit"         (func $exit_raw (param (ref null eq))))
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
  defp start_process(mfa?) do
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
  defp collect_closures(user) do
    user |> Enum.flat_map(fn {_mod, {:function, _, _, _, is}} -> Enum.flat_map(is, &make_fun_refs/1) end) |> Enum.uniq()
  end
  defp make_fun_refs({:make_fun3, {m, fun, arity}, _i, _h, _d, {:list, free}}), do: [{m, fun, arity, length(free)}]
  defp make_fun_refs(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&make_fun_refs/1)
  defp make_fun_refs(l) when is_list(l), do: Enum.flat_map(l, &make_fun_refs/1)
  defp make_fun_refs(_), do: []

  defp collect_literal_funs(user) do
    user
    |> Enum.flat_map(fn {_mod, {:function, _, _, _, is}} -> Enum.flat_map(is, &literal_funs_in/1) end)
    |> Enum.uniq()
  end

  # is String.Chars.to_string/1 (string interpolation `#{}` + Enum.join element conversion) reachable?
  defp to_string?(user) do
    # only shim when the real String.Chars protocol isn't compiled in (else its body wins).
    not Enum.any?(user, fn {m, _} -> m == String.Chars end) and
      Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
        Enum.any?(is, fn op ->
          match?({_, _, {:extfunc, String.Chars, :to_string, 1}}, op) or
            match?({_, _, {:extfunc, String.Chars, :to_string, 1}, _}, op)
        end)
      end)
  end

  defp literal_funs_in({:literal, f}) when is_function(f), do: literal_funs_in(f)
  defp literal_funs_in(f) when is_function(f) do
    info = :erlang.fun_info(f)
    [{Keyword.fetch!(info, :module), Keyword.fetch!(info, :name), Keyword.fetch!(info, :arity)}]
  end
  defp literal_funs_in(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&literal_funs_in/1)
  defp literal_funs_in(l) when is_list(l), do: Enum.flat_map(l, &literal_funs_in/1)
  # a fun can be nested inside a constant MAP value (e.g. Logger metadata `%{report_cb: &format_report/1}`);
  # recurse so its name atom is interned (materialize references $atom_<name>) and it's a DCE root.
  defp literal_funs_in(m) when is_map(m), do: Map.to_list(m) |> Enum.flat_map(fn {k, v} -> literal_funs_in(k) ++ literal_funs_in(v) end)
  defp literal_funs_in(_), do: []

  # A captured ext fun (e.g. `&abs/1`, `&band/2`) is an Erlang BIF lowered INLINE — it has no
  # standalone function the apply/trampoline path can tail-call. For each such captured MFA that is
  # neither a user function nor an existing builtin shim, synthesize a wrapper $Mod.fun_arity whose
  # body is the same mode-aware expression the inline lowering uses. (Used both as a callable target
  # and as an apply_N clause; see captured_ext_targets/1.)
  defp captured_ext_targets(user) do
    defined = MapSet.new(user, fn {m, {:function, n, a, _, _}} -> {m, n, a} end)
    bkeys = MapSet.new(Map.keys(builtins()))
    collect_literal_funs(user)
    |> Enum.uniq()
    |> Enum.reject(fn {m, f, a} -> MapSet.member?(defined, {m, f, a}) or MapSet.member?(bkeys, fq(m, f, a)) end)
    |> Enum.filter(fn mfa -> capture_wrap_body(mfa) != nil end)
  end

  defp capture_wrappers(user) do
    captured_ext_targets(user)
    |> Enum.map_join("\n", fn {m, f, a} ->
      ps = if a == 0, do: "", else: " " <> Enum.map_join(0..(a - 1), " ", &"(param $x#{&1} (ref null eq))")
      "  (func #{fq(m, f, a)}#{ps} (result (ref null eq))\n    (return #{capture_wrap_body({m, f, a})}))"
    end)
  end

  # mode-aware body for a capturable inline BIF (mirrors the {:bif,...}/{:gc_bif,...} lowering); nil = unsupported.
  defp x(n), do: "(local.get $x#{n})"
  defp xi31(n), do: "(i31.get_s (ref.cast (ref i31) (local.get $x#{n})))"
  defp capture_wrap_body({:erlang, :abs, 1}) do
    if Process.get(:bignum),
      do: "(if (result (ref null eq)) (i32.lt_s (call $int_cmp #{x(0)} (ref.i31 (i32.const 0))) (i32.const 0)) (then (call $int_sub (ref.i31 (i32.const 0)) #{x(0)})) (else #{x(0)}))",
      else: "(ref.i31 (select (i32.sub (i32.const 0) #{xi31(0)}) #{xi31(0)} (i32.lt_s #{xi31(0)} (i32.const 0))))"
  end
  defp capture_wrap_body({:erlang, :byte_size, 1}), do: "(ref.i31 (array.len (struct.get $binary 0 (ref.cast (ref $binary) #{x(0)}))))"
  defp capture_wrap_body({:erlang, :bit_size, 1}), do: "(ref.i31 (i32.shl (array.len (struct.get $binary 0 (ref.cast (ref $binary) #{x(0)}))) (i32.const 3)))"
  defp capture_wrap_body({:erlang, :map_size, 1}), do: "(ref.i31 (call $map_size #{x(0)}))"
  defp capture_wrap_body({:erlang, :tuple_size, 1}), do: "(ref.i31 (array.len (ref.cast (ref $tuple) #{x(0)})))"
  defp capture_wrap_body({:erlang, :length, 1}), do: "(ref.i31 (call $list_len #{x(0)}))"
  defp capture_wrap_body({:erlang, :hd, 1}), do: "(struct.get $cons 0 (ref.cast (ref $cons) #{x(0)}))"
  defp capture_wrap_body({:erlang, :tl, 1}), do: "(struct.get $cons 1 (ref.cast (ref $cons) #{x(0)}))"
  defp capture_wrap_body({:erlang, op, 2}) when op in [:band, :bor, :bxor, :bsl, :bsr] do
    cond do
      Process.get(:bignum) -> "(call $int_#{op} #{x(0)} #{x(1)})"
      op in [:band, :bor, :bxor] -> "(ref.i31 (i32.#{wasmop(op)} #{xi31(0)} #{xi31(1)}))"
      true -> "(ref.i31 (i32.wrap_i64 (i64.#{wasmop(op)} (i64.extend_i32_s #{xi31(0)}) (i64.extend_i32_s #{xi31(1)}))))"
    end
  end
  # comparison operators captured as funs (Enum.max/min/sort default comparators): &>=/2, &</2, …
  defp capture_wrap_body({:erlang, op, 2}) when op in [:"=:=", :==, :"=/=", :"/=", :<, :>, :">=", :"=<"] do
    "(if (result (ref null eq)) #{bool_cmp(op, {:x, 0}, {:x, 1})} (then (global.get $atom_true)) (else (global.get $atom_false)))"
  end
  # arithmetic operators captured as funs (Enum.sum/product default reducers): &+/2, &*/2, …
  defp capture_wrap_body({:erlang, op, 2}) when op in [:+, :-, :*, :div, :rem] do
    cond do
      Process.get(:float) and op in [:+, :-, :*] -> "(call $num_#{bif(op)} #{x(0)} #{x(1)})"
      Process.get(:bignum) -> "(call $int_#{bif(op)} #{x(0)} #{x(1)})"
      true -> "(ref.i31 (i32.#{wasmop(op)} #{xi31(0)} #{xi31(1)}))"
    end
  end
  # type-test BIFs captured as predicates (&is_list/1 — Stream/zip uses it via :lists.all): atom true/false
  defp capture_wrap_body({:erlang, tb, 1})
       when tb in [:is_atom, :is_binary, :is_bitstring, :is_tuple, :is_map, :is_pid, :is_reference,
                   :is_function, :is_float, :is_port, :is_integer, :is_list, :is_boolean] do
    "(if (result (ref null eq)) #{type_test_i32(tb, x(0))} (then (global.get $atom_true)) (else (global.get $atom_false)))"
  end
  defp capture_wrap_body(_), do: nil

  # i32 (1/0) type-test expression for term `vw` (shared by the inline test forms and capture wrappers).
  defp type_test_i32(:is_atom, vw), do: "(ref.test (ref $atom) #{vw})"
  defp type_test_i32(tt, vw) when tt in [:is_binary, :is_bitstring], do: "(ref.test (ref $binary) #{vw})"
  defp type_test_i32(:is_tuple, vw), do: "(ref.test (ref $tuple) #{vw})"
  defp type_test_i32(:is_map, vw), do: "(ref.test (ref $map) #{vw})"
  defp type_test_i32(:is_pid, vw), do: "(ref.test (ref $pid) #{vw})"
  defp type_test_i32(:is_reference, vw), do: "(ref.test (ref $ref) #{vw})"
  defp type_test_i32(:is_function, vw), do: "(ref.test (ref $fun) #{vw})"
  defp type_test_i32(:is_float, vw), do: if(Process.get(:float), do: "(ref.test (ref $float) #{vw})", else: "(i32.const 0)")
  defp type_test_i32(:is_port, _vw), do: "(i32.const 0)"
  defp type_test_i32(:is_integer, vw), do: if(Process.get(:bignum), do: "(i32.or (i32.or (ref.test (ref i31) #{vw}) (ref.test (ref $i64) #{vw})) (ref.test (ref $big) #{vw}))", else: "(ref.test (ref i31) #{vw})")
  defp type_test_i32(:is_list, vw), do: "(i32.or (ref.is_null #{vw}) (ref.test (ref $cons) #{vw}))"
  defp type_test_i32(:is_boolean, vw), do: "(i32.or (ref.eq #{vw} (global.get $atom_true)) (ref.eq #{vw} (global.get $atom_false)))"

  # every {mod, fun, arity} reached by a direct/external call (for auto-stubbing undefined fns)
  defp called_funs(user) do
    user |> Enum.flat_map(fn {_mod, {:function, _, _, _, is}} -> Enum.flat_map(is, &call_refs/1) end) |> Enum.uniq()
  end
  defp call_refs({:call, _, {m, f, a}}), do: [{m, f, a}]
  defp call_refs({:call_only, _, {m, f, a}}), do: [{m, f, a}]
  defp call_refs({:call_last, _, {m, f, a}, _}), do: [{m, f, a}]
  defp call_refs({:call_ext, _, {:extfunc, m, f, a}}), do: [{m, f, a}]
  defp call_refs({:call_ext_only, _, {:extfunc, m, f, a}}), do: [{m, f, a}]
  defp call_refs({:call_ext_last, _, {:extfunc, m, f, a}, _}), do: [{m, f, a}]
  defp call_refs(_), do: []

  # arities used by apply/apply_last -> need a generated $apply_N dispatch
  defp apply_arities(user) do
    used = user |> Enum.flat_map(fn {_m, {:function, _, _, _, is}} -> Enum.flat_map(is, fn
      {:apply, n} -> [n]
      {:apply_last, n, _} -> [n]
      _ -> []
    end) end)
    # MFA spawn (spawn_opt/4) runs procs via the generic apply/3, which dispatches into apply_0..apply_8;
    # force those arities so the dispatch targets exist.
    # spawn_opt/apply (MFA) and make_fun trampolines both dispatch into apply_0..apply_8.
    wild? = Enum.any?(user, fn {_m, {:function, _, _, _, is}} ->
      Enum.any?(is, fn op ->
        match?({_, _, {:extfunc, :erlang, f, _}} when f in [:spawn_opt, :apply, :make_fun, :hibernate], op) or
          match?({_, _, {:extfunc, :erlang, f, _}, _} when f in [:spawn_opt, :apply, :make_fun, :hibernate], op)
      end)
    end)
    (used ++ if(wild? or collect_literal_funs(user) != [], do: Enum.to_list(0..8), else: [])) |> Enum.uniq()
  end

  # $apply_N(args…, mod, fun): dispatch on (mod, fun) over every closed-world function of arity N
  # and tail-call it. Closed-world makes this exhaustive. Instead of a linear scan (O(functions) —
  # 339 clauses for Jason's arity-2 protocol dispatch, on the hot path per encoded value), we form
  # an i64 key = mod_idx*MUL + fun_idx from the interned atom indices and BINARY-SEARCH it: ~log2(N)
  # comparisons. Unknown pair falls through to unreachable.
  defp gen_apply(n, user) do
    params = (if n == 0, do: "", else: " " <> Enum.map_join(0..(n - 1), " ", &"(param $a#{&1} (ref null eq))")) <>
             " (param $mod (ref null eq)) (param $fun (ref null eq))"
    args = if n == 0, do: "", else: " " <> Enum.map_join(0..(n - 1), " ", &"(local.get $a#{&1})")
    aidx = Process.get(:atom_idx)
    mul = 1_000_000
    clauses =
      (user
       |> Enum.filter(fn {_m, {:function, _nm, ar, _, _}} -> ar == n end)
       # exclude pure lambdas — they have the (self, args…) closure signature, not the normal one
       |> Enum.reject(fn {m, {:function, nm, ar, _, _}} ->
         cl = Process.get(:closures, %{}) |> Map.get({m, nm, ar})
         cl != nil and not cl.dual
       end)
       # only functions whose (mod, fun) atoms are interned can be named as an apply target
       |> Enum.filter(fn {m, {:function, nm, _, _, _}} -> Map.has_key?(aidx, m) and Map.has_key?(aidx, nm) end)
       |> Enum.map(fn {m, {:function, nm, _, _, _}} ->
         {Map.fetch!(aidx, m) * mul + Map.fetch!(aidx, nm), "(return_call #{fq(m, nm, n)}#{args})"}
       end)) ++ helper_apply_clauses(n, aidx, mul, args) ++ ext_capture_clauses(n, user, aidx, mul, args)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort_by(&elem(&1, 0))
    keyset =
      "    (local.set $key (i64.add (i64.mul (i64.extend_i32_u (struct.get $atom 0 (ref.cast (ref $atom) (local.get $mod)))) (i64.const #{mul})) (i64.extend_i32_u (struct.get $atom 0 (ref.cast (ref $atom) (local.get $fun))))))"
    "  (func $apply_#{n}#{params} (result (ref null eq)) (local $key i64)\n#{keyset}\n#{bisect_apply(clauses)}\n    (unreachable))"
  end

  # balanced binary-search tree over sorted {key, call} clauses; each leaf is an exact-key guard.
  defp bisect_apply([]), do: ""
  defp bisect_apply([{k, call}]), do: "    (if (i64.eq (local.get $key) (i64.const #{k})) (then #{call}))"
  defp bisect_apply(clauses) do
    mid = div(length(clauses), 2)
    {left, right} = Enum.split(clauses, mid)
    pivot = elem(hd(right), 0)
    "    (if (i64.lt_u (local.get $key) (i64.const #{pivot}))\n      (then\n#{bisect_apply(left)})\n      (else\n#{bisect_apply(right)}))"
  end

  defp helper_apply_clauses(1, aidx, mul, args) do
    for {m, f, wat} <- [{:erlang, :exit, "$erlang.exit_1"}, {:maps, :from_list, "$maps.from_list_1"}, {:binary, :copy, "$binary.copy_1"}],
        Map.has_key?(aidx, m), Map.has_key?(aidx, f) do
      {Map.fetch!(aidx, m) * mul + Map.fetch!(aidx, f), "(return_call #{wat}#{args})"}
    end
  end
  defp helper_apply_clauses(_n, _aidx, _mul, _args), do: []

  # apply_N clauses for CAPTURED ext functions (`&abs/1`, `&Tuple.to_list/1`, `&band/2`): a literal
  # fun applied via the trampoline lands in apply_N keyed on (mod,fun). Route each captured ext MFA of
  # arity n — that isn't a user function but has a builtin shim or a synthesized capture wrapper — to it.
  defp ext_capture_clauses(n, user, aidx, mul, args) do
    defined = MapSet.new(user, fn {m, {:function, nm, a, _, _}} -> {m, nm, a} end)
    bkeys = MapSet.new(Map.keys(builtins()))
    wraps = MapSet.new(captured_ext_targets(user))
    # gated extras that exist as real functions when their feature flag is on (see compile/1)
    gated = if(Process.get(:atom_names), do: MapSet.new([{:erlang, :atom_to_binary, 1}, {:erlang, :atom_to_binary, 2}]), else: MapSet.new())
    collect_literal_funs(user)
    |> Enum.uniq()
    |> Enum.filter(fn {_, _, a} -> a == n end)
    |> Enum.reject(fn mfa -> MapSet.member?(defined, mfa) end)
    |> Enum.filter(fn {m, f, _a} = mfa ->
      (MapSet.member?(bkeys, fq_b(mfa)) or MapSet.member?(wraps, mfa) or MapSet.member?(gated, mfa)) and
        Map.has_key?(aidx, m) and Map.has_key?(aidx, f)
    end)
    |> Enum.map(fn {m, f, a} -> {Map.fetch!(aidx, m) * mul + Map.fetch!(aidx, f), "(return_call #{fq(m, f, a)}#{args})"} end)
  end
  defp fq_b({m, f, a}), do: fq(m, f, a)

  defp call_fun_arities(user) do
    user |> Enum.flat_map(fn {_mod, {:function, _, _, _, is}} -> Enum.flat_map(is, fn
      {:call_fun, n} -> [n]
      {:call_fun2, _, n, _} -> [n]
      _ -> []
    end) end) |> Enum.uniq()
  end

  defp regs_in({:literal, _}), do: []
  defp regs_in({:x, _} = r), do: [r]
  defp regs_in({:y, _} = r), do: [r]
  defp regs_in(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&regs_in/1)
  defp regs_in(l) when is_list(l), do: Enum.flat_map(l, &regs_in/1)
  defp regs_in(_), do: []

  # collect distinct atoms referenced anywhere (instruction operands + inside literals)
  # all float-register indices {:fr, n} referenced anywhere in an op (operands and dests)
  defp fr_indices({:fr, n}), do: [n]
  defp fr_indices(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&fr_indices/1)
  defp fr_indices(l) when is_list(l), do: Enum.flat_map(l, &fr_indices/1)
  defp fr_indices(_), do: []

  defp atoms_in({:literal, term}), do: term_atoms(term)
  defp atoms_in({:atom, a}), do: [a]
  defp atoms_in(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&atoms_in/1)
  defp atoms_in(l) when is_list(l), do: Enum.flat_map(l, &atoms_in/1)
  defp atoms_in(_), do: []

  defp term_atoms(a) when is_atom(a), do: [a]
  # Map.to_list (not Enum) — a struct literal (e.g. a Range) is Enumerable; Enum would iterate
  # it as a SEQUENCE, not key/value pairs. Map.to_list always treats it as a raw map.
  defp term_atoms(m) when is_map(m), do: Map.to_list(m) |> Enum.flat_map(fn {k, v} -> term_atoms(k) ++ term_atoms(v) end)
  defp term_atoms(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&term_atoms/1)
  defp term_atoms(l) when is_list(l), do: Enum.flat_map(l, &term_atoms/1)
  defp term_atoms(_), do: []

  defp i32_const(n) when n >= 0x8000_0000, do: n - 0x1_0000_0000
  defp i32_const(n), do: n

  defp bit_chunks(s, bits) do
    bytes = :binary.bin_to_list(IO.iodata_to_binary(s))
    do_bit_chunks(bytes, bits, 0, []) |> Enum.reverse()
  end

  defp do_bit_chunks(_bytes, 0, _off, acc), do: acc
  defp do_bit_chunks(bytes, bits, off, acc) do
    n = min(bits, 31)
    v = Enum.reduce(0..(n - 1), 0, fn i, out ->
      p = off + i
      byte = Enum.at(bytes, div(p, 8), 0)
      bit = Bitwise.band(Bitwise.bsr(byte, 7 - rem(p, 8)), 1)
      Bitwise.bor(Bitwise.bsl(out, 1), bit)
    end)
    do_bit_chunks(bytes, bits - n, off + n, [{off, n, v} | acc])
  end

  # ---- binary construction (bs_create_bin) ----
  # a constant binary -> a $binary built byte-by-byte from an array.new_fixed
  defp bin_literal(b) do
    bytes = :binary.bin_to_list(b)
    inner = if bytes == [], do: "", else: " " <> Enum.map_join(bytes, " ", &"(i32.const #{&1})")
    "(struct.new $binary (array.new_fixed $bytes #{length(bytes)}#{inner}))"
  end

  # emit WAT that builds the binary from its segments into $bdst; returns {lines, result_expr}.
  # Each seg = [type, flags, unit, nil, src, size]. Supported: string segs and binary segs
  # (size :all or a fixed integer byte count). Runtime length = sum of segment byte lengths.
  defp create_bin_lines(segs, val) do
    blen_expr = Enum.reduce(segs, "(i32.const 0)", fn seg, acc ->
      "(i32.add #{acc} #{seg_len(seg, val)})"
    end)
    setup = [
      "(local.set $blen #{blen_expr})",
      "(local.set $bdst (array.new_default $bytes (local.get $blen)))",
      "(local.set $boff (i32.const 0))"
    ]
    blits = Enum.flat_map(segs, &blit_seg(&1, val))
    {setup ++ blits, "(struct.new $binary (ref.as_non_null (local.get $bdst)))"}
  end

  defp seg_len([{:atom, :string}, _fl, _u, _n, {:string, s}, _sz], _val), do: "(i32.const #{byte_size(s)})"
  # :append / :private_append (building on an existing binary, e.g. <<acc::binary, …>>) behave like
  # a whole :binary segment — copy all the bytes of the source binary.
  defp seg_len([{:atom, t}, _fl, _u, _n, src, {:atom, :all}], val) when t in [:binary, :append, :private_append],
    do: "(array.len (struct.get $binary 0 (ref.cast (ref $binary) #{val.(src)})))"
  defp seg_len([{:atom, :binary}, _fl, _u, _n, _src, {:integer, n}], _val), do: "(i32.const #{n})"
  defp seg_len([{:atom, :integer}, _fl, u, _n, _src, {:integer, sz}], _val), do: "(i32.const #{div(sz * u, 8)})"
  defp seg_len([{:atom, :utf8}, _fl, _u, _n, src, {:atom, :undefined}], _val), do: "(call $utf8_enc_len #{i32val(src)})"
  defp seg_len(seg, _val), do: raise("bs_create_bin seg_len unsupported: #{inspect(seg)}")

  defp blit_seg([{:atom, :string}, _fl, _u, _n, {:string, s}, _sz], _val) do
    bytes = :binary.bin_to_list(s)
    sets = bytes |> Enum.with_index() |> Enum.map(fn {byte, k} ->
      "(array.set $bytes (local.get $bdst) (i32.add (local.get $boff) (i32.const #{k})) (i32.const #{byte}))"
    end)
    sets ++ ["(local.set $boff (i32.add (local.get $boff) (i32.const #{length(bytes)})))"]
  end
  defp blit_seg([{:atom, t}, _fl, _u, _n, src, _size], val) when t in [:binary, :append, :private_append] do
    s = val.(src)
    [
      "(local.set $bsrc (struct.get $binary 0 (ref.cast (ref $binary) #{s})))",
      "(array.copy $bytes $bytes (local.get $bdst) (local.get $boff) (local.get $bsrc) (i32.const 0) (array.len (local.get $bsrc)))",
      "(local.set $boff (i32.add (local.get $boff) (array.len (local.get $bsrc))))"
    ]
  end
  defp blit_seg([{:atom, :integer}, _fl, u, _n, src, {:integer, sz}], _val) do
    nbytes = div(sz * u, 8)
    # big-endian: most-significant byte first
    sets = for k <- 0..(nbytes - 1) do
      shift = (nbytes - 1 - k) * 8
      "(array.set $bytes (local.get $bdst) (i32.add (local.get $boff) (i32.const #{k})) (i32.and (i32.shr_u #{i32val(src)} (i32.const #{shift})) (i32.const 255)))"
    end
    sets ++ ["(local.set $boff (i32.add (local.get $boff) (i32.const #{nbytes})))"]
  end
  defp blit_seg([{:atom, :utf8}, _fl, _u, _n, src, {:atom, :undefined}], _val) do
    ["(local.set $boff (call $utf8_enc (local.get $bdst) (local.get $boff) #{i32val(src)}))"]
  end
  defp blit_seg(seg, _val), do: raise("bs_create_bin blit unsupported: #{inspect(seg)}")

  # fold a list of [k1,v1,k2,v2,...] into nested $map_put calls over a source-map expr
  defp fold_map_put(src_expr, kvs, val) do
    kvs |> Enum.chunk_every(2) |> Enum.reduce(src_expr, fn [k, v], acc ->
      "(call $map_put #{acc} #{val.(k)} #{val.(v)})"
    end)
  end

  # Build a map from put_map_assoc/exact. Fast path: when the source is the empty map and every
  # key is a compile-time constant, dedup (last wins) + sort the pairs by Erlang term order at
  # COMPILE time and emit the whole kv array in one `array.new_fixed` — O(k) instead of the O(k²)
  # chain of copy-on-write $map_put calls. (Elixir's term order matches $term_compare, so the
  # array is already in the canonical sorted order the rest of the runtime expects.) Otherwise
  # fall back to the general chained build, which is always correct.
  defp build_map(src, kvs, val) do
    pairs = kvs |> Enum.chunk_every(2) |> Enum.map(fn [k, v] -> {k, v} end)
    static? = match?({:literal, %{}}, src) and Enum.all?(pairs, fn {k, _} -> match?({:ok, _}, key_term(k)) end)
    if static? do
      ordered =
        pairs
        |> Enum.reduce(%{}, fn {k, v}, acc -> {:ok, kt} = key_term(k); Map.put(acc, kt, {k, v}) end)
        |> Enum.sort_by(fn {kt, _} -> kt end)         # default sorter = Erlang term order
        |> Enum.map(fn {_kt, kv} -> kv end)
      # keys are statically sorted -> emit the BALANCED TREE directly (dynamic value exprs). Exactly
      # K node allocations, ZERO runtime comparisons/rebalancing (vs $map_from_kv's K inserts).
      "(struct.new $map #{build_tree_expr(Enum.map(ordered, fn {k, v} -> {val.(k), val.(v)} end))})"
    else
      fold_map_put(val.(src), kvs, val)
    end
  end

  # balanced tree from a key-sorted list of {key_wat, val_wat} (pre-rendered WAT). Median = root.
  defp build_tree_expr([]), do: "(ref.null $mnode)"
  defp build_tree_expr(pairs) do
    n = length(pairs)
    {left, [{k, v} | right]} = Enum.split(pairs, div(n, 2))
    "(struct.new $mnode #{k} #{v} #{build_tree_expr(left)} #{build_tree_expr(right)} (i32.const #{n}))"
  end

  # the literal term of a constant key operand (for compile-time map sorting), or :dynamic
  defp key_term({:integer, n}), do: {:ok, n}
  defp key_term({:atom, a}), do: {:ok, a}
  defp key_term(nil), do: {:ok, []}              # bare nil operand = the empty list
  defp key_term({:literal, t}), do: {:ok, t}
  defp key_term({:tr, reg, _}), do: key_term(reg)
  defp key_term(_), do: :dynamic

  # a constant term (from beam_disasm's {:literal, _}) -> WAT that constructs it
  defp materialize(n) when is_integer(n), do: int_literal(n)
  defp materialize(f) when is_float(f), do: "(struct.new $float (f64.const #{float_lit(f)}))"
  defp materialize(nil), do: "(global.get $atom_nil)"   # the atom nil (distinct from [] below)
  defp materialize([]), do: "(ref.null none)"            # the empty list
  # constant binaries (string keys/values like "qty", SKU codes) are hoisted too — otherwise each use
  # re-allocates a $binary + $bytes. Immutable globals, built once. (Binaries are never mutated.)
  defp materialize(b) when is_binary(b) and byte_size(b) > 0, do: hoist_const({:bin, b}, fn -> bin_literal(b) end)
  defp materialize(b) when is_binary(b), do: bin_literal(b)
  defp materialize(a) when is_atom(a), do: "(global.get $atom_#{sanitize(a)})"
  defp materialize(f) when is_function(f) do
    info = :erlang.fun_info(f)
    m = Keyword.fetch!(info, :module)
    name = Keyword.fetch!(info, :name)
    arity = Keyword.fetch!(info, :arity)
    "(struct.new $fun (i32.const #{Process.get(:tramp_base) + arity}) (array.new_fixed $freevars 2 (global.get $atom_#{sanitize(m)}) (global.get $atom_#{sanitize(name)})))"
  end
  # Constant maps are HOISTED to immutable module globals, built ONCE as a compile-time-constant
  # balanced tree (nested struct.new $mnode — a valid global initializer). Otherwise the literal would
  # be re-materialized (a full tree rebuild) at every use site — e.g. `Map.get(@prices, sku)` would
  # rebuild @prices on every lookup. (Was the dominant cost in the realistic/decimal workloads.)
  defp materialize(m) when is_map(m) and map_size(m) > 0, do: hoist_const(m, fn -> const_map_expr(m) end)
  defp materialize(m) when is_map(m), do: "(struct.new $map (ref.null $mnode))"

  defp const_map_expr(m) do
    pairs = Map.to_list(m) |> Enum.sort()    # Erlang term order (Elixir's default sort) = tree order
    "(struct.new $map #{const_tree(pairs)})"
  end
  defp const_tree([]), do: "(ref.null $mnode)"
  defp const_tree(pairs) do
    n = length(pairs)
    {left, [{k, v} | right]} = Enum.split(pairs, div(n, 2))   # median root -> balanced
    "(struct.new $mnode #{materialize(k)} #{materialize(v)} #{const_tree(left)} #{const_tree(right)} (i32.const #{n}))"
  end

  # register a constant -> an immutable global (dedup by value); returns a (global.get …). Nested
  # consts registered during expr_fun get LOWER indices (declared first), so a parent's initializer
  # may reference them via global.get.
  defp hoist_const(term, expr_fun) do
    case Map.get(Process.get(:consts, %{}), term) do
      nil ->
        expr = expr_fun.()
        idx = Process.get(:const_n, 0)
        Process.put(:const_n, idx + 1)
        Process.put(:consts, Map.put(Process.get(:consts, %{}), term, idx))
        Process.put(:const_defs, [{idx, expr} | Process.get(:const_defs, [])])
        "(global.get $const#{idx})"
      idx -> "(global.get $const#{idx})"
    end
  end

  def const_globals do
    Process.get(:const_defs, []) |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {idx, expr} -> "  (global $const#{idx} (ref null eq) #{expr})" end)
  end
  defp materialize([h | t]), do: "(struct.new $cons #{materialize(h)} #{materialize(t)})"
  defp materialize(t) when is_tuple(t) do
    elems = Tuple.to_list(t)
    "(array.new_fixed $tuple #{length(elems)} #{Enum.map_join(elems, " ", &materialize/1)})"
  end
  # Unhandled literal kinds (external fun captures &M.f/a, floats, bitstrings of odd shape)
  # appear only on non-list Enum paths. In STUB mode, null them so the module still builds.
  defp materialize(other) do
    if Process.get(:stub), do: "(ref.null none)", else: raise("materialize: #{inspect(other)}")
  end

  defp int_literal(n) when n >= -1_073_741_824 and n < 1_073_741_824, do: "(ref.i31 (i32.const #{n}))"
  defp int_literal(n) do
    cond do
      not Process.get(:bignum) -> "(ref.i31 (i32.const #{n}))"
      # fits i64: build the middle tier directly — no host BigInt digit-chain at all.
      n >= -9_223_372_036_854_775_808 and n <= 9_223_372_036_854_775_807 -> "(struct.new $i64 (i64.const #{n}))"
      true -> "(struct.new $big #{bigint_const_expr(n)})"
    end
  end

  defp bigint_const_expr(n) do
    sign = if n < 0, do: -1, else: 1
    digits = Integer.to_string(abs(n)) |> String.to_charlist() |> Enum.map(&(&1 - ?0))
    zero = "(call $bigint_from_i64 (i64.const 0))"
    expr = Enum.reduce(digits, zero, fn digit, acc ->
      "(call $bigint_add (call $bigint_mul #{acc} (call $bigint_from_i64 (i64.const 10))) (call $bigint_from_i64 (i64.const #{digit})))"
    end)
    if sign < 0,
      do: "(call $bigint_sub (call $bigint_from_i64 (i64.const 0)) #{expr})",
      else: expr
  end
end

IO.puts(Beam2Wasm.run(System.argv()))
