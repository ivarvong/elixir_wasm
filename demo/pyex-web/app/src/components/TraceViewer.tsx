import { useMemo, useState } from "react";
import type { RunResult, Span } from "../lib/pyex";

const bytes = (n?: number) => n == null ? "—" : n < 1024 ? `${n} B` : `${(n / 1024).toFixed(1)} KB`;

// A span is either RUNTIME-emitted (scope "pyex": the sandbox instrumenting its own file/db I/O) or
// APP-emitted (scope = a tracer name: the guest Python called `tracer.start_as_current_span(...)`).
// The app spans are the show — vivid violet — so you can SEE that the trace came from the program.
const isApp = (s: Span) => s.scope !== "pyex" && s.scope !== "";

// Runtime spans and app spans carry ids from two independent counters, so a
// bare `s.id` collides across the families — qualify by family for React keys,
// selection, and parent lookups.
const skey = (s: Span) => `${isApp(s) ? "a" : "r"}${s.id}`;
function hue(s: Span): string {
  if (isApp(s)) return "#a78bfa";        // guest code — the star
  if (s.name.startsWith("db")) return "#5ce08a";
  if (s.name.startsWith("file")) return "#5b9dff";
  return "#79c4ff";
}

function Chip({ k, v }: { k: string; v: string | number }) {
  return (
    <span className="text-faint whitespace-nowrap shrink-0">{k}&nbsp;<b className="text-fg font-semibold">{v}</b></span>
  );
}

export function TraceViewer({ result, wallMs }: { result: RunResult | null; wallMs: number | null }) {
  const [sel, setSel] = useState<string | null>(null);

  const spans: Span[] = result && result.ok ? result.spans : [];
  const fp = result && result.ok ? result.footprint : {};

  const { maxSeq, depthOf } = useMemo(() => {
    const byId = new Map(spans.map((s) => [skey(s), s]));
    const depthOf = (s: Span) => { let d = 0; const fam = isApp(s) ? "a" : "r"; let p = s.parent_id; while (p != null) { d++; p = byId.get(`${fam}${p}`)?.parent_id ?? null; } return d; };
    const maxSeq = Math.max(1, ...spans.map((s) => s.end_seq ?? s.start_seq + 1));
    return { maxSeq, depthOf };
  }, [spans]);

  const selected = spans.find((s) => skey(s) === sel) || null;

  return (
    <div className="flex flex-col h-full min-h-0">
      {/* resource footprint — the turn's OTel attributes */}
      <div className="flex items-center gap-4 px-4 h-[42px] border-b border-line text-[11.5px] font-mono overflow-x-auto shrink-0">
        <span className="flex items-center gap-2 text-fg font-semibold shrink-0">
          <span className="w-[7px] h-[7px] rounded-full bg-accent shadow-[0_0_0_3px_rgba(124,116,255,.18)]" />
          pyex.run
        </span>
        <Chip k="steps" v={fp[":steps"] ?? "—"} />
        <Chip k="mem" v={bytes(fp[":memory_bytes"])} />
        <Chip k="stdout" v={bytes(fp[":output_bytes"])} />
        <Chip k="file_ops" v={fp[":file_ops"] ?? "—"} />
        <Chip k="events" v={fp[":event_count"] ?? "—"} />
        <span className="ml-auto shrink-0 flex items-center gap-3">
          <span className="flex items-center gap-1.5 text-faint"><span className="w-[6px] h-[6px] rounded-full" style={{ background: "#a78bfa" }} />your&nbsp;code</span>
          <span className="flex items-center gap-1.5 text-faint"><span className="w-[6px] h-[6px] rounded-full" style={{ background: "#5b9dff" }} />runtime</span>
          <Chip k="wall" v={wallMs == null ? "—" : `${wallMs.toFixed(1)} ms`} />
        </span>
      </div>

      {/* span waterfall */}
      <div className="flex-1 min-h-0 overflow-auto">
        {spans.length === 0 ? (
          <div className="p-4 text-[12.5px] text-faint italic">
            No spans this run — this program emitted none.<br />
            Try <span className="text-muted">data pipeline</span>: its Python calls
            <span className="text-muted"> tracer.start_as_current_span(…)</span> and every span shows up here.
          </div>
        ) : (
          <div className="py-2">
            {spans.map((s) => {
              const end = s.end_seq ?? maxSeq;
              const left = (s.start_seq / maxSeq) * 100;
              const width = Math.max(2, ((end - s.start_seq) / maxSeq) * 100);
              const c = hue(s);
              const on = skey(s) === sel;
              return (
                <div
                  key={skey(s)}
                  onClick={() => setSel(on ? null : skey(s))}
                  className={`grid grid-cols-[minmax(120px,220px)_1fr] items-center gap-3 px-4 py-[3px] cursor-pointer ${on ? "bg-surface2" : "hover:bg-surface2/60"}`}
                >
                  <div className="flex items-center gap-2 font-mono text-[12px] truncate" style={{ paddingLeft: depthOf(s) * 14 }}>
                    <span className="w-[6px] h-[6px] rounded-full shrink-0" style={{ background: c }} />
                    <span className="text-fg truncate">{s.name}</span>
                    {isApp(s) && <span className="text-faint truncate hidden sm:inline">{s.scope}</span>}
                  </div>
                  <div className="relative h-[16px]">
                    <div className="absolute top-0 h-full rounded-[3px]" style={{ left: `${left}%`, width: `${width}%`, background: c, opacity: on ? 1 : 0.62 }} />
                    <span className="absolute right-0 -top-[1px] text-[10.5px] font-mono text-faint">{end - s.start_seq}u</span>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* span detail */}
      {selected && (
        <div className="border-t border-line p-3 text-[11.5px] font-mono max-h-[38%] overflow-auto shrink-0">
          <div className="flex items-center gap-2 mb-2">
            <span className="w-[6px] h-[6px] rounded-full" style={{ background: hue(selected) }} />
            <span className="text-fg font-semibold">{selected.name}</span>
            <span className="text-faint">· {isApp(selected) ? "your code" : "runtime"} · {selected.kind} · scope={selected.scope}</span>
            <span className="ml-auto text-faint">seq {selected.start_seq}→{selected.end_seq ?? "…"}</span>
          </div>
          {Object.entries(selected.attributes).length === 0
            ? <div className="text-faint italic">no attributes</div>
            : Object.entries(selected.attributes).map(([k, v]) => (
                <div key={k} className="flex gap-2 py-[1px]">
                  <span className="text-accent2 min-w-[130px]">{k}</span>
                  <span className="text-fg break-all">{String(v)}</span>
                </div>
              ))}
        </div>
      )}
    </div>
  );
}
