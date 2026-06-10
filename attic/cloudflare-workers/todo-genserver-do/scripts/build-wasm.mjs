import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, "..");
const repo = resolve(project, "..", "..");
const build = resolve(project, ".build");
const compiler = resolve(repo, "compiler", "beam2wasm.exs");

const source = `
defmodule TodoServer do
  use GenServer

  def init(_), do: {:ok, %{next_id: 1, open: 0, done: 0, version: 0}}

  def handle_call(:add, _from, state), do: {:reply, :ok, %{state | next_id: state.next_id + 1, open: state.open + 1, version: state.version + 1}}

  def handle_call({:complete, false}, _from, state), do: {:reply, :ok, %{state | open: state.open - 1, done: state.done + 1, version: state.version + 1}}
  def handle_call({:complete, true}, _from, state), do: {:reply, :noop, state}

  def handle_call({:reopen, true}, _from, state), do: {:reply, :ok, %{state | open: state.open + 1, done: state.done - 1, version: state.version + 1}}
  def handle_call({:reopen, false}, _from, state), do: {:reply, :noop, state}

  def handle_call({:delete, true}, _from, state), do: {:reply, :ok, %{state | done: state.done - 1, version: state.version + 1}}
  def handle_call({:delete, false}, _from, state), do: {:reply, :ok, %{state | open: state.open - 1, version: state.version + 1}}

  def handle_call(:clear_completed, _from, state), do: {:reply, :ok, %{state | done: 0, version: state.version + 1}}
end

defmodule TodoAbi do
  def next_id(next_id, open, done, version, event, was_done), do: transition(next_id, open, done, version, event, was_done).next_id
  def next_open(next_id, open, done, version, event, was_done), do: transition(next_id, open, done, version, event, was_done).open
  def next_done(next_id, open, done, version, event, was_done), do: transition(next_id, open, done, version, event, was_done).done
  def next_version(next_id, open, done, version, event, was_done), do: transition(next_id, open, done, version, event, was_done).version

  def accepted(next_id, open, done, version, event, was_done) do
    state = %{next_id: next_id, open: open, done: done, version: version}
    {:reply, reply, _next} = TodoServer.handle_call(event(event, was_done), nil, state)
    if reply == :ok, do: 1, else: 0
  end

  defp transition(next_id, open, done, version, event, was_done) do
    state = %{next_id: next_id, open: open, done: done, version: version}
    {:reply, _reply, next} = TodoServer.handle_call(event(event, was_done), nil, state)
    next
  end

  defp event(1, _), do: :add
  defp event(2, 0), do: {:complete, false}
  defp event(2, _), do: {:complete, true}
  defp event(3, 0), do: {:reopen, false}
  defp event(3, _), do: {:reopen, true}
  defp event(4, 0), do: {:delete, false}
  defp event(4, _), do: {:delete, true}
  defp event(5, _), do: :clear_completed
end
`;

const navSource = `
defmodule NavAbi do
  @earth_radius_nm 3440.065

  def haversine_nm(lat1, lng1, lat2, lng2) do
    dlat = rad(lat2 - lat1)
    dlng = rad(lng2 - lng1)
    rlat1 = rad(lat1)
    rlat2 = rad(lat2)

    a = :math.sin(dlat / 2.0) * :math.sin(dlat / 2.0) +
      :math.cos(rlat1) * :math.cos(rlat2) * :math.sin(dlng / 2.0) * :math.sin(dlng / 2.0)

    c = 2.0 * :math.atan2(:math.sqrt(a), :math.sqrt(1.0 - a))
    @earth_radius_nm * c
  end

  defp rad(degrees), do: degrees * :math.pi() / 180.0
end
`;

mkdirSync(build, { recursive: true });
writeFileSync(resolve(build, "todo.ex"), source);
execFileSync("elixirc", ["-o", build, resolve(build, "todo.ex")], { stdio: "inherit" });

const env = {
  ...process.env,
  STUB: "1",
  EXPORTS: "next_id:int,int,int,int,int,int->int;next_open:int,int,int,int,int,int->int;next_done:int,int,int,int,int,int->int;next_version:int,int,int,int,int,int->int;accepted:int,int,int,int,int,int->int"
};
const wat = execFileSync("elixir", [compiler, resolve(build, "Elixir.TodoAbi.beam"), resolve(build, "Elixir.TodoServer.beam")], { env });
writeFileSync(resolve(build, "todo.wat"), wat);
execFileSync("wasm-as", [resolve(build, "todo.wat"), "-o", resolve(build, "todo.wasm"), "-all"], { stdio: "inherit" });

const dest = resolve(project, "src", "todo.wasm");
copyFileSync(resolve(build, "todo.wasm"), dest);
console.log(`Wrote ${dest}`);

writeFileSync(resolve(build, "nav.ex"), navSource);
execFileSync("elixirc", ["-o", build, resolve(build, "nav.ex")], { stdio: "inherit" });
const navEnv = { ...process.env, STUB: "1", EXPORTS: "haversine_nm:float,float,float,float->float" };
const navWat = execFileSync("elixir", [compiler, resolve(build, "Elixir.NavAbi.beam")], { env: navEnv });
writeFileSync(resolve(build, "nav.wat"), navWat);
execFileSync("wasm-as", [resolve(build, "nav.wat"), "-o", resolve(build, "nav.wasm"), "-all"], { stdio: "inherit" });

const navDest = resolve(project, "src", "nav.wasm");
copyFileSync(resolve(build, "nav.wasm"), navDest);
console.log(`Wrote ${navDest}`);
