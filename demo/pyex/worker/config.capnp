using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [ (name = "main", worker = .mainWorker) ],
  sockets = [ (name = "http", address = "127.0.0.1:8802", http = (), service = "main") ],
);

const mainWorker :Workerd.Worker = (
  modules = [
    (name = "worker.mjs", esModule = embed "worker.mjs"),
    (name = "imports.mjs", esModule = embed "imports.mjs"),
    (name = "pyex_wasm.wasm", wasm = embed "pyex_wasm.wasm"),
  ],
  compatibilityDate = "2026-06-01",
);
