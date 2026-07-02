import type { Files } from "../lib/pyex";

const FileIcon = () => (
  <svg viewBox="0 0 16 16" className="w-3.5 h-3.5 opacity-60 shrink-0" fill="currentColor">
    <path d="M9 1H3.5A1.5 1.5 0 0 0 2 2.5v11A1.5 1.5 0 0 0 3.5 15h9a1.5 1.5 0 0 0 1.5-1.5V6L9 1Zm0 1.5L12.5 6H9V2.5Z" />
  </svg>
);
const PyIcon = () => (
  <svg viewBox="0 0 16 16" className="w-3.5 h-3.5 shrink-0" fill="currentColor">
    <path d="M4.7 3.3 1 8l3.7 4.7 1.1-.9L2.9 8l2.9-3.8-1.1-.9Zm6.6 0-1.1.9L13.1 8l-2.9 3.8 1.1.9L15 8l-3.7-4.7Z" />
  </svg>
);

export function FileExplorer({
  files, active, written, onSelect, onAdd, onDelete,
}: {
  files: Files;
  active: string;
  written: Set<string>;
  onSelect: (path: string) => void;
  onAdd: () => void;
  onDelete: (path: string) => void;
}) {
  const paths = Object.keys(files).sort();
  const row = (path: string, label: string, icon: React.ReactNode, deletable: boolean) => {
    const on = active === path;
    return (
      <div
        key={path}
        onClick={() => onSelect(path)}
        className={`group flex items-center gap-2 pl-3 pr-2 py-2.5 md:py-[5px] cursor-pointer text-[12.5px] font-mono rounded-md mx-1
          ${on ? "bg-accent/15 text-fg" : "text-muted hover:bg-surface2 hover:text-fg"}`}
      >
        {icon}
        <span className="truncate flex-1">{label}</span>
        {written.has(path) && <span className="text-grn text-[10px] shrink-0" title="written this run">●</span>}
        {deletable && (
          <button
            onClick={(e) => { e.stopPropagation(); onDelete(path); }}
            className="opacity-50 md:opacity-0 md:group-hover:opacity-100 text-faint hover:text-red text-base leading-none grid place-items-center w-10 h-10 -my-3 -mr-2 md:w-auto md:h-auto md:my-0 md:mr-0 md:px-1 md:text-sm shrink-0"
            title="delete"
          >×</button>
        )}
      </div>
    );
  };

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center justify-between px-3 h-[38px] border-b border-line text-[11px] font-mono text-muted tracking-wide shrink-0">
        <span>EXPLORER</span>
        <button onClick={onAdd} title="new file" className="text-faint hover:text-fg text-lg md:text-base leading-none grid place-items-center w-10 h-10 -mr-3 md:w-auto md:h-auto md:mr-0 md:px-1">+</button>
      </div>
      <div className="py-2 overflow-auto flex-1">
        <div className="px-2 pb-1 text-[10px] font-mono text-faint uppercase tracking-wider">program</div>
        {row("program.py", "program.py", <PyIcon />, false)}
        <div className="px-2 pt-3 pb-1 text-[10px] font-mono text-faint uppercase tracking-wider">workspace /</div>
        {paths.length === 0 && <div className="px-4 py-1 text-[11px] text-faint italic">no files — press +</div>}
        {paths.map((p) => row(p, p, <FileIcon />, true))}
      </div>
    </div>
  );
}
