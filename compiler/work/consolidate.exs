# Closed-world protocol consolidation: produce a consolidated Enumerable beam whose impl_for/1
# is a clean type dispatch (no Code.ensure_compiled / code server).
path = :code.lib_dir(:elixir, :ebin)
impls = Protocol.extract_impls(Enumerable, [path])
{:ok, binary} = Protocol.consolidate(Enumerable, impls)
File.write!("Elixir.Enumerable.beam", binary)
IO.puts("consolidated Enumerable with impls: #{inspect(impls)}")
