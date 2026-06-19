defmodule Beam2WasmTest do
  use ExUnit.Case, async: false

  # Build state is process-local by design: each compile runs in its own Task,
  # mirroring how `mix wasm.build` and the CLI shim invoke the library.
  defp compile_wat(beams, opts) do
    Task.async(fn -> Beam2Wasm.run(beams, opts) end) |> Task.await(:infinity)
  end

  defp tmp_beam(source) do
    [{mod, bin} | _] = Code.compile_string(source)
    path = Path.join(System.tmp_dir!(), "#{mod}_#{System.unique_integer([:positive])}.beam")
    File.write!(path, bin)
    on_exit_delete(path)
    {mod, path}
  end

  defp on_exit_delete(path), do: ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)

  test "compiles a module to a WAT string with the requested exports" do
    {_mod, beam} = tmp_beam("defmodule B2WSmoke do def dbl(x), do: x + x end")
    wat = compile_wat([beam], exports: "dbl:int->int", stub: true)
    assert wat =~ "(module"
    assert wat =~ ~s[(export "dbl")]
    assert wat =~ "$Elixir_46_B2WSmoke.dbl_1"
  end

  test "bignum: false emits the wrapping i32 fast path (no big imports)" do
    {_mod, beam} = tmp_beam("defmodule B2WWrap do def inc(x), do: x + 1 end")
    wat = compile_wat([beam], exports: "inc:int->int", stub: true, bignum: false)
    refute wat =~ ~s[(import "big"]
  end

  test "an unsupported construct without stub: true fails the build; with it, a counted trap" do
    src = "defmodule B2WStubby do def f(x), do: :erlang.phash2(x) end"
    {_mod, beam} = tmp_beam(src)
    wat = compile_wat([beam], exports: "f:int->int", stub: true)
    assert wat =~ ";; stub: external"
  end
end
