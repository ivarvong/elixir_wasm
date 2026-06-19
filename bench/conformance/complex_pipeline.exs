#!/usr/bin/env elixir

# Complex end-to-end conformance: serverless fulfillment pipeline.
#
# The compiled program decodes a batch JSON payload with the real Jason library, routes a sequence
# of domain events through binary string-head clauses, updates immutable maps (inventory, ledger,
# holds, customer risk), calculates exact integer financial totals, and returns a deterministic
# checksum. The same program runs on WasmGC and BEAM for several realistic event batches.
#
#   elixir conformance/complex_pipeline.exs

Mix.install([{:jason, "~> 1.4"}], consolidate_protocols: false)

Code.require_file("../../tooling.exs", __DIR__)

defmodule ComplexPipelineConf do
  @here Path.dirname(__ENV__.file)
  @beam2wasm Path.join(@here, "../../beam2wasm.exs")
  @driver Path.join(@here, "driver.mjs")
  @tmp Path.join(@here, "_work_complex_pipeline")
  @node Tooling.node!()
  @wasmas Tooling.wasmas!()

  @src """
  defmodule ComplexPipelineTarget do
    @base_inventory %{
      "enterprise" => %{
        "SKU-GPU" => {6, 129_900, 1_650},
        "SKU-MONITOR" => {20, 34_900, 5_800},
        "SKU-KEYBOARD" => {50, 12_900, 850},
        "SKU-USB-C" => {200, 899, 60},
        "SKU-STICKER" => {5_000, 199, 5}
      },
      "consumer" => %{
        "SKU-BOOK" => {90, 1_499, 420},
        "SKU-HOODIE" => {40, 5_900, 700},
        "SKU-USB-C" => {150, 899, 60},
        "SKU-STICKER" => {10_000, 199, 5}
      },
      "startup" => %{
        "SKU-GPU" => {2, 129_900, 1_650},
        "SKU-BOOK" => {20, 1_499, 420},
        "SKU-STICKER" => {1_000, 199, 5}
      }
    }

    @risk_rules %{
      "ip_mismatch" => {10, 2},
      "chargeback" => {30, 4},
      "trusted_device" => {-8, -1},
      "velocity" => {12, 3}
    }

    def handle(json) do
      {:ok, batch} = Jason.decode(json)
      tenant = fetch(batch, "tenant")
      request_id = fetch(batch, "request_id")
      events = fetch(batch, "events")

      state = initial_state(tenant)
      final = Enum.reduce(events, state, &apply_event/2)

      score_state(final) + bytesum(request_id, 0) * 97 + bytesum(tenant, 0) * 193
    end

    defp initial_state(tenant) do
      %{
        "tenant" => tenant,
        "inventory" => base_inventory(tenant),
        "holds" => %{},
        "ledger" => %{},
        "risk" => %{},
        "shipments" => %{},
        "audit" => 17
      }
    end

    defp apply_event(event, state) do
      case fetch(event, "type") do
        "inventory.reserve" -> reserve(event, state)
        "inventory.release" -> release(event, state)
        "payment.capture" -> capture(event, state)
        "payment.refund" -> refund(event, state)
        "shipment.create" -> shipment(event, state)
        "risk.signal" -> risk(event, state)
        "price.override" -> price_override(event, state)
        "audit.note" -> bump_audit(state, bytesum(fetch(event, "message"), 0))
        _ -> bump_audit(state, 9_999)
      end
    end

    defp reserve(event, state) do
      order = fetch(event, "order_id")
      items = fetch(event, "items")
      {inventory, hold_value, hold_weight, ok} = reserve_items(items, fetch(state, "inventory"), 0, 0, true)
      hold = %{"value" => hold_value, "weight" => hold_weight, "ok" => ok, "items" => items}

      state
      |> put_in_state(["inventory"], inventory)
      |> put_in_state(["holds", order], hold)
      |> bump_audit(if(ok, do: hold_value, else: -hold_value))
    end

    defp release(event, state) do
      order = fetch(event, "order_id")
      holds = fetch(state, "holds")
      hold = Map.get(holds, order, %{"items" => []})
      inventory = release_items(fetch(hold, "items"), fetch(state, "inventory"))

      state
      |> put_in_state(["inventory"], inventory)
      |> put_in_state(["holds"], Map.delete(holds, order))
      |> bump_audit(bytesum(order, 0) * -3)
    end

    defp capture(event, state) do
      order = fetch(event, "order_id")
      customer = fetch(event, "customer_id")
      method = fetch(event, "method")
      holds = fetch(state, "holds")
      hold = Map.get(holds, order, %{"value" => 0, "weight" => 0, "ok" => false})
      risk_score = Map.get(fetch(state, "risk"), customer, 0)
      value = fetch(hold, "value")
      fee = payment_fee(method, value)
      approved = fetch(hold, "ok") and risk_score < 90
      amount = if(approved, do: value - fee, else: 0)

      state
      |> update_nested_number("ledger", customer, amount)
      |> bump_audit(amount * 5 + risk_score)
    end

    defp refund(event, state) do
      customer = fetch(event, "customer_id")
      amount = fetch(event, "amount_cents")
      ledger = fetch(state, "ledger")
      current = Map.get(ledger, customer, 0)

      state
      |> put_in_state(["ledger"], Map.put(ledger, customer, current - amount))
      |> bump_audit(-amount * 7)
    end

    defp shipment(event, state) do
      order = fetch(event, "order_id")
      region = fetch(event, "region")
      carrier = fetch(event, "carrier")
      hold = Map.get(fetch(state, "holds"), order, %{"weight" => 0, "value" => 0})
      cost = ship_cost(region, carrier, fetch(hold, "weight"), fetch(hold, "value"))
      shipment = %{"cost" => cost, "region" => region, "carrier" => carrier}

      state
      |> put_in_state(["shipments", order], shipment)
      |> bump_audit(cost * 11 + bytesum(carrier, 0))
    end

    defp risk(event, state) do
      customer = fetch(event, "customer_id")
      signal = fetch(event, "signal")
      strength = fetch(event, "strength")
      delta = risk_delta(signal, strength)
      risk = fetch(state, "risk")
      current = Map.get(risk, customer, 0)

      state
      |> put_in_state(["risk"], Map.put(risk, customer, clamp(current + delta, 0, 100)))
      |> bump_audit(delta * 13 + bytesum(signal, 0))
    end

    defp price_override(event, state) do
      sku = fetch(event, "sku")
      new_price = fetch(event, "price_cents")
      inv = fetch(state, "inventory")
      record = Map.get(inv, sku, item(0, 0, 0))
      updated = Map.put(record, "price", new_price)

      state
      |> put_in_state(["inventory", sku], updated)
      |> bump_audit(new_price * 17 + bytesum(sku, 0))
    end

    defp reserve_items(items, inventory, value, weight, ok) do
      Enum.reduce(items, {inventory, value, weight, ok}, fn line, {inv, val, w, valid?} ->
        sku = fetch(line, "sku")
        qty = fetch(line, "qty")
        record = Map.get(inv, sku, item(0, 0, 0))
        available = fetch(record, "stock")
        take = min(qty, available)
        next_record = Map.put(record, "stock", available - take)
        line_ok? = qty == take and qty > 0
        {Map.put(inv, sku, next_record), val + take * fetch(record, "price"), w + take * fetch(record, "weight"), valid? and line_ok?}
      end)
    end

    defp release_items(items, inventory) do
      Enum.reduce(items, inventory, fn line, inv ->
        sku = fetch(line, "sku")
        qty = fetch(line, "qty")
        record = Map.get(inv, sku, item(0, 0, 0))
        Map.put(inv, sku, Map.put(record, "stock", fetch(record, "stock") + qty))
      end)
    end

    defp payment_fee(method, amount) do
      case method do
        "card" -> div(amount * 29, 1000) + 30
        "wallet" -> div(amount * 12, 1000)
        "bank" -> 75
        _ -> div(amount * 50, 1000)
      end
    end

    defp ship_cost(region, carrier, weight, value) do
      {base, weight_bps, value_divisor} =
        case {region, carrier} do
          {"US-CA", "ground"} -> {499, 19, 100_000}
          {"US-NY", "ground"} -> {599, 23, 90_000}
          {"EU-DE", "air"} -> {1_899, 41, 50_000}
          {"EU-FR", "air"} -> {1_999, 43, 50_000}
          {"AP-SG", "air"} -> {2_999, 57, 40_000}
          _ -> {999, 35, 75_000}
        end

      base + div(weight * weight_bps, 100) + div(value, value_divisor)
    end

    defp risk_delta(signal, strength) do
      case Map.get(@risk_rules, signal) do
        {base, multiplier} -> base + strength * multiplier
        nil -> strength
      end
    end

    defp score_state(state) do
      score_inventory(fetch(state, "inventory"), 0) * 3 +
        score_number_map(fetch(state, "ledger"), 5) * 7 +
        score_number_map(fetch(state, "risk"), 11) * 13 +
        score_shipments(fetch(state, "shipments"), 17) * 19 +
        fetch(state, "audit") * 23
    end

    defp score_inventory(map, acc), do: score_inventory_pairs(:lists.sort(Map.to_list(map)), acc)
    defp score_inventory_pairs([], acc), do: acc
    defp score_inventory_pairs([{sku, record} | rest], acc) do
      v = bytesum(sku, 0) * 31 + fetch(record, "stock") * 37 + fetch(record, "price") * 41 + fetch(record, "weight") * 43
      score_inventory_pairs(rest, acc * 47 + v)
    end

    defp score_number_map(map, seed), do: score_number_pairs(:lists.sort(Map.to_list(map)), seed)
    defp score_number_pairs([], acc), do: acc
    defp score_number_pairs([{k, v} | rest], acc), do: score_number_pairs(rest, acc * 53 + bytesum(k, 0) * 59 + v)

    defp score_shipments(map, seed), do: score_shipment_pairs(:lists.sort(Map.to_list(map)), seed)
    defp score_shipment_pairs([], acc), do: acc
    defp score_shipment_pairs([{order, s} | rest], acc) do
      v = bytesum(order, 0) * 61 + fetch(s, "cost") * 67 + bytesum(fetch(s, "region"), 0) * 71 + bytesum(fetch(s, "carrier"), 0) * 73
      score_shipment_pairs(rest, acc * 79 + v)
    end

    defp base_inventory(tenant) do
      @base_inventory
      |> Map.get(tenant, Map.fetch!(@base_inventory, "startup"))
      |> map_inventory()
    end

    defp map_inventory(raw), do: Map.new(raw, fn {sku, {stock, price, weight}} -> {sku, item(stock, price, weight)} end)

    defp item(stock, price, weight), do: %{"stock" => stock, "price" => price, "weight" => weight}

    defp fetch(map, key), do: Map.fetch!(map, key)
    defp put_in_state(state, [key], value), do: Map.put(state, key, value)
    defp put_in_state(state, [key, nested_key], value), do: Map.update!(state, key, &Map.put(&1, nested_key, value))

    defp update_nested_number(state, key, nested_key, delta) do
      Map.update!(state, key, fn nested -> Map.put(nested, nested_key, Map.get(nested, nested_key, 0) + delta) end)
    end

    defp bump_audit(state, delta), do: Map.put(state, "audit", fetch(state, "audit") * 83 + delta)

    defp clamp(n, lo, _hi) when n < lo, do: lo
    defp clamp(n, _lo, hi) when n > hi, do: hi
    defp clamp(n, _lo, _hi), do: n

    defp bytesum(<<>>, acc), do: acc
    defp bytesum(<<c, rest::binary>>, acc), do: bytesum(rest, acc + c)
  end
  """

  @events [
    ~s({"tenant":"enterprise","request_id":"req_complex_001","events":[{"type":"risk.signal","customer_id":"cust-a","signal":"trusted_device","strength":3},{"type":"inventory.reserve","order_id":"ord-a","items":[{"sku":"SKU-GPU","qty":2},{"sku":"SKU-MONITOR","qty":3},{"sku":"SKU-USB-C","qty":10}]},{"type":"shipment.create","order_id":"ord-a","region":"EU-DE","carrier":"air"},{"type":"payment.capture","order_id":"ord-a","customer_id":"cust-a","method":"card"},{"type":"audit.note","message":"packed by robot 7"}]}),
    ~s({"tenant":"consumer","request_id":"req_complex_002","events":[{"type":"inventory.reserve","order_id":"ord-b","items":[{"sku":"SKU-BOOK","qty":4},{"sku":"SKU-HOODIE","qty":2},{"sku":"SKU-STICKER","qty":25}]},{"type":"risk.signal","customer_id":"cust-b","signal":"velocity","strength":9},{"type":"payment.capture","order_id":"ord-b","customer_id":"cust-b","method":"wallet"},{"type":"shipment.create","order_id":"ord-b","region":"US-CA","carrier":"ground"},{"type":"payment.refund","customer_id":"cust-b","amount_cents":1499}]}),
    ~s({"tenant":"startup","request_id":"req_complex_003","events":[{"type":"price.override","sku":"SKU-GPU","price_cents":149900},{"type":"inventory.reserve","order_id":"ord-c","items":[{"sku":"SKU-GPU","qty":3},{"sku":"SKU-BOOK","qty":1}]},{"type":"risk.signal","customer_id":"cust-c","signal":"chargeback","strength":12},{"type":"payment.capture","order_id":"ord-c","customer_id":"cust-c","method":"card"},{"type":"inventory.release","order_id":"ord-c"},{"type":"audit.note","message":"manual review required"}]}),
    ~s({"tenant":"enterprise","request_id":"req_complex_004","events":[{"type":"inventory.reserve","order_id":"ord-d1","items":[{"sku":"SKU-KEYBOARD","qty":5},{"sku":"SKU-USB-C","qty":12}]},{"type":"payment.capture","order_id":"ord-d1","customer_id":"cust-d","method":"bank"},{"type":"inventory.reserve","order_id":"ord-d2","items":[{"sku":"SKU-MONITOR","qty":4}]},{"type":"shipment.create","order_id":"ord-d1","region":"US-NY","carrier":"ground"},{"type":"shipment.create","order_id":"ord-d2","region":"AP-SG","carrier":"air"},{"type":"risk.signal","customer_id":"cust-d","signal":"ip_mismatch","strength":4}]}),
    ~s({"tenant":"unknown","request_id":"req_complex_005","events":[{"type":"inventory.reserve","order_id":"ord-e","items":[{"sku":"SKU-STICKER","qty":100},{"sku":"SKU-BOOK","qty":2}]},{"type":"unknown.event","payload":{"x":1}},{"type":"payment.capture","order_id":"ord-e","customer_id":"cust-e","method":"crypto"},{"type":"shipment.create","order_id":"ord-e","region":"XX-ZZ","carrier":"drone"},{"type":"payment.refund","customer_id":"cust-e","amount_cents":777}]}),
    ~s({"tenant":"consumer","request_id":"req_complex_006","events":[{"type":"risk.signal","customer_id":"cust-f","signal":"ip_mismatch","strength":8},{"type":"risk.signal","customer_id":"cust-f","signal":"trusted_device","strength":5},{"type":"inventory.reserve","order_id":"ord-f","items":[{"sku":"SKU-HOODIE","qty":1},{"sku":"SKU-USB-C","qty":1}]},{"type":"shipment.create","order_id":"ord-f","region":"EU-FR","carrier":"air"},{"type":"payment.capture","order_id":"ord-f","customer_id":"cust-f","method":"wallet"}]})
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

    watf = Path.join(@tmp, "ComplexPipelineTarget.wat")
    wasmf = Path.join(@tmp, "ComplexPipelineTarget.wasm")
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
      Bench.report("complex-pipeline", mod, :handle, @events, wasmf, casesf)
    end

    {out, 0} = System.cmd(@node, [@driver, wasmf, watf, casesf], stderr_to_stdout: true)
    actual = String.split(String.trim_trailing(out), "\n", trim: false)
    expected = Enum.map(@events, fn event -> Integer.to_string(apply(mod, :handle, [event])) end)
    failures = Enum.zip(@events, Enum.zip(expected, actual)) |> Enum.filter(fn {_event, {exp, got}} -> exp != got end)

    IO.puts("\n══════════ COMPLEX PIPELINE CONFORMANCE: WasmGC vs BEAM ══════════\n")
    if failures == [] do
      IO.puts("✅ complex-pipeline #{length(@events)}/#{length(@events)}")
    else
      IO.puts("⚠️  complex-pipeline #{length(@events) - length(failures)}/#{length(@events)}")
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

ComplexPipelineConf.main()
