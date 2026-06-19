# Graph algorithms: build a random directed weighted graph (adjacency map node -> [{neighbor, weight}])
# from a seed, then run BFS, DFS, a Kahn-style topological order on the DAG-projection, connected
# components (over the undirected projection), a list-based Dijkstra shortest path, and reachability.
# Heavy Map + MapSet + Enum + recursion. Pure & deterministic.
defmodule Gap04 do
  @cmod 2_305_843_009_213_693_951
  @lcg 18_446_744_073_709_551_616

  def run(seed) do
    s0 = rem(abs(seed) + 1, @lcg)
    n = 14 + rem(seed, 10)
    {graph, s1} = gen_graph(n, s0)
    h = 14_695_981
    nodes = 0..(n - 1) |> Enum.to_list()
    h = mix(h, n)

    # edge count + total weight
    edges = Enum.flat_map(nodes, fn u -> Enum.map(Map.get(graph, u, []), fn {v, w} -> {u, v, w} end) end)
    h = h |> mix(length(edges)) |> mix(Enum.reduce(edges, 0, fn {_, _, w}, a -> a + w end))
    h = fold_map(h, Map.new(graph, fn {u, adj} -> {u, length(adj)} end))

    # out-degree / in-degree histograms
    out_deg = Map.new(nodes, fn u -> {u, length(Map.get(graph, u, []))} end)
    in_deg =
      Enum.reduce(edges, Map.new(nodes, &{&1, 0}), fn {_, v, _}, m ->
        Map.update(m, v, 1, &(&1 + 1))
      end)
    h = h |> fold_map(out_deg) |> fold_map(in_deg)

    # BFS from node 0: visitation order + level map
    {bfs_order, levels} = bfs(graph, 0)
    h = h |> fold_list(bfs_order) |> mix(length(bfs_order))
    h = fold_map(h, levels)

    # DFS from node 0: preorder
    dfs_order = dfs(graph, 0)
    h = h |> fold_list(dfs_order) |> mix(length(dfs_order))

    # reachability set from each node (size), folded canonically
    reach_sizes =
      Map.new(nodes, fn u ->
        {ord, _} = bfs(graph, u)
        {u, length(ord)}
      end)
    h = fold_map(h, reach_sizes)

    # full reachability matrix checksum (sorted reachable lists)
    h =
      Enum.reduce(nodes, h, fn u, acc ->
        {ord, _} = bfs(graph, u)
        fold_list(acc, Enum.sort(ord))
      end)

    # DAG projection: keep only edges u -> v where u < v (guarantees acyclic); topo-sort (Kahn)
    dag = build_dag(graph, nodes)
    topo = topo_sort(dag, nodes)
    h = h |> fold_list(topo) |> mix(length(topo))
    # verify topo order respects edges (self-check folded in)
    pos = topo |> Enum.with_index() |> Map.new()
    ok =
      Enum.all?(nodes, fn u ->
        Enum.all?(Map.get(dag, u, []), fn {v, _} -> Map.get(pos, u) < Map.get(pos, v) end)
      end)
    h = mix(h, if(ok, do: 1, else: 0))

    # connected components over the undirected projection
    comps = components(graph, nodes)
    h = h |> mix(length(comps))
    comp_sizes = comps |> Enum.map(&MapSet.size/1) |> Enum.sort()
    h = fold_list(h, comp_sizes)
    # canonical component representatives (min node of each)
    reps = comps |> Enum.map(fn c -> Enum.min(MapSet.to_list(c)) end) |> Enum.sort()
    h = fold_list(h, reps)

    # Dijkstra shortest paths from node 0 (list-based priority selection)
    dist = dijkstra(graph, 0, nodes)
    h = fold_map(h, finite_map(dist))
    reachable_dists = dist |> Map.values() |> Enum.reject(&(&1 == :inf))
    h = h |> mix(length(reachable_dists)) |> mix(Enum.sum(reachable_dists))
    {dmin, dmax} =
      case reachable_dists do
        [] -> {0, 0}
        l -> Enum.min_max(l)
      end
    h = h |> mix(dmin) |> mix(dmax)

    # Dijkstra from the highest-degree node too
    src = out_deg |> Enum.max_by(fn {_, d} -> d end) |> elem(0)
    dist2 = dijkstra(graph, src, nodes)
    h = h |> mix(src) |> fold_map(finite_map(dist2))

    # all-pairs sum of finite shortest distances
    aps =
      Enum.reduce(nodes, 0, fn u, acc ->
        d = dijkstra(graph, u, nodes)
        s = d |> Map.values() |> Enum.reject(&(&1 == :inf)) |> Enum.sum()
        acc + s
      end)
    h = mix(h, aps)

    # path existence matrix density
    pairs_reachable =
      Enum.reduce(nodes, 0, fn u, acc ->
        {ord, _} = bfs(graph, u)
        acc + length(ord) - 1
      end)
    h = mix(h, pairs_reachable)

    h = mix(h, s1)
    h
  end

  # ---- graph construction ----
  defp gen_graph(n, s) do
    nodes = 0..(n - 1) |> Enum.to_list()
    {adj, s_final} =
      Enum.reduce(nodes, {%{}, s}, fn u, {m, s1} ->
        {k, s2} = rng(s1, 4)
        {edges, s3} = gen_edges(k, n, u, s2, [])
        {Map.put(m, u, edges), s3}
      end)
    {adj, s_final}
  end

  defp gen_edges(0, _n, _u, s, acc), do: {dedup_edges(acc), s}
  defp gen_edges(k, n, u, s, acc) do
    {v, s1} = rng(s, n)
    {w, s2} = rng(s1, 20)
    if v == u do
      gen_edges(k - 1, n, u, s2, acc)
    else
      gen_edges(k - 1, n, u, s2, [{v, w + 1} | acc])
    end
  end

  defp dedup_edges(edges) do
    edges
    |> Enum.reduce(%{}, fn {v, w}, m -> Map.put_new(m, v, w) end)
    |> Enum.map(fn {v, w} -> {v, w} end)
    |> Enum.sort()
  end

  # ---- BFS ----
  defp bfs(graph, start) do
    do_bfs(graph, [start], MapSet.new([start]), [], %{start => 0})
  end

  defp do_bfs(graph, queue, visited, order, levels) do
    case queue do
      [] ->
        {Enum.reverse(order), levels}

      [u | rest] ->
        lvl = Map.get(levels, u)
        neighbors = Map.get(graph, u, []) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
        {queue2, visited2, levels2} =
          Enum.reduce(neighbors, {rest, visited, levels}, fn v, {q, vis, lv} ->
            if MapSet.member?(vis, v) do
              {q, vis, lv}
            else
              {q ++ [v], MapSet.put(vis, v), Map.put(lv, v, lvl + 1)}
            end
          end)
        do_bfs(graph, queue2, visited2, [u | order], levels2)
    end
  end

  # ---- DFS (preorder, recursive) ----
  defp dfs(graph, start) do
    {order, _} = do_dfs(graph, start, MapSet.new(), [])
    Enum.reverse(order)
  end

  defp do_dfs(graph, u, visited, order) do
    if MapSet.member?(visited, u) do
      {order, visited}
    else
      visited = MapSet.put(visited, u)
      order = [u | order]
      neighbors = Map.get(graph, u, []) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      Enum.reduce(neighbors, {order, visited}, fn v, {o, vis} ->
        do_dfs(graph, v, vis, o)
      end)
    end
  end

  # ---- DAG + topo sort (Kahn) ----
  defp build_dag(graph, nodes) do
    Map.new(nodes, fn u ->
      kept = Map.get(graph, u, []) |> Enum.filter(fn {v, _} -> v > u end)
      {u, kept}
    end)
  end

  defp topo_sort(dag, nodes) do
    in_deg =
      Enum.reduce(nodes, Map.new(nodes, &{&1, 0}), fn u, acc ->
        Enum.reduce(Map.get(dag, u, []), acc, fn {v, _}, m -> Map.update(m, v, 1, &(&1 + 1)) end)
      end)
    ready = nodes |> Enum.filter(fn u -> Map.get(in_deg, u) == 0 end) |> Enum.sort()
    do_topo(dag, ready, in_deg, [])
  end

  defp do_topo(_dag, [], _in_deg, acc), do: Enum.reverse(acc)
  defp do_topo(dag, [u | rest], in_deg, acc) do
    {in_deg2, newly} =
      Enum.reduce(Map.get(dag, u, []), {in_deg, []}, fn {v, _}, {m, nw} ->
        d = Map.get(m, v) - 1
        m = Map.put(m, v, d)
        if d == 0, do: {m, [v | nw]}, else: {m, nw}
      end)
    ready = (rest ++ Enum.sort(newly)) |> Enum.sort()
    do_topo(dag, ready, in_deg2, [u | acc])
  end

  # ---- connected components (undirected projection, union over BFS) ----
  defp components(graph, nodes) do
    undirected =
      Enum.reduce(nodes, Map.new(nodes, &{&1, MapSet.new()}), fn u, acc ->
        Enum.reduce(Map.get(graph, u, []), acc, fn {v, _}, m ->
          m
          |> Map.update(u, MapSet.new([v]), &MapSet.put(&1, v))
          |> Map.update(v, MapSet.new([u]), &MapSet.put(&1, u))
        end)
      end)
    {comps, _} =
      Enum.reduce(nodes, {[], MapSet.new()}, fn u, {acc, seen} ->
        if MapSet.member?(seen, u) do
          {acc, seen}
        else
          comp = flood(undirected, [u], MapSet.new())
          {[comp | acc], MapSet.union(seen, comp)}
        end
      end)
    comps
  end

  defp flood(_g, [], visited), do: visited
  defp flood(g, [u | rest], visited) do
    if MapSet.member?(visited, u) do
      flood(g, rest, visited)
    else
      visited = MapSet.put(visited, u)
      neigh = Map.get(g, u, MapSet.new()) |> MapSet.to_list()
      flood(g, neigh ++ rest, visited)
    end
  end

  # ---- Dijkstra (list-based priority selection) ----
  defp dijkstra(graph, src, nodes) do
    dist = Map.new(nodes, fn u -> {u, if(u == src, do: 0, else: :inf)} end)
    do_dijkstra(graph, MapSet.new(nodes), dist)
  end

  defp do_dijkstra(graph, unvisited, dist) do
    if MapSet.size(unvisited) == 0 do
      dist
    else
      # pick the unvisited node with the minimum finite distance
      candidates =
        unvisited
        |> MapSet.to_list()
        |> Enum.map(fn u -> {u, Map.get(dist, u)} end)
        |> Enum.reject(fn {_, d} -> d == :inf end)

      case candidates do
        [] ->
          dist

        _ ->
          {u, du} = Enum.min_by(candidates, fn {node, d} -> {d, node} end)
          unvisited2 = MapSet.delete(unvisited, u)
          dist2 =
            Enum.reduce(Map.get(graph, u, []), dist, fn {v, w}, acc ->
              if MapSet.member?(unvisited2, v) do
                nd = du + w
                cur = Map.get(acc, v)
                if cur == :inf or nd < cur, do: Map.put(acc, v, nd), else: acc
              else
                acc
              end
            end)
          do_dijkstra(graph, unvisited2, dist2)
      end
    end
  end

  # map :inf -> a fixed sentinel integer so we never fold the atom directly
  defp finite_map(m), do: Map.new(m, fn {k, v} -> {k, if(v == :inf, do: -1, else: v)} end)

  # ---- shared checksum kit (identical across the gap corpus) ----
  defp rng(s, m), do: {rem(div(s, 65_536), max(m, 1)), nxt(s)}
  defp nxt(s), do: rem(s * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407, @lcg)
  defp mix(h, x), do: rem(h * 1_000_003 + intify(x) + 1, @cmod)
  defp fold_list(h, l), do: Enum.reduce(l, h, fn e, a -> mix(a, e) end)
  defp fold_map(h, m), do: Enum.reduce(Enum.sort(Map.to_list(m)), h, fn {k, v}, a -> a |> mix(k) |> mix(v) end)
  defp intify(x) when is_integer(x), do: rem(abs(x), @cmod)
  defp intify(x) when is_float(x), do: trunc(x * 1_000_000)
  defp intify(x) when is_binary(x), do: bsum(x, 7)
  defp intify(true), do: 2
  defp intify(false), do: 3
  defp intify(nil), do: 5
  defp intify(x) when is_atom(x), do: bsum(Atom.to_string(x), 11)
  defp intify(x) when is_list(x), do: Enum.reduce(x, 13, fn e, a -> mix(a, intify(e)) end)
  defp intify(x) when is_tuple(x), do: intify(Tuple.to_list(x))
  defp bsum(<<>>, a), do: a
  defp bsum(<<c, r::binary>>, a), do: bsum(r, rem(a * 131 + c, @cmod))
end
