import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import CodeMirror from "@uiw/react-codemirror";
import { EditorView } from "@codemirror/view";
import { markdownLive } from "./markdownLive";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { readTextFile, writeTextFile } from "@tauri-apps/plugin-fs";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { basename } from "@tauri-apps/api/path";
import { renderMarkdownToHtml } from "./renderMarkdown";
import { PREVIEW_CSS } from "./previewCss";
import { setTaskCheckedInMarkdown } from "./taskList";

const MD_EXT = /\.(md|markdown|mdown|mkd)$/i;

const EDITOR_THEME = EditorView.theme({
  "&": {
    backgroundColor: "transparent",
    color: "var(--editor-fg)",
    height: "100%",
    fontSize: "14.5px",
  },
  ".cm-scroller": {
    fontFamily:
      'ui-monospace, "SF Mono", SFMono-Regular, "JetBrains Mono", Menlo, monospace',
    lineHeight: "1.7",
    padding: "28px 32px 80px",
  },
  ".cm-content": { caretColor: "var(--accent)" },
  ".cm-cursor": { borderLeftColor: "var(--accent)" },
  ".cm-gutters": { display: "none" },
  ".cm-activeLine": { backgroundColor: "transparent" },
  ".cm-selectionBackground, ::selection": {
    backgroundColor: "var(--accent-soft) !important",
  },
});

