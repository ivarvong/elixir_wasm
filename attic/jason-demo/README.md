# Jason on WasmGC — a real hex dependency, compiled

This runs **[Jason](https://hex.pm/packages/jason) 1.4.5** (the real, unmodified JSON library — 26
modules) compiled to WasmGC by `../beam2wasm.exs`, encoding real Elixir data to JSON
**bit-exact with the BEAM**.

```
$ node --stack-trace-limit=20 run.mjs        # node 24+ (Wasm exceptions)
order_json     {"active":true,"item":"widget","qty":4,"shipped":false,"tags":["new","sale"]}
report_json    {"note":null,"squares":[[1,4,9],[16,25,36]],"sums":[6,15]}
scalars_json   [1,-42,true,false,null,"he said \"hi\"","tab\there"]
```

`json_demo.ex` builds maps, modifies them (`Map.put`, `Map.update!`), runs `Enum` transforms,
and calls `Jason.encode!/1` — exercising the real `Jason.Encoder` protocol (consolidated
closed-world), iodata generation, and string escaping. DCE keeps **981 of 1152** functions
(Jason + the reachable stdlib); the module is ~450 KB of WasmGC.

## What this exercised in the compiler (all now upstreamed to `beam2wasm.exs`)

Found by running the real library and filling each gap the honest STUBS meter surfaced:

- **Native BIFs:** `iolist_to_binary/1`, `binary_part/3`, `integer_to_binary/1`,
  `atom_to_binary/{1,2}` (via a gated atom-name table), `maps.from_list/1`, `maps.merge/2`,
  `maps.to_list/1`.
- **Binary matching:** `bs_start_match4`, `bs_get_utf8`/`bs_skip_utf8` (UTF-8 codepoint decode).
- **Correctness fixes (these matter well beyond Jason):**
  - The atom **`nil` is now distinct from the empty list `[]`** (was conflated as the null ref) —
    so `nil` encodes as `null`, not `[]`, and `is_list(nil)` is correctly `false`.
  - **Maps are canonically key-sorted** (Erlang flatmap semantics), so iteration/encoding order
    matches the VM.
  - **Map keys compare structurally** (`$term_compare`, not `ref.eq`) — string keys work.
  - Bitwise ops compute in **i64** (so >32-bit masks are representable).
  - `is_float`/`is_bitstr`/`floor`/`ceil`/`not`/`xor` opcodes.

## Known limitation: decode needs a 64-bit integer tier

`Jason.decode!/1` does **not** run yet. Its UTF-8 validation (`String.valid_utf8_fast_ascii?`)
uses a **SWAR** trick — it packs 7 bytes into a 56-bit integer and masks with `0x80808080808080`
to test 7 bytes for ASCII at once. The 31-bit `i31` term can't hold a 56-bit value (the literal
doesn't even fit `i32.const`). The bitwise i64 fix makes it *assemble*, but correct execution
needs a real **i64 integer tier** (box ints that exceed i31 in an `(struct (field i64))`, with
i64-aware arithmetic/compare/bs_match). That's the next bounded feature; with it, full
decode→modify→encode roundtrips should run.

## Rebuild

Needs a mix project with `{:jason, "~> 1.4"}` compiled under `MIX_ENV=prod`. Consolidate the
`Jason.Encoder` protocol, stage all `jason/ebin/*.beam` plus the reachable stdlib (`Map`, `Enum`,
`Keyword`, `List`, `Integer`, `String`, `Access`) into `stage/`, then `./build.sh`. The runner
provides `big` (BigInt) and `math` (libm) host imports — unused here but harmless.
