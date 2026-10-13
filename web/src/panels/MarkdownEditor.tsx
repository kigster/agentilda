// The Markdown editor every answer box and the idea dialog share: CodeMirror 6 with Markdown and fenced-code languages,
// in Gruvbox, with an Edit | Preview switch just above it, flush with its right edge.
import { useEffect, useId, useMemo, useRef, useState, type CSSProperties } from "react";
import CodeMirror, { EditorView, keymap } from "@uiw/react-codemirror";
import { Prec } from "@codemirror/state";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { languages } from "@codemirror/language-data";
import { createTheme } from "@uiw/codemirror-themes";
import { tags as t } from "@lezer/highlight";
import { renderMarkdown } from "./markdown";
import { useIsDark } from "./useIsDark";

// The palette comes from CSS variables (panels.css), so one theme follows data-theme and prefers-color-scheme alike.
const gruvbox = (dark: boolean) =>
  createTheme({
    theme: dark ? "dark" : "light",
    settings: {
      background: "var(--editor-bg)",
      foreground: "var(--gb-fg)",
      caret: "var(--ink)",
      selection: "color-mix(in srgb, var(--focus) 30%, transparent)",
      selectionMatch: "color-mix(in srgb, var(--focus) 18%, transparent)",
      lineHighlight: "transparent",
      fontFamily: "var(--mono)",
    },
    styles: [
      { tag: [t.keyword, t.list], color: "var(--gb-red)" },
      { tag: [t.string, t.regexp, t.link, t.url], color: "var(--gb-green)" },
      { tag: [t.heading], color: "var(--gb-yellow)", fontWeight: "700" },
      { tag: [t.number, t.bool, t.atom], color: "var(--gb-purple)" },
      { tag: [t.comment, t.quote, t.meta, t.processingInstruction], color: "var(--gb-gray)", fontStyle: "italic" },
      { tag: [t.typeName, t.className], color: "var(--gb-yellow)" },
      { tag: [t.variableName, t.propertyName, t.attributeName], color: "var(--gb-blue)" },
      { tag: [t.monospace, t.function(t.variableName)], color: "var(--gb-orange)" },
      { tag: [t.strong], fontWeight: "700" },
      { tag: [t.emphasis], fontStyle: "italic" },
      { tag: [t.labelName], color: "var(--gb-aqua)" },
    ],
  });

export interface MarkdownEditorProps {
  value: string;
  onChange: (value: string) => void;
  /** ⌘ Enter (Ctrl Enter off a Mac). */
  onSubmit?: () => void;
  /** The accessible name of the text box. */
  label: string;
  placeholder?: string;
  /** CSS height of the editor and its preview; the mockup's widget uses 180px. */
  height?: string;
  /** Lets the person drag its bottom edge. */
  resizable?: boolean;
  /** Shows the Edit | Preview switch. */
  preview?: boolean;
  /** The preview pane's accessible name. */
  previewLabel?: string;
  invalid?: boolean;
  autoFocus?: boolean;
}

export function MarkdownEditor({
  value, onChange, onSubmit, label, placeholder, height, resizable = false, preview = true,
  previewLabel = "Preview of your answer", invalid = false, autoFocus = false,
}: MarkdownEditorProps) {
  const dark = useIsDark();
  const [previewing, setPreviewing] = useState(false);
  const previewId = useId();
  const theme = useMemo(() => gruvbox(dark), [dark]);
  // The keymap reads the latest callback through a ref, so a new callback each render does not rebuild the editor.
  const submit = useRef(onSubmit);
  useEffect(() => { submit.current = onSubmit; }, [onSubmit]);
  const extensions = useMemo(
    () => [
      markdown({ base: markdownLanguage, codeLanguages: languages }),
      EditorView.lineWrapping,
      EditorView.contentAttributes.of({ "aria-label": label, "aria-multiline": "true", ...(invalid ? { "aria-invalid": "true" } : {}) }),
      Prec.highest(keymap.of([{ key: "Mod-Enter", run: () => { submit.current?.(); return true; } }])),
    ],
    [label, invalid],
  );
  const style = height ? ({ "--md-height": height } as CSSProperties) : undefined;
  return (
    <div className="md-pane" style={style}>
      {preview && (
        <div className="md-modes" role="group" aria-label="Answer view">
          <button type="button" className="btn md-mode" aria-pressed={!previewing} onClick={() => setPreviewing(false)}>Edit</button>
          <button type="button" className="btn md-mode" aria-pressed={previewing} onClick={() => setPreviewing(true)}>Preview</button>
        </div>
      )}
      {previewing ? (
        value.trim() ? (
          <div id={previewId} className="md-preview" tabIndex={0} aria-label={previewLabel} dangerouslySetInnerHTML={{ __html: renderMarkdown(value) }} />
        ) : (
          <div id={previewId} className="md-preview" tabIndex={0} aria-label={previewLabel}><p className="md-empty">Nothing to preview yet.</p></div>
        )
      ) : (
        <div className={`md${resizable ? " is-resizable" : ""}${invalid ? " is-invalid" : ""}`}>
          <CodeMirror
            value={value}
            onChange={onChange}
            theme={theme}
            extensions={extensions}
            placeholder={placeholder}
            autoFocus={autoFocus}
            height="100%"
            basicSetup={{ lineNumbers: false, foldGutter: false, highlightActiveLine: false, highlightActiveLineGutter: false }}
          />
        </div>
      )}
    </div>
  );
}
