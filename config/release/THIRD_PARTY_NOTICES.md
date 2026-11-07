# Third-party notices

PasswordVault source is MIT licensed. Third-party components retain their licenses.
Exact versions are recorded in the Cargo, npm and Gradle lockfiles in the source.

- Native Shell: Apache-2.0. Its Rust rich-text editor includes ports of ProseMirror
  and Tiptap components under their MIT licenses.
- The shared web rich-note editor uses Tiptap/ProseMirror and DOMPurify. Its complete
  bundled JavaScript license texts are generated as NoteEditor-LICENSES.txt and
  included in the clients that use this editor.
- Windows native file dialogs use rfd (MIT); Win32 bindings use windows-sys
  (MIT OR Apache-2.0). Exact versions are in the desktop Cargo lockfile.
- Preact and UniFFI retain their project licenses. Rust cryptographic, SQLCipher,
  SQLite, Kotlin/Android and Apple platform dependencies retain their own licenses.
- The BIP39 English word list originates from Bitcoin BIP-0039. Consult the
  source's dependency license files and upstream projects for full notices.

Retired Flutter runtimes are not included in these current application packages.
Historical release packages retain their original dependency notices.
