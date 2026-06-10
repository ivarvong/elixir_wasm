import { DurableObject } from "cloudflare:workers";
import todoModule from "./todo.wasm";
import navModule from "./nav.wasm";

const MAX_TEXT_BYTES = 2048;

type TodoRow = {
  id: number;
  text: string;
  completed: number;
  created_at: number;
  updated_at: number;
};

type TodoItem = {
  id: number;
  text: string;
  completed: boolean;
  created_at: number;
  updated_at: number;
};

type TodoStats = {
  next_id: number;
  open: number;
  done: number;
  version: number;
};

type WasmExports = {
  next_id(nextId: number, open: number, done: number, version: number, event: number, wasDone: number): bigint;
  next_open(nextId: number, open: number, done: number, version: number, event: number, wasDone: number): bigint;
  next_done(nextId: number, open: number, done: number, version: number, event: number, wasDone: number): bigint;
  next_version(nextId: number, open: number, done: number, version: number, event: number, wasDone: number): bigint;
  accepted(nextId: number, open: number, done: number, version: number, event: number, wasDone: number): bigint;
};

type NavWasmExports = {
  haversine_nm(lat1: number, lng1: number, lat2: number, lng2: number): number;
};

const EVENT = {
  add: 1,
  complete: 2,
  reopen: 3,
  delete: 4,
  clear_completed: 5
} as const;

let navExports: NavWasmExports | undefined;

function json(body: unknown, init?: ResponseInit): Response {
  return Response.json(body, {
    ...init,
    headers: {
      "Cache-Control": "no-store",
      ...init?.headers
    }
  });
}

function wasmImports(): WebAssembly.Imports {
  return {
    big: {
      from_i64: (value: bigint) => value,
      from_str: (value: unknown) => BigInt(String(value)),
      add: (left: bigint, right: bigint) => left + right,
      sub: (left: bigint, right: bigint) => left - right,
      mul: (left: bigint, right: bigint) => left * right,
      div: (left: bigint, right: bigint) => left / right,
      rem: (left: bigint, right: bigint) => left % right,
      fits_i31: (value: bigint) => (value >= -1073741824n && value < 1073741824n ? 1 : 0),
      to_i32: (value: bigint) => Number(value),
      cmp: (left: bigint, right: bigint) => (left < right ? -1 : left > right ? 1 : 0),
      bit_length: (value: bigint) => (value === 0n ? 0 : value.toString(2).length)
    }
  };
}

function navWasmImports(): WebAssembly.Imports {
  return {
    big: {
      from_i64: (value: bigint) => value,
      from_str: (value: unknown) => BigInt(String(value)),
      add: (left: bigint, right: bigint) => left + right,
      sub: (left: bigint, right: bigint) => left - right,
      mul: (left: bigint, right: bigint) => left * right,
      div: (left: bigint, right: bigint) => left / right,
      rem: (left: bigint, right: bigint) => left % right,
      fits_i31: (value: bigint) => (value >= -1073741824n && value < 1073741824n ? 1 : 0),
      to_i32: (value: bigint) => Number(value),
      cmp: (left: bigint, right: bigint) => (left < right ? -1 : left > right ? 1 : 0),
      bit_length: (value: bigint) => (value === 0n ? 0 : value.toString(2).length)
    },
    math: Object.fromEntries(
      [
        "sin",
        "cos",
        "tan",
        "asin",
        "acos",
        "atan",
        "sqrt",
        "exp",
        "log",
        "log2",
        "log10",
        "sinh",
        "cosh",
        "tanh",
        "ceil",
        "floor",
        "atan2",
        "pow"
      ].map((name) => [name, Math[name as keyof Math] as (...args: number[]) => number])
    )
  };
}

function getNavExports(): NavWasmExports {
  if (navExports) return navExports;
  navExports = new WebAssembly.Instance(navModule, navWasmImports()).exports as unknown as NavWasmExports;
  return navExports;
}

function readNumber(url: URL, name: string): number {
  const raw = url.searchParams.get(name);
  if (raw === null) throw new Error(`missing query parameter: ${name}`);
  const value = Number(raw);
  if (!Number.isFinite(value)) throw new Error(`invalid number for query parameter: ${name}`);
  return value;
}

function rowToItem(row: TodoRow): TodoItem {
  return {
    id: row.id,
    text: row.text,
    completed: row.completed === 1,
    created_at: row.created_at,
    updated_at: row.updated_at
  };
}

