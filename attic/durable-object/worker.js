// A Durable Object whose transition logic IS compiled Elixir (WasmGC).
// account_aot.wasm = Account.step/2 (+ guards, map pattern-match, %{s | ...} updates)
// compiled from Elixir via :beam_disasm -> beam2wasm.exs. The DO holds primitive
// state in durable storage and drives transitions through the module's integer ABI.
import accountModule from "account.wasm";

const EV = { deposit: 0, withdraw: 1, freeze: 2, unfreeze: 3 };
const json = (o, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });

export class Account {
  constructor(state) {
    this.state = state;
    // Precompiled at startup; instantiation is allowed (no runtime compilation).
    this.e = new WebAssembly.Instance(accountModule, {}).exports;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const event = url.searchParams.get("event");
    const amount = parseInt(url.searchParams.get("amount") || "0", 10);

    // Durable state — survives across requests, and (localDisk) across restarts.
    let balance = (await this.state.storage.get("balance")) ?? 0;
    let status = (await this.state.storage.get("status")) ?? 0; // 0=open 1=frozen
    const history = (await this.state.storage.get("history")) ?? [];

    let applied = null;
    if (event === "new") {
      balance = amount; status = 0; applied = `new ${amount}`;
    } else if (event != null) {
      const ec = EV[event];
      if (ec === undefined) return json({ error: `unknown event '${event}'` }, 400);
      // The transition runs in compiled Elixir (cross-module call into Account.step):
      const nb = this.e.transition_balance(balance, status, ec, amount);
      const ns = this.e.transition_status(balance, status, ec, amount);
      applied = ec < 2 ? `${event} ${amount}` : event;
      balance = nb; status = ns;
    }

    if (applied) {
      history.push(applied);
      await this.state.storage.put({ balance, status, history }); // single transactional commit
    }

    return json({
      account: url.searchParams.get("id") || "default",
      applied,
      balance,
      status: status === 0 ? "open" : "frozen",
      events_applied: history.length,
      history,
    });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/bench") {
      const n = parseInt(url.searchParams.get("n") || "2000", 10);
      const p0 = performance.now();
      for (let i = 0; i < n; i++) new WebAssembly.Instance(accountModule, {});
      const perf_ms = performance.now() - p0;
      const d0 = Date.now();
      for (let i = 0; i < n; i++) new WebAssembly.Instance(accountModule, {});
      const date_ms = Date.now() - d0;
      return json({ n, perf_total_ms: perf_ms, perf_per_instantiate_us: (perf_ms / n) * 1000,
                    date_total_ms: date_ms, timers_usable: perf_ms > 0 });
    }
    const id = url.searchParams.get("id") || "default";
    return env.ACCOUNT.get(env.ACCOUNT.idFromName(id)).fetch(request);
  },
};
