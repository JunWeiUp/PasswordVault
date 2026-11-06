# Shared web rich-note editor

This Tiptap bundle is shared by the legacy SwiftUI Mac client, iOS, Android and
browser clients. The current NSH Mac client uses Native Shell's native RichEditor
and does not load this bundle.

From the repository root:

```sh
npm --prefix apps/shared/note-editor ci --ignore-scripts
npm --prefix apps/shared/note-editor run build
```

`dist/NoteEditor.html` and `dist/NoteEditor-LICENSES.txt` are generated and ignored.
The native platform projects package these resources; the browser build also
bundles `editor.js` with its own CSP and bridge. Keep the locked dependencies,
CSP, attachment protocol and rich-v1 serialization compatible across clients.
