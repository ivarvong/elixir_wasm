defmodule PathIntegrityTest do
  use ExUnit.Case, async: true

  # The .mjs runners (examples/, bench/, demo/) import runtime/ and each other by *relative
  # path*. A repo restructure can silently break these — they aren't all in verify.exs — and
  # the failure only shows when a human runs the quickstart. This test resolves every relative
  # `import … from "….mjs"` in every *tracked* .mjs and asserts the target exists, so a moved
  # file fails CI immediately. (It caught examples/runsort.mjs pointing one level too high
  # after the package was promoted to the repo root.)
  #
  # Scope: tracked files only (skips generated _work/); only `.mjs` targets; and only
  # *parent-traversing* (`../`) imports — those are the cross-directory structural refs a
  # restructure breaks. Same-dir (`./`) imports are skipped: a worker's `./imports.mjs` is
  # staged next to it at build time (`mix wasm.build`), so it's legitimately absent from source.
  @root Path.expand("..", __DIR__)

  defp tracked_mjs do
    {out, 0} = System.cmd("git", ["ls-files", "*.mjs"], cd: @root)
    String.split(out, "\n", trim: true)
  end

  test "every relative .mjs import resolves to a file that exists" do
    bad =
      for rel <- tracked_mjs(),
          file = Path.join(@root, rel),
          [_, spec] <- Regex.scan(~r/\bfrom\s+["']((?:\.\.\/)+[^"']+\.mjs)["']/, File.read!(file)),
          target = Path.expand(spec, Path.dirname(file)),
          not File.exists?(target),
          do: "#{rel} → #{spec}"

    assert bad == [], "broken relative .mjs imports:\n  " <> Enum.join(bad, "\n  ")
  end
end
