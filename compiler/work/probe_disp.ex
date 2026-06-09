defmodule ProbeDisp do
  def call_mod(mod, state), do: mod.handle(state)        # variable module, known fun/arity
  def call_apply(mod, fun, args), do: apply(mod, fun, args)
  def call_known(state), do: KnownMod.handle(state)      # static module call (baseline)
end
