using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [ (name = "main", worker = .mainWorker) ],
  sockets = [ (name = "http", address = "127.0.0.1:8795", http = (), service = "main") ],
);

const mainWorker :Workerd.Worker = (
  modules = [
    (name = "worker.js", esModule = embed "worker.js"),
    (name = "strix.wasm", wasm = embed "strix.wasm"),
  ],
  compatibilityDate = "2026-06-01",
);
