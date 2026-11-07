# Native rich notes

The note body uses Native Shell 0.4.0's official `RichEditor`, with its Rust
ProseMirror state, StarterKit and TableKit. There is no WebView. The existing
`RichNoteEditor` application wrapper supplies the toolbar, owner-bound attachment
loading, preview/edit state, and encrypted-save integration.

## Data preservation

`rich-v1` Tiptap JSON remains the canonical storage format. Opening a document
never saves it. Legacy text/Markdown uses the existing Rust comrak importer;
the exact original source is retained by `patchFor` on the first actual edit.
Save echoes do not reset selection or history. Switching owners remounts the
native view and invalidates pending resource loads. `captureNotes()` pulls native
state before store flush/lock/hide; unmount also captures committed changes.

Before editing, compare the original JSON with the editor's serialization.
Only null/default attributes, empty content/mark arrays, and mark order are
normalized. Unknown nodes, marks, attributes and top-level fields fail closed:
the original document remains untouched and a read-only projection is shown.
Colors, underline, alignment, tables and blank paragraphs no longer need a
Markdown round trip. The existing comrak converter remains for legacy import.

`vaultImage` and `vaultAttachment` retain their IDs and metadata. Images are read
through the existing owner/lock-checked Rust API; decoded sources live only in
the editor session and are removed by `storedDocument` before persistence.
A native node-view plugin renders attachment names. Generic remote image nodes
are disabled; link auto-opening is disabled. Asynchronous imports check the
owner generation and editable state again before inserting content.

## Verification

Run `bash tool/nsh_mac.sh check` and `bash tool/nsh_mac.sh test` with a fresh,
seeded synthetic vault in `/tmp` (`examples/seed.rs`). Tests exercise typing,
switching documents, legacy source preservation, formatting, undo/redo, tables,
attachment references and rejection of unknown formats. These do not establish
physical Chinese IME, VoiceOver or real-window layout acceptance. No memory
reduction is claimed relative to the previous native multiline Input.