function eventAccepted(exports: WasmExports, stats: TodoStats, event: number, wasDone = 0): boolean {
  return Number(exports.accepted(stats.next_id, stats.open, stats.done, stats.version, event, wasDone)) === 1;
}

function nextStats(exports: WasmExports, stats: TodoStats, event: number, wasDone = 0): TodoStats {
  return {
    next_id: Number(exports.next_id(stats.next_id, stats.open, stats.done, stats.version, event, wasDone)),
    open: Number(exports.next_open(stats.next_id, stats.open, stats.done, stats.version, event, wasDone)),
    done: Number(exports.next_done(stats.next_id, stats.open, stats.done, stats.version, event, wasDone)),
    version: Number(exports.next_version(stats.next_id, stats.open, stats.done, stats.version, event, wasDone))
  };
}

export class TodoListObject extends DurableObject<Env> {
  private readonly exports: WasmExports;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.exports = new WebAssembly.Instance(todoModule, wasmImports()).exports as unknown as WasmExports;

    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS todos (
          id INTEGER PRIMARY KEY,
          text TEXT NOT NULL,
          completed INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      `);
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value INTEGER NOT NULL
        )
      `);
      this.ctx.storage.sql.exec("INSERT OR IGNORE INTO meta (key, value) VALUES ('next_id', 1), ('open', 0), ('done', 0), ('version', 0)");
    });
  }

  getTodos(): { stats: TodoStats; items: TodoItem[] } {
    const stats = this.readStats();
    const items = this.ctx.storage.sql.exec<TodoRow>("SELECT id, text, completed, created_at, updated_at FROM todos ORDER BY id ASC").toArray().map(rowToItem);
    return { stats, items };
  }

  addTodo(text: string): { stats: TodoStats; item: TodoItem } {
    const normalized = text.trim();
    const size = new TextEncoder().encode(normalized).length;
    if (normalized.length === 0) throw new Error("text is required");
    if (size > MAX_TEXT_BYTES) throw new Error("text is too large");

    const stats = this.readStats();
    if (!eventAccepted(this.exports, stats, EVENT.add)) throw new Error("add rejected by GenServer transition");

    const next = nextStats(this.exports, stats, EVENT.add);
    const now = Date.now();

    this.ctx.storage.sql.exec(
      "INSERT INTO todos (id, text, completed, created_at, updated_at) VALUES (?, ?, 0, ?, ?)",
      stats.next_id,
      normalized,
      now,
      now
    );
    this.writeStats(next);

    return { stats: next, item: { id: stats.next_id, text: normalized, completed: false, created_at: now, updated_at: now } };
  }

  completeTodo(id: number): { stats: TodoStats; item: TodoItem } {
    return this.setCompleted(id, true);
  }

  reopenTodo(id: number): { stats: TodoStats; item: TodoItem } {
    return this.setCompleted(id, false);
  }

  deleteTodo(id: number): { stats: TodoStats; deleted: TodoItem } {
    const row = this.findTodo(id);
    const stats = this.readStats();
    const wasDone = row.completed;

    if (!eventAccepted(this.exports, stats, EVENT.delete, wasDone)) throw new Error("delete rejected by GenServer transition");

    const next = nextStats(this.exports, stats, EVENT.delete, wasDone);
    this.ctx.storage.sql.exec("DELETE FROM todos WHERE id = ?", id);
    this.writeStats(next);

    return { stats: next, deleted: rowToItem(row) };
  }

  clearCompleted(): { stats: TodoStats; deleted: number } {
    const stats = this.readStats();
    if (!eventAccepted(this.exports, stats, EVENT.clear_completed)) throw new Error("clear_completed rejected by GenServer transition");

    const deleted = this.ctx.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM todos WHERE completed = 1").one().count;
    const next = nextStats(this.exports, stats, EVENT.clear_completed);
    this.ctx.storage.sql.exec("DELETE FROM todos WHERE completed = 1");
    this.writeStats(next);

    return { stats: next, deleted };
  }

  private setCompleted(id: number, completed: boolean): { stats: TodoStats; item: TodoItem } {
    const row = this.findTodo(id);
    const wasDone = row.completed;
    const event = completed ? EVENT.complete : EVENT.reopen;
    const stats = this.readStats();

    if (!eventAccepted(this.exports, stats, event, wasDone)) {
      return { stats, item: rowToItem(row) };
    }

    const next = nextStats(this.exports, stats, event, wasDone);
    const now = Date.now();
    this.ctx.storage.sql.exec("UPDATE todos SET completed = ?, updated_at = ? WHERE id = ?", completed ? 1 : 0, now, id);
    this.writeStats(next);

    return { stats: next, item: { ...rowToItem(row), completed, updated_at: now } };
  }

  private findTodo(id: number): TodoRow {
    if (!Number.isInteger(id) || id < 1) throw new Error("invalid todo id");
    const row = this.ctx.storage.sql.exec<TodoRow>("SELECT id, text, completed, created_at, updated_at FROM todos WHERE id = ?", id).one();
    if (!row) throw new Error("todo not found");
    return row;
  }

  private readStats(): TodoStats {
    const rows = this.ctx.storage.sql.exec<{ key: string; value: number }>("SELECT key, value FROM meta").toArray();
    const meta = Object.fromEntries(rows.map((row) => [row.key, row.value]));
    return {
      next_id: meta.next_id ?? 1,
      open: meta.open ?? 0,
      done: meta.done ?? 0,
      version: meta.version ?? 0
    };
  }

  private writeStats(stats: TodoStats): void {
    this.ctx.storage.sql.exec(
      "UPDATE meta SET value = CASE key WHEN 'next_id' THEN ? WHEN 'open' THEN ? WHEN 'done' THEN ? WHEN 'version' THEN ? ELSE value END",
      stats.next_id,
      stats.open,
      stats.done,
      stats.version
    );
  }
}

