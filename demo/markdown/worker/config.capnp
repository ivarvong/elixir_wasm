using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [ (name = "main", worker = .mainWorker) ],
  sockets = [ (name = "http", address = "127.0.0.1:8796", http = (), service = "main") ],
);

const mainWorker :Workerd.Worker = (
  modules = [
    (name = "worker.mjs", esModule = embed "worker.mjs"),
    (name = "imports.mjs", esModule = embed "imports.mjs"),
    (name = "blog.wasm", wasm = embed "blog.wasm"),
  ],
  compatibilityDate = "2026-06-01",
);
