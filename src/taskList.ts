const TASK_MARKER_LINE_RE = /^([ \t]*(?:>[ \t]*)*(?:[-+*]|\d+[.)])[ \t]+\[)([ xX])(\])/;
const FENCE_LINE_RE = /^[ \t]{0,3}(```+|~~~+)/;

export function setTaskCheckedInMarkdown(
  markdown: string,
  targetIndex: number,
  checked: boolean,
): string | null {
  let currentIndex = 0;
  let changed = false;
  let activeFence: { char: string; length: number } | null = null;

  const parts = markdown.split(/(\n)/);
  const next = parts
    .map((part, index) => {
      if (index % 2 === 1) return part;

      const fence = FENCE_LINE_RE.exec(part)?.[1];
      if (fence) {
        if (activeFence) {
          if (fence[0] === activeFence.char && fence.length >= activeFence.length) {
            activeFence = null;
          }
        } else {
          activeFence = { char: fence[0], length: fence.length };
        }
        return part;
      }

      if (activeFence) return part;

      return part.replace(TASK_MARKER_LINE_RE, (match, prefix: string, _mark: string, suffix: string) => {
        if (currentIndex++ !== targetIndex) return match;
        changed = true;
        return `${prefix}${checked ? "x" : " "}${suffix}`;
      });
    })
    .join("");

  return changed ? next : null;
}
