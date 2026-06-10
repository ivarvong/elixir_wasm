defmodule Sqlite do
  @moduledoc """
  A SQLite client for compiled Elixir. `:sql_host.exec/2` is a host import — exactly the
  NIF model: the host decides the engine (node:sqlite locally, the Durable Object's
  synchronous `ctx.storage.sql` in production). Params and rows ride REAL Jason both ways,
  so a row comes back as a plain Elixir map: `%{"kind" => "coffee", "amount" => 4}`.
  """

  @doc "Run any statement; returns the rows as a list of maps ([] for DDL/DML)."
  def query!(sql, params \\ []), do: :sql_host.exec(sql, Jason.encode!(params)) |> Jason.decode!()

  @doc "Run a statement for effect."
  def exec!(sql, params \\ []) do
    _ = :sql_host.exec(sql, Jason.encode!(params))
    :ok
  end

  @doc "First column of the first row (aggregates: `one!(\"SELECT SUM(x) AS v ...\")[\"v\"]`)."
  def one!(sql, params \\ []), do: query!(sql, params) |> hd()
end

defmodule SqlLedger do
  @moduledoc """
  A per-actor ledger stored in SQL, driven entirely from compiled Elixir: schema, inserts
  with bound params, aggregate queries — and Elixir-side cross-checks over the decoded rows
  (the SQL SUM must equal Enum.sum over SELECT *, computed in Elixir).
  """

  def setup do
    Sqlite.exec!("""
    CREATE TABLE IF NOT EXISTS entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL,
      amount INTEGER NOT NULL
    )
    """)
  end

  def add(kind, amount) when is_binary(kind) and is_integer(amount) do
    [%{"id" => id}] =
      Sqlite.query!("INSERT INTO entries (kind, amount) VALUES (?, ?) RETURNING id", [kind, amount])
    id
  end

  def balance, do: Sqlite.one!("SELECT COALESCE(SUM(amount), 0) AS v FROM entries")["v"]

  def by_kind do
    Sqlite.query!("SELECT kind, COUNT(*) AS n, SUM(amount) AS total FROM entries GROUP BY kind ORDER BY kind")
  end

  def top(n), do: Sqlite.query!("SELECT kind, amount FROM entries ORDER BY amount DESC, id ASC LIMIT ?", [n])

  # the report: SQL aggregates + an Elixir-side fold over the raw rows that must agree with SQL
  def report do
    rows = Sqlite.query!("SELECT kind, amount FROM entries ORDER BY id")
    elixir_sum = rows |> Enum.map(&Map.fetch!(&1, "amount")) |> Enum.sum()
    sql_sum = balance()
    check = if elixir_sum == sql_sum, do: "agree", else: "DISAGREE"

    lines =
      by_kind()
      |> Enum.map(fn %{"kind" => k, "n" => n, "total" => t} -> "  #{k}: #{n} entries, total #{t}" end)

    tops = top(3) |> Enum.map(fn %{"kind" => k, "amount" => a} -> "#{k}(#{a})" end) |> Enum.join(", ")

    Enum.join(
      ["ledger: #{length(rows)} entries",
       "balance: #{sql_sum} (sql) / #{elixir_sum} (elixir fold) -> #{check}"] ++
        lines ++ ["top: #{tops}"],
      "\n"
    )
  end

  # ── differential entry: seed-driven session against a fresh database ──
  @kinds ["coffee", "lunch", "salary", "rent", "book"]
  def run(seed) do
    setup()
    # deterministic LCG over the seed; inserts a mix of credits and debits
    Enum.reduce(1..12, abs(seed) + 7, fn i, acc ->
      x = rem(acc * 1103515245 + 12345, 2_147_483_648)
      kind = Enum.at(@kinds, rem(x, length(@kinds)))
      amount = rem(x, 500) - 100 + i
      add(kind, amount)
      x
    end)
    report()
  end

  # ── DO surface: one JSON op in, one JSON result out (decoded/encoded by real Jason) ──
  def ledger_op(json) do
    setup()
    case Jason.decode!(json) do
      %{"op" => "add", "kind" => kind, "amount" => amount} ->
        id = add(kind, amount)
        Jason.encode!(%{ok: true, id: id, balance: balance()})

      %{"op" => "balance"} ->
        Jason.encode!(%{balance: balance()})

      %{"op" => "report"} ->
        Jason.encode!(%{report: report()})

      other ->
        Jason.encode!(%{error: "unknown op", got: other})
    end
  end
end
