# NotaPeek Architecture

NotaPeek has three main parts:

- Tauri shell: native macOS app lifecycle, file-open events, filesystem access, dialogs, opener integration, and window vibrancy.
- React frontend: Markdown file picker, drag/drop handling, CodeMirror editor, rendered preview iframe, task checkbox editing, and keyboard shortcuts.
- Swift Quick Look extension: Finder preview support for Markdown files outside the main app.

## Runtime Flow

1. User opens a Markdown file through Finder, drag/drop, or the app picker.
2. Tauri reads the file and sends the path/content to React.
3. React renders Markdown to HTML using `marked` and `highlight.js`.
4. Preview HTML is isolated inside an iframe with the shared preview stylesheet.
5. Task checkbox clicks update the Markdown source and save back to disk.
6. Finder Quick Look uses the embedded Swift extension and bundled preview assets for native `.md` previews.

## Important Files

- `src/App.tsx` - app state, open/save flow, drag/drop, preview iframe, shortcuts
- `src/renderMarkdown.ts` - Markdown to HTML rendering
- `src/taskList.ts` - task checkbox Markdown mutation
- `src/previewCss.ts` - shared preview CSS for app rendering
- `src/styles.css` - app chrome and layout
- `src-tauri/src/lib.rs` - Tauri setup, macOS vibrancy, file-open events
- `src-tauri/tauri.conf.json` - bundle metadata, permissions, file associations
- `src-tauri/quicklook/PreviewViewController.swift` - Quick Look preview renderer
- `scripts/package-macos.sh` - local app bundle build
- `scripts/release-dmg.sh` - signed and notarized DMG build

## Release Outputs

Generated build outputs are intentionally ignored by Git:

- `dist/`
- `release/`
- `src-tauri/target/`
- `src-tauri/quicklook/build/`

The source repo should be enough for another developer to install dependencies, run the app, and package a new macOS build.
