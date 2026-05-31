import AppKit
import Foundation
import JavaScriptCore
import QuickLookUI
import WebKit

final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate, WKScriptMessageHandler {
    private static let taskToggleMessage = "taskToggle"
    private static let taskMarkerPattern = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]*)*(?:[-+*]|\d+[.)])[ \t]+\[([ xX])\]"#)
    private static let fencePattern = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(```+|~~~+)"#)

    private var webView: WKWebView!
    private var previewURL: URL?

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.taskToggleMessage)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 1100))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(WeakScriptMessageDelegate(self), name: Self.taskToggleMessage)
        config.userContentController = contentController
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let wv = WKWebView(frame: root.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        root.addSubview(wv)

        webView = wv
        view = root
        preferredContentSize = NSSize(width: 960, height: 1100)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            previewURL = url
            let html = try renderHTML(for: url)
            webView.loadHTMLString(html, baseURL: nil)
            // Tell Quick Look we're done synchronously — the WKWebView paints
            // asynchronously once the WebContent process is ready. Waiting on
            // didFinishNavigation hangs the preview spinner in the sandbox.
            handler(nil)
        } catch {
            handler(error)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let target = navigationAction.request.url {
            NSWorkspace.shared.open(target)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.taskToggleMessage,
              let body = message.body as? [String: Any],
              let index = (body["index"] as? NSNumber)?.intValue,
              let checked = (body["checked"] as? Bool) ?? (body["checked"] as? NSNumber)?.boolValue else {
            return
        }

        do {
            try updateTask(at: index, checked: checked)
            setTaskState(index: index, checked: checked, saved: true)
        } catch {
            NSLog("NotaPeek Quick Look task update failed: \(String(describing: error))")
            setTaskState(index: index, checked: !checked, saved: false)
        }
    }

    private func renderHTML(for url: URL) throws -> String {
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let raw = try Data(contentsOf: url)
        let markdown = String(data: raw, encoding: .utf8)
            ?? String(decoding: raw, as: UTF8.self)

        let bundle = Bundle(for: PreviewViewController.self)
        let markedJS = resource(bundle, "marked.min", "js")
        let hljsJS = resource(bundle, "highlight.min", "js")
        let body = renderMarkdown(markdown, markedJS: markedJS, hljsJS: hljsJS)
        let title = escapeHTML(url.deletingPathExtension().lastPathComponent)
        let css = resource(bundle, "preview", "css")

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title)</title>
          <style>\(css)</style>
        </head>
        <body>
          <main class="page">
            <article class="markdown-body">\(body)</article>
          </main>
          \(interactiveScript())
        </body>
        </html>
        """
    }

    private func renderMarkdown(_ markdown: String, markedJS: String, hljsJS: String) -> String {
        guard !markedJS.isEmpty, let context = JSContext() else {
            return "<pre>" + escapeHTML(markdown) + "</pre>"
        }

        var jsThrew = false
        context.exceptionHandler = { _, _ in jsThrew = true }
        context.evaluateScript(markedJS)
        if !hljsJS.isEmpty {
            context.evaluateScript(hljsJS)
        }
        context.setObject(markdown as NSString, forKeyedSubscript: "__MD__" as NSString)

        let result = context.evaluateScript("""
        (function () {
          if (typeof marked === 'undefined') return null;
          var parse = marked.parse || marked;
          var html = parse(String(__MD__), {
            gfm: true,
            breaks: false,
            mangle: false,
            headerIds: false
          });
          if (typeof hljs !== 'undefined') {
            var unescape = function(s) {
              return String(s)
                .replace(/&amp;/g, '&')
                .replace(/&lt;/g, '<')
                .replace(/&gt;/g, '>')
                .replace(/&quot;/g, '"')
                .replace(/&#39;/g, "'");
            };
            html = html.replace(/<pre><code class="language-([^"]+)">([\\s\\S]*?)<\\/code><\\/pre>/g, function(_, lang, code) {
              var raw = unescape(code);
              try {
                var hl;
                if (hljs.getLanguage(lang)) {
                  hl = hljs.highlight(raw, { language: lang, ignoreIllegals: true });
                } else {
                  hl = hljs.highlightAuto(raw);
                }
                return '<div class="code-block" data-lang="' + lang + '"><div class="code-lang">' + lang + '</div><pre><code class="hljs language-' + lang + '">' + hl.value + '</code></pre></div>';
              } catch (e) {
                return '<div class="code-block"><pre><code class="hljs">' + code + '</code></pre></div>';
              }
            });
            html = html.replace(/<pre><code>([\\s\\S]*?)<\\/code><\\/pre>/g, function(_, code) {
              try {
                var hl = hljs.highlightAuto(unescape(code));
                return '<div class="code-block"><pre><code class="hljs">' + hl.value + '</code></pre></div>';
              } catch (e) {
                return '<div class="code-block"><pre><code class="hljs">' + code + '</code></pre></div>';
              }
            });
          }
          var taskIndex = 0;
          html = html.replace(/<li>\\s*<input([^>]*type="checkbox"[^>]*)>\\s*/gi, function(_, attrs) {
            var checked = /checked/i.test(attrs);
            var index = taskIndex++;
            var label = checked ? 'Mark task incomplete' : 'Mark task complete';
            return '<li class="task-item ' + (checked ? 'task-done' : 'task-todo') + '"><button class="task-checkbox" type="button" data-task-index="' + index + '" data-checked="' + checked + '" aria-pressed="' + checked + '" aria-label="' + label + '"><span class="task-checkbox-mark" aria-hidden="true">' + (checked ? '✓' : '') + '</span></button>';
          });
          return html;
        })()
        """)

        if !jsThrew,
           let html = result?.toString(),
           html != "undefined",
           html != "null",
           !html.isEmpty {
            return html
        }

        return "<pre>" + escapeHTML(markdown) + "</pre>"
    }

    private func updateTask(at index: Int, checked: Bool) throws {
        guard let url = previewURL else { throw TaskUpdateError.missingURL }

        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let raw = try Data(contentsOf: url)
        let markdown = String(data: raw, encoding: .utf8)
            ?? String(decoding: raw, as: UTF8.self)

        guard let updated = markdownBySettingTask(markdown, at: index, checked: checked) else {
            throw TaskUpdateError.taskNotFound
        }

        let data = Data(updated.utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
    }

    private func markdownBySettingTask(_ markdown: String, at targetIndex: Int, checked: Bool) -> String? {
        var currentIndex = 0
        var output = ""
        var cursor = markdown.startIndex
        var activeFence: (character: Character, length: Int)?

        while cursor < markdown.endIndex {
            let lineEnd = markdown[cursor...].firstIndex(of: "\n") ?? markdown.endIndex
            var line = String(markdown[cursor..<lineEnd])
            let hasNewline = lineEnd < markdown.endIndex

            if let fence = fenceMarker(in: line) {
                if let active = activeFence {
                    if fence.character == active.character && fence.length >= active.length {
                        activeFence = nil
                    }
                } else {
                    activeFence = fence
                }
            } else if activeFence == nil, let markerRange = taskMarkerRange(in: line) {
                if currentIndex == targetIndex {
                    line.replaceSubrange(markerRange, with: checked ? "x" : " ")
                    output += line
                    if hasNewline {
                        output += "\n"
                        output += String(markdown[markdown.index(after: lineEnd)...])
                    }
                    return output
                }
                currentIndex += 1
            }

            output += line
            if hasNewline {
                output += "\n"
                cursor = markdown.index(after: lineEnd)
            } else {
                cursor = lineEnd
            }
        }

        return nil
    }

    private func taskMarkerRange(in line: String) -> Range<String.Index>? {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = Self.taskMarkerPattern.firstMatch(in: line, range: fullRange),
              match.numberOfRanges > 1 else {
            return nil
        }
        return Range(match.range(at: 1), in: line)
    }

    private func fenceMarker(in line: String) -> (character: Character, length: Int)? {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = Self.fencePattern.firstMatch(in: line, range: fullRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }

        let marker = String(line[range])
        guard let character = marker.first else { return nil }
        return (character, marker.count)
    }

    private func setTaskState(index: Int, checked: Bool, saved: Bool) {
        let script = "window.notapeekTaskSaved && window.notapeekTaskSaved(\(index), \(checked ? "true" : "false"), \(saved ? "true" : "false"));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func interactiveScript() -> String {
        """
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

          window.notapeekTaskSaved = (index, checked, saved) => {
            const button = document.querySelector('.task-checkbox[data-task-index="' + index + '"]');
            if (button) setTaskState(button, checked, !saved);
          };

          document.addEventListener('click', (event) => {
            const target = event.target && event.target.closest ? event.target : null;
            const button = target ? target.closest('.task-checkbox[data-task-index]') : null;
            if (!button) return;

            event.preventDefault();
            event.stopPropagation();

            const index = Number(button.dataset.taskIndex);
            const checked = button.dataset.checked !== 'true';
            setTaskState(button, checked, false);

            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.taskToggle) {
              window.webkit.messageHandlers.taskToggle.postMessage({ index, checked });
            }
          });
        })();
        </script>
        """
    }

    private func resource(_ bundle: Bundle, _ name: String, _ ext: String) -> String {
        guard let url = bundle.url(forResource: name, withExtension: ext),
              let string = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return string
    }

    private func escapeHTML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private enum TaskUpdateError: LocalizedError {
    case missingURL
    case taskNotFound

    var errorDescription: String? {
        switch self {
        case .missingURL:
            return "No preview file URL is available."
        case .taskNotFound:
            return "No matching task marker was found in the markdown source."
        }
    }
}

private final class WeakScriptMessageDelegate: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
