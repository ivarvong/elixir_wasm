// sqlsrv.mjs — the VM oracle's SQL backing: a line server over node:sqlite, so the BEAM run
// and the Wasm run hit the IDENTICAL engine. One JSON request per line {sql, params}; one
// response line "OK <rows-json>" | "ERR <message>". The DB is :memory: — one server per seed.
import { DatabaseSync } from "node:sqlite";
import readline from "node:readline";

const db = new DatabaseSync(":memory:");
const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on("line", (line) => {
  try {
    const { sql, params } = JSON.parse(line);
    const rows = db.prepare(sql).all(...JSON.parse(params));
    process.stdout.write("OK " + JSON.stringify(rows) + "\n");
  } catch (err) {
    process.stdout.write("ERR " + String(err.message).replace(/\n/g, " ") + "\n");
  }
});
