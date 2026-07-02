import CodeMirror from "@uiw/react-codemirror";
import { python } from "@codemirror/lang-python";
import { githubDark } from "@uiw/codemirror-theme-github";
import { EditorView } from "@codemirror/view";

// On phones, wrapped lines break mid-identifier and destroy the code's visual
// structure — scroll horizontally instead, like GitHub mobile. Checked once:
// a viewport class change mid-session is not worth a listener.
const isPhone = typeof window !== "undefined" && window.matchMedia("(max-width: 767px)").matches;

export function Editor({ value, onChange, readOnly = false }:
  { value: string; onChange?: (v: string) => void; readOnly?: boolean }) {
  return (
    <CodeMirror
      value={value}
      onChange={onChange}
      theme={githubDark}
      readOnly={readOnly}
      height="100%"
      style={{ height: "100%", fontSize: "13px" }}
      extensions={isPhone ? [python()] : [python(), EditorView.lineWrapping]}
      basicSetup={{ lineNumbers: true, foldGutter: false, highlightActiveLine: !readOnly, autocompletion: false, searchKeymap: false }}
    />
  );
}
