// A GenServer (compiled Elixir) running inside a Cloudflare Durable Object, with its state
// DURABLE across restart. Bank.handle_call/3 is real compiled Elixir (multi-clause + guards);
// the DO drives one GenServer step per request and persists the new state to DO storage.
// This is "Durable Objects with OTP discipline" made literal — the product thesis, closed.
import bankModule from "./bank.wasm";

const e = new WebAssembly.Instance(bankModule, {}).exports;       // no runtime compilation
const ATOMS = ["true", "false", "Elixir.BankAbi", "handle", "withdraw", "deposit", "balance",
               "Elixir.Bank", "handle_call", "reply", "ok", "insufficient", "init"];
const OP = { balance: 0, deposit: 1, withdraw: 2 };

// decode the GenServer's {:reply, reply, new_state} tuple back into JS
function step(state, ev, amt) {
  const r = e.handle(state, ev, amt);
  const reply = e.tup_get(r, 1), ns = e.tup_get(r, 2);
  const replyV = e.is_atom(reply) ? ":" + ATOMS[e.atom_idx(reply)] : e.get_int(reply);
  return { reply: replyV, newState: e.get_int(ns) };
}

export class BankDO {
  constructor(state) { this.state = state; }
  async fetch(req) {
    const url = new URL(req.url);
    const op = url.searchParams.get("op") || "balance";
    const amt = parseInt(url.searchParams.get("amount") || "0", 10);
    let bal = await this.state.storage.get("balance");
    if (bal === undefined) bal = 100;                              // init balance
    const { reply, newState } = step(bal, OP[op] ?? 0, amt);
    await this.state.storage.put("balance", newState);            // durable per-actor state
    const hist = (await this.state.storage.get("history")) || [];
    hist.push(`${op} ${amt} -> ${reply}`);
    await this.state.storage.put("history", hist);
    return Response.json({ op, amount: amt, reply, balance: newState, events: hist.length });
  }
}

export default {
  async fetch(req, env) {
    const id = new URL(req.url).searchParams.get("acct") || "default";
    return env.BANK.get(env.BANK.idFromName(id)).fetch(req);
  },
};
