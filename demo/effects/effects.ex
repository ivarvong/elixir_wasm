defmodule Effects do
  # The effects-ABI demo: File and console IO handed to the HOST. Reads a fixture, transforms it,
  # WRITES a file, PUTS a summary, handles a missing-file error — all through real File/IO on top of
  # the host fs/io imports. The harness runs it on the VM (real fs, captured stdout) and on Wasm
  # (virtual in-memory fs, captured console) and compares result + written bytes + printed lines.
  def run(_seed) do
    {:ok, content} = File.read("data/input.txt")
    upper = String.upcase(content)
    :ok = File.write("data/output.txt", upper <> "\n[processed]")
    IO.puts("processed " <> :erlang.integer_to_binary(byte_size(content)) <> " bytes")
    missing = case File.read("data/missing.txt") do
      {:error, :enoent} -> 1
      _ -> 0
    end
    bsum(upper, 7) + missing
  end
  defp bsum(<<>>, a), do: a
  defp bsum(<<c, r::binary>>, a), do: bsum(r, rem(a * 131 + c, 1_000_000_007))
end
