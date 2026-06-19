defmodule Beam2Wasm.PrivDriftTest do
  use ExUnit.Case, async: true

  # priv/ ships REAL copies (hex archives can't follow symlinks); runtime/ in the parent
  # repo is the source of truth. This test pins them together when developing in-repo.
  @runtime Path.expand("../runtime", __DIR__)

  for f <- ~w(imports.mjs scheduler.mjs deepstack.mjs) do
    test "priv/#{f} matches runtime/#{f}" do
      runtime = Path.join(@runtime, unquote(f))

      if File.exists?(runtime) do
        assert File.read!(Path.join([:code.priv_dir(:beam2wasm), unquote(f)])) == File.read!(runtime),
               "priv/#{unquote(f)} drifted from runtime/ — re-copy it"
      end
    end
  end
end
