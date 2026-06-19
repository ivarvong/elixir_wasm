#!/usr/bin/env elixir

# Realistic end-to-end conformance: a Lambda-style order processor.
#
# It decodes a JSON checkout event with the real Jason library, computes catalog totals,
# discounts, shipping, tax, inventory/limit validation, fraud risk, and a deterministic receipt
# checksum. The same compiled program is run on WasmGC and BEAM for a corpus of realistic events.
#
#   elixir conformance/realistic_order.exs

Mix.install([{:jason, "~> 1.4"}], consolidate_protocols: false)

Code.require_file("../../tooling.exs", __DIR__)

defmodule RealisticOrderConf do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../../beam2wasm.exs")
  @driver Path.join(@here, "driver.mjs")
  @tmp Path.join(@here, "_work_realistic_order")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()

  @src """
  defmodule RealisticOrderTarget do
    @prices %{"SKU-BOOK" => 1_499, "SKU-USB-C" => 899, "SKU-KEYBOARD" => 12_900, "SKU-MONITOR" => 34_900, "SKU-GPU" => 129_900, "SKU-HOODIE" => 5_900, "SKU-STICKER" => 199}
    @weights %{"SKU-BOOK" => 420, "SKU-USB-C" => 60, "SKU-KEYBOARD" => 850, "SKU-MONITOR" => 5_800, "SKU-GPU" => 1_650, "SKU-HOODIE" => 700, "SKU-STICKER" => 5}
    @stock %{"SKU-GPU" => 4, "SKU-MONITOR" => 12, "SKU-STICKER" => 10_000}
    @max_qty %{"SKU-GPU" => 2, "SKU-MONITOR" => 3}
    @high_demand %{"SKU-GPU" => true, "SKU-MONITOR" => true}
    @shipping %{"US-CA" => 799, "US-NY" => 899, "EU-DE" => 1_499, "EU-FR" => 1_599, "AP-SG" => 2_499}
    @tax %{"US-CA" => 875, "US-NY" => 800, "EU-DE" => 1_900, "EU-FR" => 2_000, "AP-SG" => 900}
    @tier_discount %{"gold" => 7, "silver" => 3}

    def handle(json) do
      {:ok, event} = Jason.decode(json)

      customer = fetch(event, "customer")
      cart = fetch(event, "cart")
      address = fetch(event, "address")
      context = fetch(event, "context")

      region = fetch(address, "region")
      tier = fetch(customer, "tier")
      lines = fetch(cart, "items")
      codes = fetch(cart, "promo_codes")

      subtotal = subtotal(lines)
      weight = weight(lines)
      discount = discounts(subtotal, codes, tier)
      shipping = shipping_cents(weight, region, codes, subtotal - discount)
      tax = div((subtotal - discount + shipping) * tax_bps(region), 10_000)
      risk = risk_score(customer, address, context, subtotal, lines)
      valid = valid_cart?(lines) and subtotal > 0 and risk < 85

      total = subtotal - discount + shipping + tax
      decision = if(valid, do: decision_score(total, risk), else: -decision_score(total, risk))

      checksum(event, subtotal, discount, shipping, tax, risk, total, decision)
    end

    defp fetch(map, key), do: Map.fetch!(map, key)

    defp subtotal(lines), do: Enum.reduce(lines, 0, fn item, acc -> acc + line_subtotal(item) end)
    defp weight(lines), do: Enum.reduce(lines, 0, fn item, acc -> acc + fetch(item, "qty") * product_weight(fetch(item, "sku")) end)

    defp line_subtotal(item) do
      sku = fetch(item, "sku")
      qty = fetch(item, "qty")
      qty * price_cents(sku)
    end

    defp discounts(subtotal, codes, tier) do
      code_discount(codes, subtotal) + tier_discount(tier, subtotal)
    end

    defp code_discount(codes, subtotal), do: Enum.reduce(codes, 0, fn code, acc -> acc + one_code_discount(code, subtotal) end)

    defp one_code_discount(code, subtotal) do
      case code do
        "WELCOME10" -> div(subtotal * 10, 100)
        "VIP5" -> div(subtotal * 5, 100)
        "SAVE25" -> min(div(subtotal * 25, 100), 15_000)
        _ -> 0
      end
    end

    defp tier_discount(tier, subtotal), do: div(subtotal * Map.get(@tier_discount, tier, 0), 100)

    defp shipping_cents(weight, region, codes, net) do
      free = has_code?(codes, "FREESHIP") or net >= 75_000
      if free do
        0
      else
        base_shipping(region) + div(weight * 37, 100)
      end
    end

    defp has_code?(codes, code), do: Enum.any?(codes, &(&1 == code))

    defp valid_cart?([]), do: false
    defp valid_cart?(items), do: all_lines_valid?(items)
    defp all_lines_valid?(items), do: Enum.all?(items, &line_valid?/1)

    defp line_valid?(item) do
      sku = fetch(item, "sku")
      qty = fetch(item, "qty")
      qty > 0 and qty <= stock(sku) and qty <= max_qty(sku)
    end

    defp risk_score(customer, address, context, subtotal, lines) do
      email = fetch(customer, "email")
      age_days = fetch(customer, "account_age_days")
      attempts = fetch(context, "attempts_24h")
      ip_region = fetch(context, "ip_region")
      region = fetch(address, "region")

      0
      |> add_if(age_days < 7, 25)
      |> add_if(attempts > 5, 20)
      |> add_if(subtotal > 200_000, 20)
      |> add_if(ip_region != region, 18)
      |> add_if(disposable_email?(email), 22)
      |> add_if(high_demand_quantity(lines) > 2, 12)
    end

    defp add_if(acc, true, n), do: acc + n
    defp add_if(acc, false, _n), do: acc

    defp disposable_email?(email) do
      ends_with?(email, "@tempmail.test") or ends_with?(email, "@throwaway.test")
    end

    defp ends_with?(s, suffix), do: String.ends_with?(s, suffix)

    defp high_demand_quantity(items) do
      Enum.reduce(items, 0, fn item, acc ->
        sku = fetch(item, "sku")
        if high_demand?(sku), do: acc + fetch(item, "qty"), else: acc
      end)
    end

    defp decision_score(total, risk), do: total * 101 - risk * 97

    defp checksum(event, subtotal, discount, shipping, tax, risk, total, decision) do
      customer = fetch(event, "customer")
      address = fetch(event, "address")
      cart = fetch(event, "cart")

      order_hash = bytesum(fetch(event, "order_id"), 0)
      email_hash = bytesum(fetch(customer, "email"), 0)
      region_hash = bytesum(fetch(address, "region"), 0)
      promo_hash = score_strings(fetch(cart, "promo_codes"), 0)

      subtotal * 3 + discount * 5 + shipping * 7 + tax * 11 + risk * 13 + total * 17 + decision +
        order_hash * 19 + email_hash * 23 + region_hash * 29 + promo_hash * 31
    end

    defp bytesum(<<>>, acc), do: acc
    defp bytesum(<<c, rest::binary>>, acc), do: bytesum(rest, acc + c)

    defp score_strings(strings, acc), do: Enum.reduce(strings, acc, fn s, total -> total * 41 + bytesum(s, 0) end)

    defp price_cents(sku), do: Map.get(@prices, sku, 0)
    defp product_weight(sku), do: Map.get(@weights, sku, 0)
    defp stock(sku), do: Map.get(@stock, sku, 100)
    defp max_qty(sku), do: Map.get(@max_qty, sku, 20)
    defp high_demand?(sku), do: Map.get(@high_demand, sku, false)
    defp base_shipping(region), do: Map.get(@shipping, region, 1_999)
    defp tax_bps(region), do: Map.get(@tax, region, 0)
  end
  """

  @events [
    ~s({"order_id":"ord_1001","customer":{"email":"ada@example.com","tier":"gold","account_age_days":900},"address":{"region":"US-CA"},"context":{"ip_region":"US-CA","attempts_24h":1},"cart":{"promo_codes":["WELCOME10"],"items":[{"sku":"SKU-BOOK","qty":2},{"sku":"SKU-USB-C","qty":3},{"sku":"SKU-HOODIE","qty":1}]}}),
    ~s({"order_id":"ord_1002","customer":{"email":"new@tempmail.test","tier":"bronze","account_age_days":2},"address":{"region":"US-NY"},"context":{"ip_region":"EU-DE","attempts_24h":8},"cart":{"promo_codes":["SAVE25"],"items":[{"sku":"SKU-GPU","qty":1},{"sku":"SKU-MONITOR","qty":1}]}}),
    ~s({"order_id":"ord_1003","customer":{"email":"lin@example.org","tier":"silver","account_age_days":120},"address":{"region":"EU-DE"},"context":{"ip_region":"EU-DE","attempts_24h":2},"cart":{"promo_codes":["FREESHIP","VIP5"],"items":[{"sku":"SKU-KEYBOARD","qty":1},{"sku":"SKU-STICKER","qty":10}]}}),
    ~s({"order_id":"ord_1004","customer":{"email":"ops@company.test","tier":"gold","account_age_days":1300},"address":{"region":"AP-SG"},"context":{"ip_region":"AP-SG","attempts_24h":1},"cart":{"promo_codes":[],"items":[{"sku":"SKU-MONITOR","qty":3},{"sku":"SKU-USB-C","qty":5},{"sku":"SKU-BOOK","qty":4}]}}),
    ~s({"order_id":"ord_1005","customer":{"email":"bulk@example.com","tier":"silver","account_age_days":30},"address":{"region":"US-CA"},"context":{"ip_region":"US-CA","attempts_24h":4},"cart":{"promo_codes":["WELCOME10","FREESHIP"],"items":[{"sku":"SKU-STICKER","qty":250},{"sku":"SKU-HOODIE","qty":2}]}}),
    ~s({"order_id":"ord_1006","customer":{"email":"fraud@throwaway.test","tier":"bronze","account_age_days":1},"address":{"region":"EU-FR"},"context":{"ip_region":"US-NY","attempts_24h":12},"cart":{"promo_codes":["SAVE25","WELCOME10"],"items":[{"sku":"SKU-GPU","qty":3},{"sku":"SKU-MONITOR","qty":2}]}}),
    ~s({"order_id":"ord_1007","customer":{"email":"small@example.net","tier":"bronze","account_age_days":80},"address":{"region":"US-NY"},"context":{"ip_region":"US-NY","attempts_24h":1},"cart":{"promo_codes":["NOPE"],"items":[{"sku":"SKU-BOOK","qty":1}]}}),
    ~s({"order_id":"ord_1008","customer":{"email":"vip@example.net","tier":"gold","account_age_days":5000},"address":{"region":"EU-DE"},"context":{"ip_region":"EU-FR","attempts_24h":3},"cart":{"promo_codes":["VIP5","SAVE25"],"items":[{"sku":"SKU-GPU","qty":2},{"sku":"SKU-KEYBOARD","qty":2},{"sku":"SKU-HOODIE","qty":4}]}})
  ]

  def main do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)

    [{mod, beam}] = Code.compile_string(@src)
    target = Path.join(@tmp, "#{mod}.beam")
    File.write!(target, beam)

    jason_beams = Path.wildcard(Path.join([Path.dirname(to_string(:code.which(Jason))), "*.beam"]))
    extra_beams = Enum.map([Enum, Map, Access, Keyword, List, String, :lists, :maps], fn m -> to_string(:code.which(m)) end)
    exports = "handle:bin->int"

    {wat, 0} = System.cmd("elixir", [@beam2wasm, target] ++ jason_beams ++ extra_beams,
      env: [{"EXPORTS", exports}, {"STUB", "1"}], stderr_to_stdout: false)

    watf = Path.join(@tmp, "RealisticOrderTarget.wat")
    wasmf = Path.join(@tmp, "RealisticOrderTarget.wasm")
    casesf = Path.join(@tmp, "cases.json")

    File.write!(watf, wat)
    {asm, 0} = System.cmd(@wasmas, Tooling.wasm_as_args(watf, wasmf), stderr_to_stdout: true)
    if asm != "", do: IO.write(asm)

    cases = Enum.map(@events, fn event ->
      %{"name" => "handle", "ret" => "int", "args" => [%{"type" => "bin", "val" => event}]}
    end)
    File.write!(casesf, IO.iodata_to_binary(:json.encode(cases)))

    if System.get_env("BENCH") do
      Code.require_file("_bench.exs", @here)
      Bench.report("realistic-order", mod, :handle, @events, wasmf, casesf)
    end

    {out, 0} = System.cmd(@node, [@driver, wasmf, watf, casesf], stderr_to_stdout: true)
    actual = String.split(String.trim_trailing(out), "\n", trim: false)
    expected = Enum.map(@events, fn event -> Integer.to_string(apply(mod, :handle, [event])) end)
    failures = Enum.zip(@events, Enum.zip(expected, actual)) |> Enum.filter(fn {_event, {exp, got}} -> exp != got end)

    IO.puts("\n══════════ REALISTIC ORDER CONFORMANCE: WasmGC vs BEAM ══════════\n")
    if failures == [] do
      IO.puts("✅ realistic-order #{length(@events)}/#{length(@events)}")
    else
      IO.puts("⚠️  realistic-order #{length(@events) - length(failures)}/#{length(@events)}")
      for {event, {exp, got}} <- failures do
        IO.puts("       ✗ #{inspect(event)}  got #{inspect(got)}  exp #{inspect(exp)}")
      end
    end

    IO.puts("\n──────────────────────────────────────────────────────────────")
    IO.puts("  TOTAL: #{length(@events) - length(failures)}/#{length(@events)} cases bit-exact vs the VM")
    IO.puts("──────────────────────────────────────────────────────────────\n")

    if failures != [], do: System.halt(1)
  end
end

RealisticOrderConf.main()
