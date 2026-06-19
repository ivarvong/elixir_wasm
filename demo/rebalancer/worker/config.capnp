using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [ (name = "main", worker = .mainWorker) ],
  sockets = [ (name = "http", address = "127.0.0.1:8797", http = (), service = "main") ],
);

const mainWorker :Workerd.Worker = (
  modules = [
    (name = "worker.mjs", esModule = embed "worker.mjs"),
    (name = "host.mjs", esModule = embed "host.mjs"),
    (name = "imports.mjs", esModule = embed "imports.mjs"),
    (name = "rebalancer.wasm", wasm = embed "rebalancer.wasm"),
  ],
  compatibilityDate = "2026-06-01",
);
