using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "main", worker = .mainWorker),
    (name = "do-disk", disk = (path = "state", writable = true)),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8801", http = (), service = "main") ],
);

const mainWorker :Workerd.Worker = (
  modules = [
    (name = "worker.mjs", esModule = embed "worker.mjs"),
    (name = "imports.mjs", esModule = embed "imports.mjs"),
    (name = "ledger.wasm", wasm = embed "ledger.wasm"),
  ],
  compatibilityDate = "2026-06-01",
  durableObjectNamespaces = [ (className = "LedgerDO", uniqueKey = "ledger-v1", enableSql = true) ],
  durableObjectStorage = (localDisk = "do-disk"),
  bindings = [ (name = "LEDGER", durableObjectNamespace = "LedgerDO") ],
);
