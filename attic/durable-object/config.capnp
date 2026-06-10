using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "main", worker = .mainWorker),
    (name = "do-disk", disk = (path = "state", writable = true)),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:8791", http = (), service = "main") ],
);

const mainWorker :Workerd.Worker = (
  modules = [
    (name = "worker.js", esModule = embed "worker.js"),
    (name = "account.wasm", wasm = embed "account_aot.wasm"),
  ],
  compatibilityDate = "2026-06-01",
  durableObjectNamespaces = [ (className = "Account", uniqueKey = "account-key-v1") ],
  durableObjectStorage = (localDisk = "do-disk"),
  bindings = [ (name = "ACCOUNT", durableObjectNamespace = "Account") ],
);
