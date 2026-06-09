# Limitations — what is a TRUE limit vs what is a BUG

**The bar (the mission):** any non-native code — pure Elixir/Erlang bytecode — runs on WasmGC,
bit-exact vs the VM. **If pure code doesn't run, that is a bug**, and we build the support.
This document is the canonical line between the two. Everything in §3 is a bug with a finite,
enumerated inventory; only §1 contains legitimate "can't"s, and even most of those have designed
answers.

Evidence base: the differential harnesses (conformance 161/161, fuzz 33/33, gaps 19/20), the
20-program gap corpus master list (`gaps/GAPS_FOUND.txt`), and the richest real-world probe so far —
compiling real Jason + real Earmark + stdlib (149 beams), whose reachable-stub inventory enumerates
~190 distinct functions (`demo/markdown/_work/blog.wat`).

---

## 1. True limits (the only legitimate "reasons it can't")

### 1.1 Native code itself — the NIF/BIF host boundary
NIFs and C-implemented BIFs are, by definition, not "non-native code." Each one used must be
**shimmed at the host boundary** with equivalent semantics. The *limit* is therefore not "it doesn't
run" but **shim existence + semantic fidelity**:

- **`:re` (PCRE)** ↔ JS `RegExp`: the shim strategy works (run/2/3, split/3, replace/3 shipped,
  bit-exact on everything tested), but PCRE has constructs JS lacks (possessive quantifiers,
  atomic groups, recursion `(?R)`, `\h`/`\R`). Fidelity endgame, if ever needed: compile PCRE2
  itself to wasm as a linear-memory sidecar (the "no C" decision was about the *runtime term
  model*, not leaf libraries), or implement a PCRE-compatible engine in Elixir.
- **Float→string formatting** (`float_to_binary` et al.): Erlang uses shortest-round-trip (Ryu).
  JS also prints shortest-round-trip but with different formatting conventions at the edges
  (exponent thresholds, `1.0e20` vs `100000000000000000000`). Needs an exact-Erlang-format
  implementation, not a naive host passthrough. Buildable; precision-critical.
- **Unicode case/normalization**: currently host-shimmed (JS `toUpperCase`). The *pure* path
  exists — Elixir's own `String.Unicode` is generated Elixir code and already compiles — at a
  module-size cost. NFC/NFD normalization (`:unicode.characters_to_nf*`) likewise has table-driven
  pure implementations available.
- **`:crypto`**: host WebCrypto/node-crypto (shipped for hash). Limit = algorithm availability on
  the platform.
- **Time, randomness, entropy** (`:os.system_time`, seeds): host effects by nature; shimmed.
  (Note `:rand` itself is pure Erlang — only the seed is an effect.)

### 1.2 Platform effects — the environment, not the language
Cloudflare Workers has no filesystem (`File.*`), no OS (`:os`, ports), no raw sockets (HTTP via
fetch only), a ~128MB isolate cap and ~10MB module cap (why function-level DCE exists). These bound
what *effects* a program can perform, not what pure code computes. A pure function that never does
I/O is unaffected; `File.read/1` will never work because there is no file.

### 1.3 Runtime code creation
`Code.eval_string`, runtime `Module.create`, `EEx.eval_string/eval_file` require compiling code at
runtime — the platform forbids runtime wasm codegen. **The designed answer exists**: the tiered
runtime (`interp/` — a BEAM interpreter, itself compiled by this compiler, that executes `.beam`
as *data* with the same term ABI). Seed built and verified; productionizing it is roadmap work, so
even this limit is "buildable, via the tier." (Compile-*time* EEx templates are just functions and
need nothing special.)

