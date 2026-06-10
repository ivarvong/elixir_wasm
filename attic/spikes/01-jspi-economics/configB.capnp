using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [ (name = "main", worker = .w) ],
  sockets = [ (name = "http", address = "127.0.0.1:8788", http = (), service = "main") ],
);
const w :Workerd.Worker = (
  modules = [ (name = "workerB.js", esModule = embed "workerB.js"), (name = "spikeB.wasm", wasm = embed "spikeB.wasm") ],
  compatibilityDate = "2026-06-01",
  compatibilityFlags = ["experimental"],
);
