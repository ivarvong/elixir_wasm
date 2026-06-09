defmodule Blog do
  # A real-world content pipeline, entirely in compiled Elixir on WasmGC:
  #   JSON (article) --parse--> map --markdown render + template--> HTML page.
  # Real Jason.decode! parses the article; the markdown->HTML render is line-based string processing + Enum/Map — no NIFs, no host libs. `render/1` returns the
  # HTML binary; the harness runs it on Wasm AND the VM and asserts the bytes are identical.

  @articles [
    ~s|{"title":"Running Elixir on the Edge","author":"ada","tags":["wasm","beam","edge"],"body":"# Why WasmGC\\n\\nBEAM terms are a *graph* of heap cells. **WasmGC** gives us first-class GC structs.\\n\\n- cons cells\\n- tuples\\n- maps\\n\\nSee the [spike](https://example.com/spike) for `ref.eq` details.\\n\\n> Closed-world is a feature, not a constraint.\\n\\n```\\nfact(50) == bit_identical\\n```\\n\\nThat's the whole idea."}|,    ~s|{"title":"Durable Objects with OTP Discipline","author":"grace","tags":["otp","durable"],"body":"## The thesis\\n\\nA **single-owner**, strongly-consistent state machine at the edge.\\n\\n1. order lifecycles\\n2. idempotent payments\\n3. per-account ledgers\\n\\nRun `GenServer` callbacks with state that *survives* restart.\\n\\n---\\n\\nRead `ARCHITECTURE.md` first."}|,    ~s|{"title":"Exact Integers, Bit-for-Bit","author":"linus","tags":["bignum"],"body":"# fact(50)\\n\\nArithmetic is **exact** by default: i31 to `$i64` to host BigInt.\\n\\n> No silent truncation.\\n\\nThe result is *bit-identical* to the Elixir VM."}|  ]

  # entry: pick an article by seed, parse its JSON, render the page; return the HTML as a binary.
  def render(seed) do
    json = Enum.at(@articles, rem(abs(seed), length(@articles)))
    doc = Jason.decode!(json)
    page(doc)
  end

  # ── HTML template ─────────────────────────────────────────────────────────────
  defp page(doc) do
    title = mget(doc, "title", "untitled")
    author = mget(doc, "author", "anon")
    tags = mget(doc, "tags", [])
    body_html = markdown(mget(doc, "body", ""))

    tag_html = tags |> Enum.map(fn t -> "<span class=\"tag\">" <> esc(t) <> "</span>" end) |> Enum.join("")

    "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>" <> esc(title) <>
      "</title></head>\n<body>\n<article>\n<h1>" <> esc(title) <>
      "</h1>\n<div class=\"meta\">by " <> esc(author) <> " &middot; " <> tag_html <>
      "</div>\n" <> body_html <> "</article>\n</body></html>\n"
  end

  # ── markdown -> HTML (line/block based) ─────────────────────────────────────────
  defp markdown(md) do
    md |> split_lines() |> blocks([]) |> Enum.join("")
  end

  # group lines into blocks. acc holds the rendered HTML strings (reversed via [h|t] then reverse at end).
  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks(["" | rest], acc), do: blocks(rest, acc)            # skip blank separators

  defp blocks(["```" <> _ | rest], acc) do                        # fenced code block
    {code, rest2} = take_until_fence(rest, [])
    blocks(rest2, ["<pre><code>" <> esc(Enum.join(code, "\n")) <> "</code></pre>\n" | acc])
  end

  defp blocks(["### " <> h | rest], acc), do: blocks(rest, ["<h3>" <> inline(h) <> "</h3>\n" | acc])
  defp blocks(["## " <> h | rest], acc), do: blocks(rest, ["<h2>" <> inline(h) <> "</h2>\n" | acc])
  defp blocks(["# " <> h | rest], acc), do: blocks(rest, ["<h1>" <> inline(h) <> "</h1>\n" | acc])
  defp blocks(["---" | rest], acc), do: blocks(rest, ["<hr/>\n" | acc])

  defp blocks(["> " <> q | rest], acc) do                         # blockquote (consecutive > lines)
    {qs, rest2} = take_quote([("> " <> q) | rest], [])
    blocks(rest2, ["<blockquote>" <> inline(Enum.join(qs, " ")) <> "</blockquote>\n" | acc])
  end

  defp blocks([line | _rest] = lines, acc) do
    cond do
      bullet?(line) ->
        {items, rest2} = take_list(lines, &bullet?/1, [])
        blocks(rest2, ["<ul>\n" <> render_items(items, &debullet/1) <> "</ul>\n" | acc])

      ordered?(line) ->
        {items, rest2} = take_list(lines, &ordered?/1, [])
        blocks(rest2, ["<ol>\n" <> render_items(items, &deorder/1) <> "</ol>\n" | acc])

      true ->
        {para, rest2} = take_para(lines, [])
        blocks(rest2, ["<p>" <> inline(Enum.join(para, " ")) <> "</p>\n" | acc])
    end
  end

  defp take_until_fence([], acc), do: {Enum.reverse(acc), []}
  defp take_until_fence(["```" <> _ | rest], acc), do: {Enum.reverse(acc), rest}
  defp take_until_fence([l | rest], acc), do: take_until_fence(rest, [l | acc])

  defp take_quote(["> " <> q | rest], acc), do: take_quote(rest, [q | acc])
  defp take_quote(rest, acc), do: {Enum.reverse(acc), rest}

  defp take_list([l | rest], pred, acc) do
    if pred.(l), do: take_list(rest, pred, [l | acc]), else: {Enum.reverse(acc), [l | rest]}
  end
  defp take_list([], _pred, acc), do: {Enum.reverse(acc), []}

  defp take_para([l | rest], acc) do
    if l == "" or block_start?(l), do: {Enum.reverse(acc), [l | rest]}, else: take_para(rest, [l | acc])
  end
  defp take_para([], acc), do: {Enum.reverse(acc), []}

  defp render_items(items, strip) do
    items |> Enum.map(fn i -> "<li>" <> inline(strip.(i)) <> "</li>\n" end) |> Enum.join("")
  end

  defp block_start?(l) do
    bullet?(l) or ordered?(l) or String.starts_with?(l, "#") or String.starts_with?(l, ">") or
      String.starts_with?(l, "```") or l == "---"
  end

  defp bullet?(l), do: String.starts_with?(l, "- ") or String.starts_with?(l, "* ")
  defp debullet("- " <> r), do: r
  defp debullet("* " <> r), do: r
  defp debullet(r), do: r

  # "N. item" detection via binary pattern matching (no Integer.parse — keeps the demo off the
  # binary_to_integer path, which the compiler doesn't support yet).
  defp ordered?(<<c, r::binary>>) when c >= ?0 and c <= ?9, do: after_digits(r)
  defp ordered?(_), do: false
  defp after_digits(<<c, r::binary>>) when c >= ?0 and c <= ?9, do: after_digits(r)
  defp after_digits(". " <> _), do: true
  defp after_digits(_), do: false

  defp deorder(<<c, r::binary>>) when c >= ?0 and c <= ?9, do: deorder(r)
  defp deorder(". " <> r), do: r
  defp deorder(r), do: r

  # ── inline spans: **bold**, *italic*, `code`, [text](url) ──────────────────────
  # single left-to-right scan over the codepoints; emits HTML with entities escaped.
  defp inline(s), do: ins(String.to_charlist(s), [])

  defp ins([], acc), do: acc |> Enum.reverse() |> List.to_string()
  defp ins([?*, ?* | r], acc) do
    {inner, rest} = span_until(r, [?*, ?*], [])
    ins(rest, prepend_rev("<strong>" <> inline(inner) <> "</strong>", acc))
  end
  defp ins([?* | r], acc) do
    {inner, rest} = span_until(r, [?*], [])
    ins(rest, prepend_rev("<em>" <> inline(inner) <> "</em>", acc))
  end
  defp ins([?` | r], acc) do
    {inner, rest} = span_until(r, [?`], [])
    ins(rest, prepend_rev("<code>" <> esc(inner) <> "</code>", acc))
  end
  defp ins([?[ | r], acc) do
    case link_parts(r) do
      {text, url, rest} -> ins(rest, prepend_rev("<a href=\"" <> esc(url) <> "\">" <> inline(text) <> "</a>", acc))
      :no -> ins(r, [?[ | acc])
    end
  end
  defp ins([c | r], acc), do: ins(r, prepend_rev(esc_char(c), acc))

  # collect codepoints until the closing delimiter (a charlist); returns {inner_string, rest_codepoints}
  defp span_until([], _delim, acc), do: {acc |> Enum.reverse() |> List.to_string(), []}
  defp span_until(cs, delim, acc) do
    if List.starts_with?(cs, delim) do
      {acc |> Enum.reverse() |> List.to_string(), Enum.drop(cs, length(delim))}
    else
      [c | r] = cs
      span_until(r, delim, [c | acc])
    end
  end

  defp link_parts(cs) do
    case span_close(cs, ?], []) do
      {text, [?( | r2]} ->
        case span_close(r2, ?), []) do
          {url, rest} -> {text, url, rest}
          :no -> :no
        end
      _ -> :no
    end
  end
  defp span_close([], _d, _acc), do: :no
  defp span_close([d | r], d, acc), do: {acc |> Enum.reverse() |> List.to_string(), r}
  defp span_close([c | r], d, acc), do: span_close(r, d, [c | acc])

  defp prepend_rev(str, acc), do: Enum.reverse(String.to_charlist(str)) ++ acc

  # ── HTML escaping ───────────────────────────────────────────────────────────────
  defp esc(s), do: s |> String.to_charlist() |> Enum.map_join("", &esc_char/1)
  defp esc_char(?&), do: "&amp;"
  defp esc_char(?<), do: "&lt;"
  defp esc_char(?>), do: "&gt;"
  defp esc_char(?"), do: "&quot;"
  defp esc_char(c), do: <<c::utf8>>


  # ── small map/list helpers ──
  defp mget(m, k, default), do: if(Map.has_key?(m, k), do: Map.get(m, k), else: default)

  defp split_lines(s), do: String.split(s, "\n")
end
