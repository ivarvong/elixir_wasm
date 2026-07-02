import { useEffect, useMemo, useRef, useState } from "react";
import { Pyex, type RunResult, type Files } from "./lib/pyex";
import { EXAMPLES } from "./examples";
import { Editor } from "./components/Editor";
import { FileExplorer } from "./components/FileExplorer";
import { Output } from "./components/Output";
import { TraceViewer } from "./components/TraceViewer";

const GH = ({ repo }: { repo: string }) => (
  <a href={`https://github.com/ivarvong/${repo}`} target="_blank" rel="noopener"
     className="hidden sm:inline-flex items-center gap-2 h-8 px-2.5 rounded-lg text-[12px] font-mono text-muted hover:text-fg hover:bg-surface2 border border-transparent hover:border-line transition">
    <svg viewBox="0 0 16 16" className="w-4 h-4 fill-current"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.6 7.6 0 014-.01c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
    <span>ivarvong/<b className="text-fg font-semibold">{repo}</b></span>
  </a>
);

type Tab = "files" | "code" | "output" | "trace";

export function App() {
  const [code, setCode] = useState(EXAMPLES[0].code);
  const [files, setFiles] = useState<Files>(EXAMPLES[0].files ?? {});
  const [active, setActive] = useState("program.py");
  const [result, setResult] = useState<RunResult | null>(null);
  const [running, setRunning] = useState(false);
  const [wallMs, setWallMs] = useState<number | null>(null);
  const [written, setWritten] = useState<Set<string>>(new Set());
  const [status, setStatus] = useState("booting…");
  const [ready, setReady] = useState(false);
  const [exampleName, setExampleName] = useState(EXAMPLES[0].name);
  const [mobileTab, setMobileTab] = useState<Tab>("code");
  const [rev, setRev] = useState(1);

  const codeRef = useRef(code);
  const filesRef = useRef(files);
  const pyex = useRef<Pyex | null>(null);
  const debounce = useRef<number | undefined>(undefined);

  // boot the worker once
  useEffect(() => {
    pyex.current = new Pyex({
      onReady: ({ sizeMB, ms }) => { setReady(true); setStatus(`interpreter ${sizeMB.toFixed(1)} MB · ${ms.toFixed(0)}ms`); setRev((r) => r + 1); },
      onBootError: () => setStatus("needs a WasmGC browser (Chrome/Edge 119+, Firefox 120+)"),
      onResult: (_id, r) => {
        setRunning(false); setResult(r); setWallMs(r.ms);
        if (r.ok) {
          const before = filesRef.current;
          const w = new Set(Object.keys(r.files).filter((k) => r.files[k] !== before[k]));
          setWritten(w);
          filesRef.current = r.files; setFiles(r.files);   // evolve the workspace — no re-run (rev unchanged)
        }
        // on phones, jump to the result so the run is visible without hunting for a tab
        if (self.matchMedia?.("(max-width: 767px)").matches) setMobileTab("output");
        setStatus("ready");
      },
    });
  }, []);

  // live compile — runs on user intent only (rev bumps), never on result-driven file updates
  useEffect(() => {
    if (!ready) return;
    clearTimeout(debounce.current);
    debounce.current = self.setTimeout(runNow, 450);
    return () => clearTimeout(debounce.current);
  }, [rev, ready]);

  // ⌘↵ / Ctrl↵ runs from anywhere
  useEffect(() => {
    const h = (e: KeyboardEvent) => { if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); runNow(); } };
    window.addEventListener("keydown", h); return () => window.removeEventListener("keydown", h);
  }, [ready]);

  function runNow() {
    if (!pyex.current?.isReady) return;
    setRunning(true); setStatus("running…");
    pyex.current.run(codeRef.current, filesRef.current);
  }

  // user-intent mutations bump rev
  const editActive = (v: string) => {
    if (active === "program.py") { codeRef.current = v; setCode(v); }
    else { const f = { ...filesRef.current, [active]: v }; filesRef.current = f; setFiles(f); }
    setRev((r) => r + 1);
  };
  const loadExample = (name: string) => {
    const ex = EXAMPLES.find((e) => e.name === name)!;
    codeRef.current = ex.code; filesRef.current = ex.files ?? {};
    setCode(ex.code); setFiles(ex.files ?? {}); setActive("program.py");
    setExampleName(name); setWritten(new Set()); setRev((r) => r + 1);
  };
  const addFile = () => {
    const path = prompt("New file path", "/workspace/notes.txt");
    if (!path) return;
    const f = { ...filesRef.current, [path]: "" }; filesRef.current = f; setFiles(f);
    setActive(path); setMobileTab("code"); setRev((r) => r + 1);
  };
  const deleteFile = (path: string) => {
    const f = { ...filesRef.current }; delete f[path]; filesRef.current = f; setFiles(f);
    if (active === path) setActive("program.py");
    setRev((r) => r + 1);
  };

  const activeValue = active === "program.py" ? code : (files[active] ?? "");
  const dot = running ? "bg-accent animate-pulse shadow-[0_0_0_3px_rgba(124,116,255,.18)]"
    : result ? (result.ok ? "bg-grn" : "bg-red") : "bg-faint";

  const explorer = (
    <FileExplorer files={files} active={active} written={written}
      onSelect={(p) => { setActive(p); setMobileTab("code"); }} onAdd={addFile} onDelete={deleteFile} />
  );
  const editor = (
    <div className="flex flex-col h-full min-h-0">
      <div className="flex items-center justify-between px-3.5 h-[38px] border-b border-line text-[11px] font-mono text-muted shrink-0">
        <span className="text-fg">{active}</span>
        <span className="text-faint">{active === "program.py" ? `${code.split("\n").length} lines` : "vfs file"}</span>
      </div>
      <div className="flex-1 min-h-0"><Editor value={activeValue} onChange={editActive} /></div>
    </div>
  );
  const output = <Output result={result} running={running} />;
  const trace = <TraceViewer result={result} wallMs={wallMs} />;

  const Card = ({ children, className = "" }: { children: React.ReactNode; className?: string }) => (
    <section className={`bg-surface border border-line rounded-xl overflow-hidden flex flex-col min-h-0 ${className}`}>{children}</section>
  );

  return (
    <div className="flex flex-col h-full">
      {/* nav */}
      <nav className="flex items-center gap-3 px-4 h-[54px] border-b border-line shrink-0">
        <div className="w-[26px] h-[26px] rounded-[7px] grid place-items-center font-mono font-bold text-[13px] text-white shrink-0"
             style={{ background: "linear-gradient(145deg,#7c74ff,#5a4fd6)", boxShadow: "0 0 0 1px rgba(255,255,255,.08), 0 6px 18px -6px #7c74ff" }}>py</div>
        <span className="font-mono font-semibold text-[15px]">pyex</span>
        <span className="hidden md:inline text-muted text-[12.5px]">— a Python&nbsp;3 interpreter <span className="text-fg">written in Elixir</span>, compiled to <span className="text-accent2">WebAssembly&nbsp;GC</span></span>
        <div className="flex-1" />
        <GH repo="pyex" /><GH repo="elixir_wasm" />
      </nav>

      {/* toolbar */}
      <div className="flex items-center gap-2 px-4 py-2.5 border-b border-line shrink-0">
        <div className="flex gap-1.5 overflow-x-auto [scrollbar-width:none] [-ms-overflow-style:none] max-md:[mask-image:linear-gradient(to_right,black_calc(100%-28px),transparent)]">
          {EXAMPLES.map((e) => (
            <button key={e.name} onClick={() => loadExample(e.name)}
              className={`shrink-0 h-10 md:h-8 px-3 rounded-full font-mono text-[12px] border transition whitespace-nowrap
                ${e.name === exampleName ? "bg-accent/15 border-accent/40 text-[#cfc9ff]" : "bg-surface border-line text-muted hover:text-fg hover:border-line2"}`}>
              {e.name}
            </button>
          ))}
        </div>
        <div className="flex-1" />
        <span className="flex items-center gap-2 font-mono text-[11.5px] text-muted shrink-0">
          <span className={`w-[7px] h-[7px] rounded-full transition ${dot}`} />
          <span className="hidden sm:inline">{status}</span>
        </span>
        <button onClick={runNow} disabled={!ready}
          className="inline-flex items-center gap-2 h-10 md:h-9 px-4 rounded-lg text-[13px] font-semibold text-white border border-white/10 transition disabled:opacity-50 hover:brightness-110 shrink-0"
          style={{ background: "linear-gradient(180deg,#9a8bff,#7c74ff)", boxShadow: "0 6px 16px -8px #7c74ff" }}>
          Run <kbd className="hidden md:inline font-mono text-[10.5px] opacity-80 bg-black/20 px-1.5 py-0.5 rounded">⌘↵</kbd>
        </button>
      </div>

      {/* desktop: files | editor | (output over trace — both always visible) */}
      <main className="hidden md:grid flex-1 min-h-0 gap-3 p-3" style={{ gridTemplateColumns: "216px 1fr 1.15fr" }}>
        <Card>{explorer}</Card>
        <Card>{editor}</Card>
        <div className="grid grid-rows-[minmax(0,34fr)_minmax(0,66fr)] gap-3 min-h-0">
          <Card>
            <div className="flex items-center px-3.5 h-[34px] border-b border-line shrink-0 font-mono text-[11px] text-muted">stdout</div>
            <div className="flex-1 min-h-0 flex flex-col">{output}</div>
          </Card>
          <Card>
            <div className="flex items-center px-3.5 h-[34px] border-b border-line shrink-0 font-mono text-[11px] text-muted">
              trace <span className="text-faint">· OpenTelemetry spans</span>
            </div>
            <div className="flex-1 min-h-0 flex flex-col">{trace}</div>
          </Card>
        </div>
      </main>

      {/* mobile: one panel + bottom tab bar */}
      <main className="md:hidden flex-1 min-h-0 p-2.5">
        <Card className="h-full">
          {mobileTab === "files" ? explorer : mobileTab === "code" ? editor : mobileTab === "output" ? output : trace}
        </Card>
      </main>
      <nav className="md:hidden flex shrink-0 border-t border-line bg-surface" style={{ paddingBottom: "env(safe-area-inset-bottom)" }}>
        {(["files", "code", "output", "trace"] as const).map((t) => {
          const on = mobileTab === t;
          const badge =
            t === "files" ? Object.keys(files).length + 1 :
            t === "trace" ? (result?.ok ? result.spans.length : null) :
            null;
          return (
            <button key={t} onClick={() => setMobileTab(t)}
              className={`relative flex-1 py-3 font-mono text-[12px] capitalize transition ${on ? "text-accent2" : "text-muted active:text-fg"}`}>
              {on && <span className="absolute top-0 left-1/2 -translate-x-1/2 w-8 h-[2px] rounded-full bg-accent2" />}
              <span className="inline-flex items-center gap-1.5">
                {t}
                {t === "output" && (
                  <span className={`w-[6px] h-[6px] rounded-full ${running ? "bg-accent animate-pulse" : result ? (result.ok ? "bg-grn" : "bg-red") : "bg-faint"}`} />
                )}
                {badge != null && badge > 0 && <span className="text-faint text-[10.5px]">{badge}</span>}
              </span>
            </button>
          );
        })}
      </nav>
    </div>
  );
}