function listStub(env: Env, name: string): DurableObjectStub<TodoListObject> {
  return env.TODO_LISTS.getByName(name);
}

function parseId(pathname: string): number {
  const id = Number(pathname.split("/").at(-1));
  if (!Number.isInteger(id)) throw new Error("invalid todo id");
  return id;
}

async function readJson<T>(request: Request): Promise<T> {
  return (await request.json()) as T;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const list = url.searchParams.get("list") ?? "default";
    const stub = listStub(env, list);

    try {
      if (request.method === "GET" && url.pathname === "/") {
        return json({
          service: "todo-genserver-do",
          routes: {
            "GET /haversine?lat1=...&lng1=...&lat2=...&lng2=...": "nautical miles between two coordinates, computed by compiled Elixir WasmGC",
            "GET /todos?list=name": "list todos",
            "POST /todos?list=name": "create todo with { text }",
            "POST /todos/:id/complete?list=name": "complete todo",
            "POST /todos/:id/reopen?list=name": "reopen todo",
            "DELETE /todos/:id?list=name": "delete todo",
            "POST /todos/clear-completed?list=name": "delete completed todos"
          }
        });
      }

      if (request.method === "GET" && url.pathname === "/haversine") {
        const lat1 = readNumber(url, "lat1");
        const lng1 = readNumber(url, "lng1");
        const lat2 = readNumber(url, "lat2");
        const lng2 = readNumber(url, "lng2");
        const nauticalMiles = getNavExports().haversine_nm(lat1, lng1, lat2, lng2);

        return json({
          from: { lat: lat1, lng: lng1 },
          to: { lat: lat2, lng: lng2 },
          nautical_miles: Number(nauticalMiles.toFixed(6)),
          engine: "elixir-wasmgc"
        });
      }

      if (request.method === "GET" && url.pathname === "/todos") {
        return json(await stub.getTodos());
      }

      if (request.method === "POST" && url.pathname === "/todos") {
        const body = await readJson<{ text?: string }>(request);
        return json(await stub.addTodo(body.text ?? ""), { status: 201 });
      }

      if (request.method === "POST" && url.pathname === "/todos/clear-completed") {
        return json(await stub.clearCompleted());
      }

      if (request.method === "POST" && url.pathname.endsWith("/complete")) {
        return json(await stub.completeTodo(parseId(url.pathname.replace(/\/complete$/, ""))));
      }

      if (request.method === "POST" && url.pathname.endsWith("/reopen")) {
        return json(await stub.reopenTodo(parseId(url.pathname.replace(/\/reopen$/, ""))));
      }

      if (request.method === "DELETE" && url.pathname.startsWith("/todos/")) {
        return json(await stub.deleteTodo(parseId(url.pathname)));
      }

      return json({ error: "Not found" }, { status: 404 });
    } catch (error) {
      console.error(
        JSON.stringify({
          message: "todo request failed",
          list,
          path: url.pathname,
          error: error instanceof Error ? error.message : String(error)
        })
      );
      return json({ error: error instanceof Error ? error.message : "Bad request" }, { status: 400 });
    }
  }
} satisfies ExportedHandler<Env>;
