import { DurableObject } from "cloudflare:workers";
import portfolioModule from "./portfolio.wasm";

type PortfolioState = {
  cash: number;
  aapl: number;
  msft: number;
  events: number;
};

type PortfolioEvent = {
  type: string;
  amount?: number;
};

type PortfolioResult = PortfolioState & {
  value: string;
  applied: PortfolioEvent;
};

type WasmExports = {
  next_cash(cash: number, aapl: number, msft: number, event: number, amount: number): bigint;
  next_aapl(cash: number, aapl: number, msft: number, event: number, amount: number): bigint;
  next_msft(cash: number, aapl: number, msft: number, event: number, amount: number): bigint;
  value(cash: number, aapl: number, msft: number): bigint;
};

const EVENT_CODE: Record<string, number> = {
  deposit: 1,
  withdraw: 2,
  buy_aapl: 3,
  sell_aapl: 4,
  buy_msft: 5,
  sell_msft: 6,
  rebalance: 7
};

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

function eventCode(type: string): number {
  const code = EVENT_CODE[type];
  if (code === undefined) throw new Error(`unknown event type: ${type}`);
  return code;
}

function normalizeAmount(event: PortfolioEvent): number {
  if (event.type === "rebalance") return 0;
  const amount = event.amount;
  if (!Number.isInteger(amount) || amount < 0) throw new Error("amount must be a non-negative integer");
  return amount;
}

export class PortfolioObject extends DurableObject<Env> {
  private readonly exports: WasmExports;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.exports = new WebAssembly.Instance(portfolioModule, wasmImports()).exports as unknown as WasmExports;
  }

  async snapshot(): Promise<PortfolioState & { value: string }> {
    const state = await this.readState();
    return {
      ...state,
      value: this.exports.value(state.cash, state.aapl, state.msft).toString()
    };
  }

  async reset(cash = 0): Promise<PortfolioState & { value: string }> {
    if (!Number.isInteger(cash) || cash < 0) throw new Error("cash must be a non-negative integer");
    const state = { cash, aapl: 0, msft: 0, events: 0 } satisfies PortfolioState;
    await this.ctx.storage.put("state", state);
    return this.snapshot();
  }

  async apply(event: PortfolioEvent): Promise<PortfolioResult> {
    const state = await this.readState();
    const code = eventCode(event.type);
    const amount = normalizeAmount(event);

    const next = {
      cash: Number(this.exports.next_cash(state.cash, state.aapl, state.msft, code, amount)),
      aapl: Number(this.exports.next_aapl(state.cash, state.aapl, state.msft, code, amount)),
      msft: Number(this.exports.next_msft(state.cash, state.aapl, state.msft, code, amount)),
      events: state.events + 1
    } satisfies PortfolioState;

    await this.ctx.storage.put("state", next);

    return {
      ...next,
      value: this.exports.value(next.cash, next.aapl, next.msft).toString(),
      applied: event
    };
  }

  private async readState(): Promise<PortfolioState> {
    return (await this.ctx.storage.get<PortfolioState>("state")) ?? { cash: 0, aapl: 0, msft: 0, events: 0 };
  }
}

function accountStub(env: Env, accountId: string): DurableObjectStub<PortfolioObject> {
  return env.PORTFOLIOS.getByName(accountId);
}

async function parseEvent(request: Request): Promise<PortfolioEvent> {
  const event = (await request.json()) as Partial<PortfolioEvent>;
  if (typeof event.type !== "string") throw new Error("event.type is required");
  return { type: event.type, amount: event.amount };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/accounts\/([^/]+)(?:\/(events|reset))?$/);

    try {
      if (request.method === "GET" && url.pathname === "/") {
        return json({
          service: "portfolio-genserver-do",
          routes: {
            "GET /accounts/:id": "current durable portfolio state",
            "POST /accounts/:id/events": "apply deposit/withdraw/buy_aapl/sell_aapl/buy_msft/sell_msft/rebalance",
            "POST /accounts/:id/reset": "reset portfolio, optional { cash }"
          }
        });
      }

      if (!match) return json({ error: "Not found" }, { status: 404 });

      const accountId = decodeURIComponent(match[1]);
      const action = match[2];
      const stub = accountStub(env, accountId);

      if (request.method === "GET" && action === undefined) {
        return json(await stub.snapshot());
      }

      if (request.method === "POST" && action === "events") {
        const event = await parseEvent(request);
        const result = await stub.apply(event);
        console.log(JSON.stringify({ message: "portfolio event applied", accountId, type: event.type }));
        return json(result);
      }

      if (request.method === "POST" && action === "reset") {
        const body = (await request.json().catch(() => ({}))) as { cash?: number };
        return json(await stub.reset(body.cash ?? 0));
      }

      return json({ error: "Method not allowed" }, { status: 405 });
    } catch (error) {
      console.error(
        JSON.stringify({
          message: "portfolio request failed",
          error: error instanceof Error ? error.message : String(error),
          path: url.pathname
        })
      );
      return json({ error: error instanceof Error ? error.message : "Bad request" }, { status: 400 });
    }
  }
} satisfies ExportedHandler<Env>;
