import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { GFM } from "@lezer/markdown";
import { syntaxTree } from "@codemirror/language";
import type { Extension, Range } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  ViewPlugin,
  type ViewUpdate,
  WidgetType,
} from "@codemirror/view";

/**
 * Live-preview markdown extension — Raycast/Obsidian-style.
 * Renders headings, bold, italic, code, quotes, lists, links inline.
 * Raw syntax reveals itself only on the line the cursor sits on.
 */

class BulletWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const s = document.createElement("span");
    s.className = "cm-md-bullet";
    s.textContent = "•";
    return s;
  }
}

class HrWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const s = document.createElement("span");
    s.className = "cm-md-hr";
    return s;
  }
}

class TaskWidget extends WidgetType {
  constructor(readonly checked: boolean) {
    super();
  }
  eq(o: TaskWidget) {
    return o.checked === this.checked;
  }
  toDOM() {
    const s = document.createElement("span");
    s.className = "cm-md-task" + (this.checked ? " checked" : "");
    s.textContent = this.checked ? "✓" : "";
    return s;
  }
}

function buildDecorations(view: EditorView): DecorationSet {
  const { state } = view;
  const doc = state.doc;
  const ranges: Range<Decoration>[] = [];
  const sel = state.selection.ranges;

  // A line is "revealed" (raw syntax shown) when a selection touches it.
  const revealed = (from: number, to: number) => {
    const a = doc.lineAt(from).from;
    const b = doc.lineAt(to).to;
    return sel.some((r) => r.to >= a && r.from <= b);
  };

  const hide = (from: number, to: number) => {
    if (to > from) ranges.push(Decoration.replace({}).range(from, to));
  };
  const mark = (from: number, to: number, cls: string) => {
    if (to > from) ranges.push(Decoration.mark({ class: cls }).range(from, to));
  };
  const lineClass = (pos: number, cls: string) => {
    const lf = doc.lineAt(pos).from;
    ranges.push(Decoration.line({ class: cls }).range(lf));
  };
  const eachLine = (from: number, to: number, fn: (lf: number) => void) => {
    let pos = from;
    while (pos <= to) {
      const line = doc.lineAt(pos);
      fn(line.from);
      if (line.to >= to) break;
      pos = line.to + 1;
    }
  };
  const trailingSpace = (pos: number) =>
    doc.sliceString(pos, pos + 1) === " " ? 1 : 0;

  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from,
      to,
      enter: (node) => {
        const name = node.name;
        const show = revealed(node.from, node.to);

        const h = /^(?:ATX|Setext)Heading([1-6])$/.exec(name);
        if (h) {
          eachLine(node.from, node.to, (lf) =>
            lineClass(lf, `cm-md-h${h[1]}`),
          );
          return;
        }

        if (name === "HeaderMark") {
          if (!show) hide(node.from, node.to + trailingSpace(node.to));
          return;
        }

        if (name === "StrongEmphasis") {
          mark(node.from, node.to, "cm-md-strong");
          return;
        }
        if (name === "Emphasis") {
          mark(node.from, node.to, "cm-md-em");
          return;
        }
        if (name === "Strikethrough") {
          mark(node.from, node.to, "cm-md-strike");
          return;
        }
        if (name === "InlineCode") {
          mark(node.from, node.to, "cm-md-code");
          return;
        }

        if (name === "EmphasisMark" || name === "StrikethroughMark") {
          if (!show) hide(node.from, node.to);
          return;
        }
        if (name === "CodeMark") {
          // keep the ``` fences of a fenced block visible
          if (node.node.parent?.name === "FencedCode") return;
          if (!show) hide(node.from, node.to);
          return;
        }

        if (name === "FencedCode") {
          eachLine(node.from, node.to, (lf) => lineClass(lf, "cm-md-fence"));
          return;
        }

        if (name === "Blockquote") {
          eachLine(node.from, node.to, (lf) => lineClass(lf, "cm-md-quote"));
          return;
        }
        if (name === "QuoteMark") {
          if (!show) hide(node.from, node.to + trailingSpace(node.to));
          return;
        }

        if (name === "ListMark") {
          const item = node.node.parent;
          const hasTask = !!item?.getChild("TaskMarker");
          const ordered = item?.parent?.name === "OrderedList";
          if (hasTask) {
            hide(node.from, node.to + trailingSpace(node.to));
          } else if (!ordered) {
            ranges.push(
              Decoration.replace({ widget: new BulletWidget() }).range(
                node.from,
                node.to,
              ),
            );
          }
          return;
        }
        if (name === "TaskMarker") {
          const checked = doc
            .sliceString(node.from, node.to)
            .toLowerCase()
            .includes("x");
          ranges.push(
            Decoration.replace({ widget: new TaskWidget(checked) }).range(
              node.from,
              node.to + trailingSpace(node.to),
            ),
          );
          return;
        }

        if (name === "HorizontalRule") {
          const line = doc.lineAt(node.from);
          if (show) {
            lineClass(node.from, "cm-md-hr-line");
          } else {
            ranges.push(
              Decoration.replace({ widget: new HrWidget() }).range(
                line.from,
                line.to,
              ),
            );
          }
          return;
        }

        if (name === "Link") {
          mark(node.from, node.to, "cm-md-link");
          return;
        }
        if (name === "Image") {
          mark(node.from, node.to, "cm-md-image");
          return;
        }
        if (name === "LinkMark" || name === "URL") {
          if (!show) hide(node.from, node.to);
          return;
        }
      },
    });
  }

  return Decoration.set(ranges, true);
}

