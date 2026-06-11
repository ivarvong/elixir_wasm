defmodule Beam2Wasm.Result do
  @moduledoc """
  The result of `Beam2Wasm.compile/2`: the WAT text plus the honesty report.

  `stubs` counts unsupported constructs compiled as named traps (`0` = the reachable
  program is provably supported). `externals` lists functions some kept code calls but
  no fed beam defines — each is an honest trap *if reached*; real libraries usually
  carry some on cold paths.
  """
  @enforce_keys [:wat, :stubs, :externals]
  defstruct [:wat, :stubs, :externals]

  @type t :: %__MODULE__{wat: String.t(), stubs: non_neg_integer(), externals: [String.t()]}
end
