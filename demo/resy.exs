defmodule Resy do
  # "Get me all the JS URLs on resy.com, and a SHA-256 of them" — a real program with TWO host boundaries.
  #
  #   * Req.get!/1   — HTTP. Effect (socket); transport can't compile → crosses to the host.
  #   * :crypto.hash — OpenSSL NIF. Native; can't compile → crosses to the host (node/WebCrypto).
  #
  # Everything between — pulling `src="…"` out of the HTML, filter/dedup/sort, and the pure hex encoder —
  # compiles to WasmGC. Same source on the VM and on Wasm. The fetch is held constant (one capture); the
  # hash is deterministic (same standard algorithm on OpenSSL and node), so the outputs must be identical.
  def run do
    %{body: html} = Req.get!("https://resy.com")

    urls = html |> extract_js_urls() |> Enum.uniq() |> Enum.sort()
    joined = Enum.join(urls, "\n")
    digest = :crypto.hash(:sha256, joined)

    joined <> "\n\nsha256(urls) = " <> hex(digest)
  end

  defp extract_js_urls(html) do
    html
    |> String.split(~s(src="))
    |> tl()
    |> Enum.map(fn chunk -> chunk |> String.split(~s(")) |> hd() end)
    |> Enum.filter(fn url -> String.contains?(url, ".js") end)
  end

  # pure byte→hex (no stdlib deps): recursion + bs_create_bin + binary concat, all byte-aligned.
  defp hex(<<>>), do: ""
  defp hex(<<b, rest::binary>>), do: <<hexc(div(b, 16)), hexc(rem(b, 16))>> <> hex(rest)
  defp hexc(n) when n < 10, do: ?0 + n
  defp hexc(n), do: ?a + (n - 10)
end
