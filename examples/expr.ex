defmodule Expr do
  # A tiny expression language: literals, variables, +,-,*, if, and let-binding.
  # AST = tuples tagged with atoms; environment = assoc list of {name, value}.
  def eval({:lit, n}, _env), do: n
  def eval({:var, name}, env), do: lookup(env, name)
  def eval({:add, a, b}, env), do: eval(a, env) + eval(b, env)
  def eval({:sub, a, b}, env), do: eval(a, env) - eval(b, env)
  def eval({:mul, a, b}, env), do: eval(a, env) * eval(b, env)
  def eval({:neg, a}, env), do: 0 - eval(a, env)
  def eval({:if, c, t, e}, env) do
    if eval(c, env) != 0, do: eval(t, env), else: eval(e, env)
  end
  def eval({:let, name, val, body}, env) do
    eval(body, [{name, eval(val, env)} | env])
  end

  def lookup([{k, v} | _], k), do: v
  def lookup([_ | rest], name), do: lookup(rest, name)

  # Self-contained demo: build and evaluate the AST for
  #   let a = x in (let b = 6 in a*b + (a - b))
  # The inner (constant) subtree compiles to a literal the compiler must materialize;
  # the outer let is built at runtime. demo(x) = x*6 + (x - 6).
  def demo(x) do
    ast =
      {:let, :a, {:lit, x},
        {:let, :b, {:lit, 6},
          {:add,
            {:mul, {:var, :a}, {:var, :b}},
            {:sub, {:var, :a}, {:var, :b}}}}}
    eval(ast, [])
  end
end
