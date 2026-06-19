using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [ (name = "main", worker = .mainWorker) ],
  sockets = [ (name = "http", address = "127.0.0.1:8790", http = (), service = "main") ],
);

const mainWorker :Workerd.Worker = (
  modules = [ (name = "worker.js", esModule = embed "worker.js") ],
  compatibilityDate = "2026-06-01",
  durableObjectNamespaces = [
    (className = "NaiveOrder",  uniqueKey = "naive-order-key-v1"),
    (className = "StatemOrder", uniqueKey = "statem-order-key-v1"),
  ],
  durableObjectStorage = (inMemory = void),
  bindings = [
    (name = "NAIVE",  durableObjectNamespace = "NaiveOrder"),
    (name = "STATEM", durableObjectNamespace = "StatemOrder"),
  ],
);