### 1.4 Scale & scheduling semantics
~15–25k concurrent JSPI processes per isolate (vs BEAM's millions); the reduction budget is
per-isolate today (per-process budgets are roadmap); one isolate = one thread (parallelism comes
from many isolates/DOs, like BEAM distribution). These change *capacity*, not correctness.

---

## 2. Deliberate, documented deltas (not bugs — by decision)

- **Map iteration order for >32-key maps** is key-sorted (BST), not BEAM's HAMT hash order. Elixir
  documents map order as unspecified; BEAM's order isn't stable across OTP versions. Programs that
  depend on it are relying on unspecified behavior (this was the one apparent "compiler lie" in the
  gap corpus — a test bug; see `gaps/FINDINGS.md`).
- **Stacktraces are empty** (`__STACKTRACE__` = `[]`). Exceptions/try/rescue work; traces aren't
  recorded. Could be partially built (function names exist in `-g` builds); fidelity to BEAM trace
  format is a future decision, not promised.
- **`apply/3` reaches only compiled-in code** (closed world + DCE). Mitigated by apply-target
  analysis keeping reachable dispatch targets; fully recovered by the interpreter tier.
- **No live introspection** (`:observer`, `:dbg`, hot tracing) — closed-world consequence.

---

## 3. The bug inventory (buildable; "it's a lot of work" is not a reason)

Current enumerated inventory, classified by the kind of work. Tags: **[beams]** = pure code that
should run once the right `.beam`s are fed/kept (+ verify bit-exact); **[builtin]** = implement a
WAT builtin / host shim; **[compiler]** = compiler lowering work; **[exact]** = must match a
documented algorithm bit-for-bit; **[proc]** = scheduler-mode completion; **[interp]** = needs the
interpreter tier.

**Exceptions & errors (in every program's error paths; top of the gap-corpus frequency list):**
- `erlang:error/1,2,3`, `throw/1`, `nif_error/1` → lower to the `$exc` throw with proper terms **[compiler]**
- Exception constructors (`ArgumentError.exception/1`, `RuntimeError`, `KeyError`, …) — generated
  pure code **[beams]**; `Exception.message/normalize` **[beams]**
- `Kernel.inspect/1` + the `Inspect` protocol/Algebra — pure **[beams]**, plus `io_lib.*` (pure
  Erlang) **[beams]** and float formatting **[exact]**

**Term primitives:**
- `erts_internal.cmp_term/2` → wire to the existing `$term_compare` **[builtin]** (trivial)
- `erlang.phash/2`, `phash2` → documented stable algorithm, implement exactly **[exact]**
- `integer_to_binary/2`, `integer_to_list/2` (base-N; mirrors the just-built `binary_to_integer/2`),
  `atom_to_list/1`, `binary.last/1`, `list_to_bin/1` **[builtin]**
- `binary_to_float/1`, `list_to_float/1`, `float_to_binary/2`, `Float.round/3` **[exact]**
- Non-byte-aligned bitstrings (sub-byte segments; `gaps/` p18) **[compiler]**

**Dynamic atoms** (`binary_to_atom/2`, `*_to_existing_atom`, `Module.concat/1,2`): runtime
atom-table overflow — a name-keyed side table with interned identity **[compiler]**. Unlocks
unconsolidated-protocol dispatch too (though the right default is consolidating ourselves in our
closed-world pass — we have whole-program knowledge at compile time).

**Regex completion** (live frontier; run/2/3, split/3, replace/3 done):
`replace` with a **function** replacement (per-match closure dispatch back into wasm), `replace/4`,
`scan/2`, `match?/2`, `split/2`, `escape/1`, `compile!/1,2`, named captures **[builtin]**.

**Pure-Erlang/Elixir stdlib that should just run** **[beams]** (+ differential verification):
`:array`, `:orddict`, `:gb_trees`, `:queue`, `:digraph`, `:rand`, `erl_scan`/`erl_anno`,
leex/yecc-generated lexers (plain generated Erlang!), `Calendar`/`Date`/`DateTime`/`Time`
(`to_iso8601`), `Path.*`, `URI.*`, `OptionParser`, `String.Break`, `Stream`/`Stream.Reducers`,
`:sets`/`MapSet` internals, `Macro.*` (the pure parts), the `-inlined-` protocol/struct helpers.

**Process/runtime completion** **[proc]**: `spawn/1,3` + `spawn_monitor` in all call forms,
`erlang.send/2` alias forms, `make_ref/0` outside proc mode, `Process.get/delete/sleep`, `Task.*`,
runtime-variable `receive … after`, per-process reduction budgets, `unique_integer/0`.

**Host-effect shims** **[builtin]**: `IO.puts/warn` → console, `application.get_key/2` → static app
env, `convert_time_unit` (pure arithmetic).

**Under investigation:** one real divergence — Earmark's `LineScanner` receives a non-binary on
Wasm where the VM has a binary (differential debugging in progress; this is exactly the class the
harnesses exist to catch).

---

## 4. How we hold the bar (limitations as a *measured number*)

1. **Differential harnesses** — every change proves itself bit-exact vs the VM (conformance / fuzz /
   gaps), and every new real-library demo (Jason, Req, Earmark, …) extends the probe surface.
2. **The compiler never lies** — unsupported = a *counted trap* (`STUBS: N`, stub names listed),
   never a silently wrong value. 0 stubs ⇒ provably supported.
3. **Planned: the stdlib API scoreboard** — enumerate every public function of every stdlib module
   via `Module.__info__(:functions)`, generate seeded representative calls, diff Wasm vs VM, and
   publish `Enum 74/74, Map 30/30, String 41/43, …`. That turns this whole document's §3 into a
   shrinking number per release — the direct measurement of "any pure Elixir runs."