const livePreview = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = buildDecorations(view);
    }
    update(u: ViewUpdate) {
      if (u.docChanged || u.viewportChanged || u.selectionSet) {
        this.decorations = buildDecorations(u.view);
      }
    }
  },
  { decorations: (v) => v.decorations },
);

const liveTheme = EditorView.theme({
  "& .cm-md-h1, & .cm-md-h2, & .cm-md-h3, & .cm-md-h4, & .cm-md-h5, & .cm-md-h6":
    {
      fontWeight: "700",
      color: "#f4f4f8",
      lineHeight: "1.3",
    },
  "& .cm-md-h1": { fontSize: "1.9em" },
  "& .cm-md-h2": { fontSize: "1.55em" },
  "& .cm-md-h3": { fontSize: "1.3em" },
  "& .cm-md-h4": { fontSize: "1.12em" },
  "& .cm-md-h5": { fontSize: "1em" },
  "& .cm-md-h6": {
    fontSize: "0.9em",
    textTransform: "uppercase",
    letterSpacing: "0.06em",
    color: "#9b9bad",
  },
  "& .cm-md-strong": { fontWeight: "700", color: "#f4f4f8" },
  "& .cm-md-em": { fontStyle: "italic" },
  "& .cm-md-strike": { textDecoration: "line-through", color: "#8a8a99" },
  "& .cm-md-code": {
    fontFamily:
      "ui-monospace, SFMono-Regular, 'JetBrains Mono', Menlo, monospace",
    fontSize: "0.88em",
    background: "rgba(255,122,182,0.12)",
    color: "#ffb3d4",
    padding: "0.1em 0.35em",
    borderRadius: "4px",
  },
  "& .cm-md-link": {
    color: "#ff7ab6",
    textDecoration: "underline",
    textUnderlineOffset: "2px",
    cursor: "pointer",
  },
  "& .cm-md-image": { color: "#b08cff" },
  "& .cm-line.cm-md-quote": {
    borderLeft: "3px solid #ff7ab6",
    paddingLeft: "14px",
    color: "#c2c2d0",
    fontStyle: "italic",
  },
  "& .cm-line.cm-md-fence": {
    fontFamily:
      "ui-monospace, SFMono-Regular, 'JetBrains Mono', Menlo, monospace",
    fontSize: "0.86em",
    background: "rgba(255,255,255,0.045)",
  },
  "& .cm-md-bullet": { color: "#ff7ab6", fontWeight: "700" },
  "& .cm-md-task": {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    width: "1em",
    height: "1em",
    marginRight: "0.45em",
    fontSize: "0.78em",
    lineHeight: "1",
    borderRadius: "4px",
    border: "1.5px solid #6b6b7c",
    color: "#0f0f14",
    verticalAlign: "middle",
  },
  "& .cm-md-task.checked": {
    background: "#ff7ab6",
    borderColor: "#ff7ab6",
    fontWeight: "700",
  },
  "& .cm-md-hr": {
    display: "inline-block",
    width: "100%",
    borderTop: "1px solid rgba(255,255,255,0.18)",
    verticalAlign: "middle",
  },
  "& .cm-line.cm-md-hr-line": { color: "#6b6b7c" },
});

export function markdownLive(): Extension {
  return [
    markdown({ base: markdownLanguage, extensions: GFM }),
    livePreview,
    liveTheme,
  ];
}