function composeDoc(body: string): string {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${PREVIEW_CSS}
    html, body { background: transparent !important; }
    .markdown-body { box-shadow: none !important; border: 0 !important; background: transparent !important; padding: 36px 40px 80px !important; max-width: 780px !important; }
    .page { padding: 0 !important; }
  </style></head><body><main class="page"><article class="markdown-body">${body}</article></main>
  <script>
  (() => {
    const setTaskState = (button, checked, failed) => {
      const item = button.closest('.task-item');
      const mark = button.querySelector('.task-checkbox-mark');
      if (item) {
        item.classList.toggle('task-done', checked);
        item.classList.toggle('task-todo', !checked);
        item.classList.toggle('task-save-failed', !!failed);
      }
      button.dataset.checked = checked ? 'true' : 'false';
      button.setAttribute('aria-pressed', checked ? 'true' : 'false');
      button.setAttribute('aria-label', checked ? 'Mark task incomplete' : 'Mark task complete');
      if (mark) mark.textContent = checked ? '✓' : '';
    };

    window.addEventListener('message', (event) => {
      if (event.data?.type !== 'task-saved') return;
      const button = document.querySelector('.task-checkbox[data-task-index="' + event.data.index + '"]');
      if (button) setTaskState(button, event.data.checked, !event.data.saved);
    });

    document.addEventListener('click', (event) => {
      const target = event.target && event.target.closest ? event.target : null;
      const button = target ? target.closest('.task-checkbox[data-task-index]') : null;
      if (button) {
        event.preventDefault();
        event.stopPropagation();
        const index = Number(button.dataset.taskIndex);
        const checked = button.dataset.checked !== 'true';
        setTaskState(button, checked, false);
        window.parent.postMessage({ type: 'task-toggle', index, checked }, '*');
        return;
      }

      const a = target ? target.closest('a[target=_blank]') : null;
      if (a) {
        event.preventDefault();
        window.parent.postMessage({ type: 'open-url', href: a.href }, '*');
      }
    });
  })();
  </script>
  </body></html>`;
}

export default function App() {
  const [filePath, setFilePath] = useState<string | null>(null);
  const [fileName, setFileName] = useState<string>("Untitled");
  const [text, setText] = useState<string>("");
  const [html, setHtml] = useState<string>("");
  const [mode, setMode] = useState<"preview" | "split">("preview");
  const [dirty, setDirty] = useState(false);
  const previewRef = useRef<HTMLIFrameElement | null>(null);

  const loadFile = useCallback(async (path: string) => {
    try {
      const contents = await readTextFile(path);
      const name = await basename(path);
      setFilePath(path);
      setFileName(name);
      setText(contents);
      setDirty(false);
      await getCurrentWindow().setTitle(name);
    } catch (err) {
      console.error("read failed", err);
    }
  }, []);

  const pickFile = useCallback(async () => {
    const selected = await openDialog({
      multiple: false,
      filters: [{ name: "Markdown", extensions: ["md", "markdown", "mdown", "mkd"] }],
    });
    if (typeof selected === "string") await loadFile(selected);
  }, [loadFile]);

  const saveFile = useCallback(async () => {
    if (!filePath) return;
    await writeTextFile(filePath, text);
    setDirty(false);
  }, [filePath, text]);

  // Receive file paths from backend (Finder Open With, cold + warm).
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    (async () => {
      const stop = await listen<string>("file-open", (event) => {
        if (event.payload) loadFile(event.payload);
      });
      unlisten = stop;
      const pending = await invoke<string | null>("consume_pending_file").catch(() => null);
      if (pending) loadFile(pending);
    })();
    return () => {
      if (unlisten) unlisten();
    };
  }, [loadFile]);

  // Drag & drop — use Tauri native file-drop event (HTML5 drop is intercepted).
  const [dropHover, setDropHover] = useState(false);
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    (async () => {
      const stop = await getCurrentWebview().onDragDropEvent((event) => {
        if (event.payload.type === "over") {
          setDropHover(true);
        } else if (event.payload.type === "drop") {
          setDropHover(false);
          const paths = event.payload.paths || [];
          const md = paths.find((p) => MD_EXT.test(p));
          if (md) loadFile(md);
        } else {
          setDropHover(false);
        }
      });
      unlisten = stop;
    })();
    return () => {
      if (unlisten) unlisten();
    };
  }, [loadFile]);

  // Re-render preview as text changes.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const body = await renderMarkdownToHtml(text);
      if (!cancelled) setHtml(composeDoc(body));
    })();
    return () => {
      cancelled = true;
    };
  }, [text]);

  // Keyboard shortcuts.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const cmd = e.metaKey || e.ctrlKey;
      if (cmd && e.key.toLowerCase() === "o") {
        e.preventDefault();
        pickFile();
      } else if (cmd && e.key.toLowerCase() === "s") {
        e.preventDefault();
        saveFile();
      } else if (cmd && e.key.toLowerCase() === "e") {
        e.preventDefault();
        setMode((m) => (m === "preview" ? "split" : "preview"));
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [pickFile, saveFile]);

  // Handle interactive preview messages.
  useEffect(() => {
    const onMessage = (e: MessageEvent) => {
      if (e.data?.type === "open-url" && typeof e.data.href === "string") {
        import("@tauri-apps/plugin-opener").then((m) => m.openUrl(e.data.href));
      } else if (
        e.data?.type === "task-toggle" &&
        typeof e.data.index === "number" &&
        typeof e.data.checked === "boolean"
      ) {
        const { index, checked } = e.data;
        setText((current) => {
          const next = setTaskCheckedInMarkdown(current, index, checked);
          if (next === null) return current;

          setDirty(true);
          if (filePath) {
            writeTextFile(filePath, next)
              .then(() => {
                setDirty(false);
                previewRef.current?.contentWindow?.postMessage(
                  { type: "task-saved", index, checked, saved: true },
                  "*",
                );
              })
              .catch((err) => {
                console.error("task save failed", err);
                previewRef.current?.contentWindow?.postMessage(
                  { type: "task-saved", index, checked: !checked, saved: false },
                  "*",
                );
              });
          }

          return next;
        });
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [filePath]);

  const editor = useMemo(
    () => (
      <CodeMirror
        value={text}
        height="100%"
        theme="none"
        extensions={[markdownLive(), EDITOR_THEME, EditorView.lineWrapping]}
        basicSetup={{ lineNumbers: false, foldGutter: false, highlightActiveLine: false }}
        onChange={(v) => {
          setText(v);
          setDirty(true);
        }}
      />
    ),
    [text],
  );

  const empty = !filePath && !text;

  return (
    <div className={`app mode-${mode}${dropHover ? " drop-hover" : ""}`} data-tauri-drag-region>
      <header className="toolbar" data-tauri-drag-region>
        <div className="title" data-tauri-drag-region>
          <span className="dot" />
          <span className="name">{fileName}</span>
          {dirty && <span className="dirty" title="Unsaved changes">●</span>}
        </div>
        <div className="actions">
          <button onClick={pickFile} title="Open (⌘O)">Open</button>
          <button
            onClick={() => setMode((m) => (m === "preview" ? "split" : "preview"))}
            title="Toggle edit (⌘E)"
            className={mode === "split" ? "active" : ""}
          >
            {mode === "split" ? "Preview" : "Edit"}
          </button>
          {filePath && (
            <button onClick={saveFile} title="Save (⌘S)" disabled={!dirty}>
              Save
            </button>
          )}
        </div>
      </header>

      {empty ? (
        <main className="empty">
          <div className="empty-card">
            <h1>NotaPeek</h1>
            <p className="tagline">Markdown previews, the way macOS should have done it.</p>
            <p>Drop a <code>.md</code> file here, or press <kbd>⌘O</kbd> to open one.</p>
            <p className="hint">Set this app as the default in Finder → Get Info → Open with → Change All.</p>
          </div>
        </main>
      ) : mode === "split" ? (
        <main className="split">
          <section className="pane editor-pane">{editor}</section>
          <section className="pane preview-pane">
            <iframe ref={previewRef} title="preview" srcDoc={html} />
          </section>
        </main>
      ) : (
        <main className="preview-only">
          <iframe ref={previewRef} title="preview" srcDoc={html} />
        </main>
      )}
    </div>
  );
}
