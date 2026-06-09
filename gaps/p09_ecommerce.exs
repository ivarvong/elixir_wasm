# extra: Enum Map List Keyword Integer
# An e-commerce pricing & inventory engine: a catalog of products (sku -> {price, weight, stock}) is
# synthesized from the seed, then random carts are generated, priced with discounts/coupons/tax and
# tiered shipping (driven by Keyword options), stock is decremented (out-of-stock lines rejected),
# orders are grouped by region, and summary statistics produced. Heavy Map/Enum/Keyword/Integer/tuple
# work. Money is in integer cents. Every result folds into a rolling checksum. Pure & deterministic.
defmodule Gap09 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616
  @skus ~w(widget gadget gizmo sprocket cog bolt nut washer gear spring)a
  @regions ~w(north south east west)a

  def run(seed) when is_integer(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    h = 14_695_981

    pricing_opts = [tax_bps: 825, free_ship_threshold: 5000, ship_base: 499, ship_per_kg: 75]

    # ---- build catalog ----
    {catalog, s1} = build_catalog(@skus, s0, %{})

    h =
      fold_map(
        h,
        Map.new(catalog, fn {sku, {price, weight, stock}} ->
          {Atom.to_string(sku), price * 1000 + weight * 10 + min(stock, 9)}
        end)
      )

    h = mix(h, catalog |> Map.values() |> Enum.map(fn {p, _, _} -> p end) |> Enum.sum())
    h = mix(h, catalog |> Map.values() |> Enum.map(fn {_, _, st} -> st end) |> Enum.sum())

    # ---- generate carts ----
    {carts, s2} = gen_carts(40 + rem(seed, 20), s1, [])
    h = mix(h, length(carts))

    # ---- process each cart into an order, mutating shared inventory ----
    {orders, final_catalog} = process_carts(carts, catalog, pricing_opts, [])

    h = mix(h, length(orders))

    # fold every order's salient fields
    h =
      Enum.reduce(orders, h, fn order, a ->
        a
        |> mix(order.id)
        |> mix(Atom.to_string(order.region))
        |> mix(order.subtotal)
        |> mix(order.discount)
        |> mix(order.tax)
        |> mix(order.shipping)
        |> mix(order.total)
        |> mix(length(order.lines))
        |> mix(order.rejected)
      end)

    # ---- final inventory ----
    h =
      fold_map(
        h,
        Map.new(final_catalog, fn {sku, {_p, _w, stock}} -> {Atom.to_string(sku), stock} end)
      )

    # inventory conservation: units sold == opening - closing stock
    opening_stock = catalog |> Map.values() |> Enum.map(fn {_, _, s} -> s end) |> Enum.sum()
    closing_stock = final_catalog |> Map.values() |> Enum.map(fn {_, _, s} -> s end) |> Enum.sum()
    units_sold = Enum.reduce(orders, 0, fn o, acc -> acc + o.units end)
    h = h |> mix(opening_stock) |> mix(closing_stock) |> mix(units_sold)
    h = mix(h, bool_int(opening_stock - closing_stock == units_sold))

    # ---- group orders by region and summarize ----
    by_region = Enum.group_by(orders, & &1.region)

    region_revenue =
      Map.new(by_region, fn {region, os} ->
        {Atom.to_string(region), os |> Enum.map(& &1.total) |> Enum.sum()}
      end)

    h = fold_map(h, region_revenue)

    region_counts = Map.new(by_region, fn {region, os} -> {Atom.to_string(region), length(os)} end)
    h = fold_map(h, region_counts)

    # average order value per region (integer cents)
    region_aov =
      Map.new(by_region, fn {region, os} ->
        {Atom.to_string(region), div(os |> Enum.map(& &1.total) |> Enum.sum(), max(length(os), 1))}
      end)

    h = fold_map(h, region_aov)

    # ---- global statistics ----
    totals = Enum.map(orders, & &1.total)

    h =
      case totals do
        [] ->
          mix(h, 0)

        _ ->
          {mn, mx} = Enum.min_max(totals)
          h |> mix(mn) |> mix(mx) |> mix(Enum.sum(totals)) |> mix(div(Enum.sum(totals), length(totals)))
      end

    # gross revenue, total tax collected, total shipping, total discounts
    gross = Enum.reduce(orders, 0, fn o, a -> a + o.total end)
    tax_collected = Enum.reduce(orders, 0, fn o, a -> a + o.tax end)
    ship_collected = Enum.reduce(orders, 0, fn o, a -> a + o.shipping end)
    disc_given = Enum.reduce(orders, 0, fn o, a -> a + o.discount end)
    h = h |> mix(gross) |> mix(tax_collected) |> mix(ship_collected) |> mix(disc_given)

    # best-selling sku across all orders
    sku_units =
      Enum.reduce(orders, %{}, fn o, acc ->
        Enum.reduce(o.lines, acc, fn {sku, qty, _line_total}, m ->
          Map.update(m, sku, qty, &(&1 + qty))
        end)
      end)

    h = fold_map(h, Map.new(sku_units, fn {k, v} -> {Atom.to_string(k), v} end))

    h =
      case map_size(sku_units) do
        0 ->
          mix(h, 0)

        _ ->
          {best_sku, best_qty} = Enum.max_by(sku_units, fn {_, v} -> v end)
          h |> mix(Atom.to_string(best_sku)) |> mix(best_qty)
      end

    # coupon usage tally
    coupon_orders = Enum.count(orders, fn o -> o.discount > 0 end)
    free_ship_orders = Enum.count(orders, fn o -> o.shipping == 0 end)
    h = h |> mix(coupon_orders) |> mix(free_ship_orders)

    h = mix(h, s2)
    h
  end

  # ---- catalog ----
  defp build_catalog(skus, s, acc) do
    Enum.reduce(skus, {acc, s}, fn sku, {m, sa} ->
      {price, sb} = rng(sa, 9000)
      {weight, sc} = rng(sb, 5000)
      {stock, sd} = rng(sc, 100)
      {Map.put(m, sku, {price + 100, weight + 50, stock + 10}), sd}
    end)
    |> then(fn {m, sf} -> {m, sf} end)
  end

  # ---- cart generation: each cart has a region, a coupon flag, and a set of line items ----
  defp gen_carts(0, s, acc), do: {Enum.reverse(acc), s}

  defp gen_carts(n, s, acc) do
    {ri, s1} = rng(s, length(@regions))
    region = Enum.at(@regions, ri)
    {nlines, s2} = rng(s1, 4)
    {lines, s3} = gen_lines(nlines + 1, s2, [])
    {coupon_roll, s4} = rng(s3, 3)
    coupon = if coupon_roll == 0, do: :save10, else: :none

    cart = %{region: region, lines: lines, coupon: coupon}
    gen_carts(n - 1, s4, [cart | acc])
  end

  defp gen_lines(0, s, acc), do: {Enum.reverse(acc), s}

  defp gen_lines(n, s, acc) do
    {si, s1} = rng(s, length(@skus))
    sku = Enum.at(@skus, si)
    {qty, s2} = rng(s1, 6)
    gen_lines(n - 1, s2, [{sku, qty + 1} | acc])
  end

  # ---- order processing ----
  defp process_carts([], catalog, _opts, acc), do: {Enum.reverse(acc), catalog}

  defp process_carts([cart | rest], catalog, opts, acc) do
    id = length(acc) + 1
    {order, new_catalog} = price_cart(cart, catalog, opts, id)
    process_carts(rest, new_catalog, opts, [order | acc])
  end

  defp price_cart(cart, catalog, opts, id) do
    # fulfill each line against available stock
    {fulfilled, rejected, catalog2, units} =
      Enum.reduce(cart.lines, {[], 0, catalog, 0}, fn {sku, qty}, {lines, rej, cat, u} ->
        {price, _weight, stock} = Map.fetch!(cat, sku)

        if stock >= qty do
          line_total = price * qty
          cat = Map.update!(cat, sku, fn {p, w, st} -> {p, w, st - qty} end)
          {[{sku, qty, line_total} | lines], rej, cat, u + qty}
        else
          {lines, rej + 1, cat, u}
        end
      end)

    fulfilled = Enum.reverse(fulfilled)
    subtotal = Enum.reduce(fulfilled, 0, fn {_, _, lt}, a -> a + lt end)

    # discount: coupon gives 10% off, plus a volume discount for big orders
    coupon_disc = if cart.coupon == :save10, do: div(subtotal * 10, 100), else: 0
    volume_disc = if subtotal > 20_000, do: div(subtotal * 5, 100), else: 0
    discount = coupon_disc + volume_disc
    discounted = subtotal - discount

    # total weight for shipping
    weight =
      Enum.reduce(fulfilled, 0, fn {sku, qty, _}, a ->
        {_p, w, _s} = Map.fetch!(catalog, sku)
        a + w * qty
      end)

    shipping = ship_cost(discounted, weight, opts)
    tax = div(discounted * Keyword.fetch!(opts, :tax_bps), 10_000)
    total = discounted + tax + shipping

    order = %{
      id: id,
      region: cart.region,
      lines: fulfilled,
      units: units,
      subtotal: subtotal,
      discount: discount,
      tax: tax,
      shipping: shipping,
      total: total,
      rejected: rejected
    }

    {order, catalog2}
  end

  defp ship_cost(discounted, weight_grams, opts) do
    threshold = Keyword.fetch!(opts, :free_ship_threshold)

    if discounted >= threshold do
      0
    else
      base = Keyword.fetch!(opts, :ship_base)
      per_kg = Keyword.fetch!(opts, :ship_per_kg)
      kg = div(weight_grams + 999, 1000)
      base + per_kg * kg
    end
  end

  defp bool_int(true), do: 1
  defp bool_int(false), do: 0

  # ---- shared checksum kit (identical across the gap corpus) ----
  defp rng(s, m), do: {rem(div(s, 65_536), max(m, 1)), nxt(s)}
  defp nxt(s), do: rem(s * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407, @lcg)
  defp mix(h, x), do: rem(h * 1_000_003 + intify(x) + 1, @cmod)
  defp fold_list(h, l), do: Enum.reduce(l, h, fn e, a -> mix(a, e) end)
  defp fold_map(h, m), do: Enum.reduce(Enum.sort(Map.to_list(m)), h, fn {k, v}, a -> a |> mix(k) |> mix(v) end)
  defp intify(x) when is_integer(x), do: rem(abs(x), @cmod)
  defp intify(x) when is_float(x), do: trunc(x * 1_000_000)
  defp intify(x) when is_binary(x), do: bsum(x, 7)
  defp intify(true), do: 2
  defp intify(false), do: 3
  defp intify(nil), do: 5
  defp intify(x) when is_atom(x), do: bsum(Atom.to_string(x), 11)
  defp intify(x) when is_list(x), do: Enum.reduce(x, 13, fn e, a -> mix(a, intify(e)) end)
  defp intify(x) when is_tuple(x), do: intify(Tuple.to_list(x))
  defp bsum(<<>>, a), do: a
  defp bsum(<<c, r::binary>>, a), do: bsum(r, rem(a * 131 + c, @cmod))
end
