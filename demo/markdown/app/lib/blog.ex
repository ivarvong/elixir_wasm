defmodule Blog do
  # A real-world content pipeline on WasmGC using UNMODIFIED hex deps end-to-end:
  #   JSON --Jason.decode!--> map  ;  markdown body --Earmark.as_html!--> HTML  ;  wrap in a template.
  @articles [
    ~s|{"title":"Running Elixir on the Edge","author":"ada","tags":["wasm","beam","edge"],"reads":1240,"body":"# Why WasmGC\\n\\nBEAM terms are a *graph* of heap cells. **WasmGC** gives first-class GC structs.\\n\\n- cons cells\\n- tuples\\n- maps\\n\\nSee [the spike](https://example.com) for `ref.eq`.\\n\\n> Closed-world is a feature.\\n"}|,
    ~s|{"title":"Durable Objects with OTP","author":"grace","tags":["otp","durable"],"reads":877,"body":"## The thesis\\n\\nA **single-owner** state machine at the edge.\\n\\n1. order lifecycles\\n2. idempotent payments\\n\\nState *survives* restart.\\n"}|,
    ~s|{"title":"Exact Integers","author":"linus","tags":["bignum"],"reads":42,"body":"# fact(50)\\n\\nArithmetic is **exact**: i31 to host BigInt.\\n\\n> Bit-identical to the VM.\\n"}|
  ]

  # bin->bin entry: render an arbitrary markdown document through the real Earmark engine.
  # Used by bench_vs_js.exs to compare against JS markdown renderers on identical input.
  def render_md(md) when is_binary(md), do: Earmark.as_html!(md)

  def render(seed) do
    doc = Enum.at(@articles, rem(abs(seed), length(@articles))) |> Jason.decode!()
    body = Earmark.as_html!(Map.get(doc, "body"))
    tags = Map.get(doc, "tags") |> Enum.map_join("", fn t -> "<span class=\"tag\">" <> t <> "</span>" end)
    "<!doctype html>\n<article>\n<h1>" <> Map.get(doc, "title") <> "</h1>\n" <>
      "<div class=\"meta\">by " <> Map.get(doc, "author") <> " &middot; " <>
      Integer.to_string(Map.get(doc, "reads")) <> " reads &middot; " <> tags <> "</div>\n" <>
      body <> "</article>\n"
  end
end
