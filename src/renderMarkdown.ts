import { Marked } from "marked";
import hljs from "highlight.js";

function escapeHtml(s: string) {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export async function renderMarkdownToHtml(md: string): Promise<string> {
  const marked = new Marked({ gfm: true, breaks: false });

  marked.use({
    renderer: {
      code(token: { text: string; lang?: string }) {
        const lang = (token.lang ?? "").trim().toLowerCase();
        const valid = lang && hljs.getLanguage(lang);
        const highlighted = valid
          ? hljs.highlight(token.text, { language: lang, ignoreIllegals: true }).value
          : hljs.highlightAuto(token.text).value;
        const label = lang ? `<div class="code-lang">${escapeHtml(lang)}</div>` : "";
        return `<div class="code-block">${label}<pre><code class="hljs language-${escapeHtml(lang || "plaintext")}">${highlighted}</code></pre></div>`;
      },
      link(token: { href: string; title?: string | null; text: string }) {
        const href = token.href;
        const title = token.title ? ` title="${escapeHtml(token.title)}"` : "";
        const target = /^https?:/i.test(href) ? ' target="_blank" rel="noopener"' : "";
        return `<a href="${escapeHtml(href)}"${title}${target}>${token.text}</a>`;
      },
    },
  });

  let html = await marked.parse(md);
  let taskIndex = 0;
  html = html.replace(/<li>\s*<input([^>]*type="checkbox"[^>]*)>\s*/gi, (_m, attrs) => {
    const checked = /checked/i.test(attrs);
    const cls = checked ? "task-item task-done" : "task-item task-todo";
    const label = checked ? "Mark task incomplete" : "Mark task complete";
    return `<li class="${cls}"><button class="task-checkbox" type="button" data-task-index="${taskIndex++}" data-checked="${checked}" aria-pressed="${checked}" aria-label="${label}"><span class="task-checkbox-mark" aria-hidden="true">${checked ? "✓" : ""}</span></button>`;
  });
  return html;
}
