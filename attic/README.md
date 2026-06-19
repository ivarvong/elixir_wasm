# attic — preserved history, not live code

Early spikes and superseded demos, kept because docs/ARCHITECTURE.md and docs/ROADMAP.md
cite these spikes and measurements as the evidence behind their conclusions. Nothing in the
live suites or deployed services references this directory.

| what | superseded by |
|---|---|
| `spikes/` | conclusions live in docs/ARCHITECTURE.md; 01-jspi-economics → `runtime/scheduler.mjs`, 03-durable-statem → `durable-genserver/` |
| `durable-object/` | the original account-DO demo → `durable-genserver/` (deployed) |
| `jason-demo/` | the first real-dependency build → `demo/markdown/` (deployed) |
| `measurements/` | early one-off measurement notes → `bench/perf/` (reproducible harnesses) |
