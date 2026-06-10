defmodule JsonDemo do
  # Real Jason (the hex dependency) encoding real Elixir data to JSON, compiled to WasmGC,
  # bit-exact with the BEAM. Decode is blocked on a 64-bit-integer tier (Jason's SWAR UTF-8 path).
  def order_json do
    %{"item" => "widget", "qty" => 3, "active" => true, "tags" => ["new", "sale"]}
    |> Map.put("shipped", false)
    |> Map.update!("qty", &(&1 + 1))
    |> Jason.encode!()
  end
  def report_json do
    rows = [[1, 2, 3], [4, 5, 6]]
    Jason.encode!(%{squares: Enum.map(rows, fn r -> Enum.map(r, fn x -> x * x end) end),
                    sums: Enum.map(rows, fn r -> Enum.sum(r) end),
                    note: nil})
  end
  def scalars_json, do: Jason.encode!([1, -42, true, false, nil, "he said \"hi\"", "tab\there"])
end
