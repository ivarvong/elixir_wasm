import type { RunResult } from "../lib/pyex";

export function Output({ result, running }: { result: RunResult | null; running: boolean }) {
  return (
    <pre className="flex-1 min-h-0 m-0 p-4 overflow-auto whitespace-pre-wrap break-words font-mono text-[13px] leading-relaxed">
      {running && !result && <span className="text-faint">running…</span>}
      {!result && !running && <span className="text-faint">Run to see output.</span>}
      {result && (result.ok
        ? (result.stdout
            ? <span className="text-fg">{result.stdout}</span>
            : <span className="text-faint">(no output)</span>)
        : <span className="text-red">{result.error}</span>)}
    </pre>
  );
}
