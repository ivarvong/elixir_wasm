// Client-side handle to the pyex Web Worker: compile-once, run-many, with a watchdog.
export type Footprint = Record<string, number>;
export type Span = {
  id: number; parent_id: number | null; name: string; scope: string; kind: string;
  attributes: Record<string, unknown>; start_seq: number; end_seq: number | null;
};
export type Files = Record<string, string>;
export type RunResult =
  | { ok: true; stdout: string; footprint: Footprint; files: Files; spans: Span[]; ms: number }
  | { ok: false; error: string; ms: number };

type Listener = {
  onReady: (info: { sizeMB: number; ms: number }) => void;
  onBootError: (msg: string) => void;
  onResult: (id: number, r: RunResult) => void;
};

export class Pyex {
  private worker!: Worker;
  private ready = false;
  private runId = 0;
  private latest = 0;
  private watchdog: number | undefined;
  constructor(private l: Listener) { this.spawn(); }

  private spawn() {
    this.worker = new Worker(new URL("../pyex.worker.ts", import.meta.url), { type: "module" });
    this.worker.onmessage = (ev: MessageEvent<any>) => {
      const d = ev.data;
      if (d.type === "ready") { this.ready = true; this.l.onReady(d); }
      else if (d.type === "boot-error") this.l.onBootError(d.message);
      else if (d.type === "result") {
        clearTimeout(this.watchdog);
        if (d.id !== this.latest) return;
        const r: RunResult = d.ok
          ? { ok: true, stdout: d.stdout, footprint: d.footprint, files: d.files, spans: d.spans, ms: d.ms }
          : { ok: false, error: d.error, ms: d.ms };
        this.l.onResult(d.id, r);
      }
    };
  }

  get isReady() { return this.ready; }

  run(code: string, files: Files, maxSteps = 2_000_000): number {
    const id = ++this.runId; this.latest = id;
    this.worker.postMessage({ id, code, filesJson: JSON.stringify(files), maxSteps });
    clearTimeout(this.watchdog);
    this.watchdog = self.setTimeout(() => {
      this.worker.terminate(); this.ready = false;
      this.l.onResult(id, { ok: false, error: "run timed out — restarting the interpreter…", ms: 0 });
      this.spawn();
    }, 6000);
    return id;
  }
}
