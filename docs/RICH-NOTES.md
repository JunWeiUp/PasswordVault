# Encrypted rich notes (2.3.0 preview)

Mac personal notes now use locally bundled Tiptap 3.31.4 / ProseMirror. Notesnook informed the editing workflow; its GPL editor and product modules are not copied. Dependency notices are generated with the offline bundle. This is a local development preview, not a public release or a completed security audit.

## Editing

Keep the existing three-column workspace and one native page scrollbar. Notes open directly in Edit; Preview is explicitly read-only. The toolbar groups history, paragraph style, inline formatting, additional formatting, insert actions and find/replace. Selections offer inline formatting; tables and attachments expose contextual operations.

Supported operations include headings, bold/italic/underline/strike, colors/highlights, alignment, lists/tasks and nesting, quotes, links, code, dividers, table row/column operations, headers, merged cells, column resizing, images, file attachments, find/replace, and undo/redo. Images can be pasted/dropped/selected, resized to preset widths, captioned, replaced and removed. Attachments support Save as and removal; there is no automatic external-app preview. Image inline rendering supports PNG, JPEG, GIF and WebP; other files remain downloadable attachments. Limits are 25 MiB per file and 250 MiB retained attachments per note.

The editor owns selection and history. Autosave acknowledgements never replace its document. Initialization resets history once; it is not an undoable edit. Configuration sequence and document revisions reject stale changes before changing editability. Height changes precede native scrolling; scrolling does not reset first responder. Native and web focus are distinct and tested independently.

## Data and compatibility

- `noteFormat: rich-v1` identifies a versioned `noteDocument` JSON tree; `note` is its searchable text summary. Opening legacy text/Markdown preserves the original bytes. The first real edit keeps an encrypted `noteOriginal` copy. Unsupported HTML, remote images and footnote-definition lines are preserved as visible literal blocks.
- On first rich write or attachment import, retain the encrypted database and header in the vault's `before-rich-notes` subdirectory, then promote the encrypted document to format 3. Recover using both files in a separate vault directory and the password valid when the copy was made. Never replace an open vault's files. This snapshot is encrypted but retains its original password envelope after later password changes.
- Old binaries reject format 3. Updated mobile/Web clients show summaries and disallow rich-note edits/incomplete exports. There is no automatic cross-device rich-note sync. Existing shared notes retain text editing; rich personal notes cannot be moved into legacy shared vaults.
- Rich notes do not have a writable Markdown-source view. Markdown export is explicitly lossy (colors, alignment, merged cells), writes plaintext, and exports attachment references only; save the files separately. Full-vault CSV/plain JSON export is blocked once the document has upgraded. Use a complete encrypted archive instead.

## Encryption and backup

`note_attachments` stores blobs and metadata in SQLCipher. Blob bytes additionally use AES-GCM with the existing HKDF primitive under the `note-attachments-v1` domain. Authentication binds vault ID and attachment metadata (ID, owning note, name, MIME and length). UniFFI transfers bytes; regular note saves carry only JSON and IDs. A blob is durable before its reference is inserted. Failed imports can be retried/cancelled; failed note writes retain the encrypted recovery path.

The nonpersistent WKWebView has no network access or vault keys. Session-bound `pvnote://` resources serve decrypted images only while unlocked; lock invalidates outstanding resource tasks and destroys the editor. Paste sanitization removes active/remote embedded content. Explicit Save as writes a plaintext file to the chosen destination. Swift/JavaScript/WebKit memory cannot be certified as fully zeroized.

Undo can reference removed attachments until the editor closes. Unreferenced attachments are collected after the next unlock **after** encrypted draft restoration succeeds, not while an editor can undo. Trash retains attachments; permanent note removal deletes its blobs in the same database transaction.

`PasswordVaultArchive` version 3 contains a password-wrapped fresh root, authenticated encrypted manifest and individually authenticated encrypted files. All files are authenticated before mutation; the document and imported blobs commit together. Missing/tampered files, conflicting immutable IDs and wrong passwords fail without replacing existing records. Local and WebDAV backups use the same archive. Legacy V2 backups remain readable; unchanged V2 vaults keep their old backup writer. Archives currently use bounded in-memory JSON (1 GiB input, 512 MiB aggregate file ciphertext on export); very large vault archives need a future streaming format.

## Verification

Run the core, Mac and browser checks from `NATIVE-MIGRATION.md`. `RichNoteTests` covers a real SwiftUI workspace with native key events (100 Return/input cycles each for paragraphs, lists and long notes), caret visibility, native focus transfer, formatting/table/find operations, image paste/resource loading, encrypted backup and lock/reopen. The retained editor lifecycle tests cover composition simulation, stale updates, final snapshots and failure preservation. `rich_notes.rs` covers encrypted canaries, archive authentication/rollback, attachment ownership, size limits and legacy-client rejection.

A disposable fixture can be created with `cargo run -p vault-core --release --example rich_notes_demo -- <NEW_DIRECTORY>` and opened with `--vault-directory`. Its password is in the example. Do not use a real vault for acceptance.

Physical Chinese candidate-window confirmation, VoiceOver, macOS 13/Intel hardware and large-archive peak memory remain separate acceptance gates. Automated composition and Unicode paste do not certify physical input methods.

### Local verification results

- Rust: 36 tests plus clippy/format checks passed, including authenticated metadata tampering, unavailable storage, attachment ownership and complete backup recovery.
- Mac: 73 Swift tests passed; the final search change also passed its targeted real-WebKit regression across differently formatted text. The full-window test sends 300 native Return/input cycles, checks caret visibility and verifies native focus transfer. Title Return now requests body focus, including delayed editor initialization; a later click/Tab cancels the pending request.
- Browser: 40 tests, TypeScript, WASM and build checks passed. Android Kotlin compilation passed (the unit-test task has no local test sources); iOS Simulator build passed. These are not phone installation or physical-device acceptance.
- Native UI checks with disposable data confirmed persistent Chinese paste/newlines, native image selection, encrypted rendering, image width/caption changes and saved content after reopening. Physical Pinyin candidate confirmation was not established by the automation.
- The universal Mac preview is ad-hoc signed, matching the installed app's observed signing class, and passes strict code-sign verification. The local signing configuration has no development team and no matching Mac profile is available; Touch ID/development-certificate signing is not certified by this preview. The installed application and real vault were not replaced.

### Wheel and trackpad regression

Build 22 forwards vertical DOM wheel deltas to the enclosing native clip view because WebKit otherwise consumes them inside the content-height editor. Pixel, line and page modes are normalized; scroll bounds are clamped without changing focus or selection. Scrollable menus and horizontal table gestures stay in WebKit. User scrolling cancels queued caret restoration. A real-WebKit/native-window regression fails on build 21 and passes with this fix, covering both directions, fractional momentum-style deltas, preview mode, nested scrolling and bounds. This is simulated input evidence, not a physical trackpad hardware certification.

The build 22 focused suite passed 15 editor/lifecycle tests, including the 300 Return cycles. In a separate synthetic 70-paragraph note, native UI scrolling over the body moved the outer scrollbar from 0.935 to 0.224 upward and then 0.579 downward; the body retained keyboard focus. The shipped universal bundle passed strict signature verification.

### Visible editing tools

Build 23 exposes the everyday controls above the body in labeled Text and Insert rows. Bold/italic/underline/strike, text color/highlight, lists/tasks, links, tables, images and attachments are directly visible. Alignment/clear formatting and secondary insert/export tools remain in named menus. Controls wrap at narrow widths, retain their selected/disabled state, and scroll with the title/body.

Build 24 replaces native HTML color wells with local button-anchored palettes. This avoids the misplaced WebKit/macOS color popover when the editor is nested in a scrolled native document. Both text color and highlight offer preset swatches, validated HEX input and reset; outside click/Escape dismisses the palette. No system-wide color panel is opened.
