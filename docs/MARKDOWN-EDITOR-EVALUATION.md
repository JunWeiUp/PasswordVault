# WYSIWYG Markdown editor evaluation

Status: integrated into the **Mac 2.0.9 build 13** developer preview; the browser remains 2.0.9. The prototype findings below are retained separately from the WKWebView integration evidence.

The requested behavior is a rendered Markdown surface that is directly editable, continues lists on Return, exits an empty list item on Return, and preserves a local caret while editing earlier paragraphs. The previous native implementation manually replaced attributed text and mapped source/rendered offsets without a dedicated Return/list command. The replacement uses ProseMirror transactions for these operations.

## Candidates

| Candidate | Fit | Integration considerations |
| --- | --- | --- |
| [Milkdown](https://github.com/Milkdown/milkdown), MIT | Recommended. A WYSIWYG Markdown framework built on ProseMirror and remark, inspired by Typora. Its commonmark/gfm/history plugins supply a structured editing model and list commands. | Use a bundled local editor in a system WKWebView inside the existing SwiftUI app. Style it to match the current note page; avoid rewriting content on autosave echoes. |
| [Vditor](https://github.com/Vanessa219/vditor/blob/master/README.md), MIT | A viable alternative with WYSIWYG, instant rendering and split preview, plus extensive Markdown features. | Choose WYSIWYG for consistently hidden syntax. Disable its optional cache/upload/remote-resource behaviors and bundle only needed assets. Its broad feature set needs more configuration for this vault. |
| [SwiftMarkdownEngine](https://github.com/nodes-app/swift-markdown-engine) | Native AppKit/TextKit 2 with SwiftUI integration. | Its current [Package.swift](https://github.com/nodes-app/swift-markdown-engine/blob/main/Package.swift) requires macOS 14, while this application targets macOS 13. Live styling alone does not establish the requested hidden-syntax editing behavior. |

The Xiaomi implementation mentioned in conversation was not identified by repository or URL; none of these candidates is claimed to be Xiaomi's implementation.

## Prototype evidence

Pinned `@milkdown/kit` to **7.22.2** and bundled commonmark, GFM and history locally. The generated JavaScript bundle is 451,329 bytes, excluding HTML/CSS; this is a file-size measurement, not runtime memory. The prototype uses fictional text and does not connect to a vault, database or network service. Its content-security policy disallows network connections, images and fonts.

Eight behaviors passed in ego lite:

1. Return continues an unordered list.
2. Return on an empty item exits the list.
3. Return continues an ordered list.
4. Two consecutive insertions into the middle of an earlier paragraph retain that insertion point.
5. Undo and redo restore those edits.
6. Typing `# d` produces a rendered heading without the marker.
7. Tab indents a list item under its predecessor.
8. A browser-protocol simulated Chinese composition commits at the chosen middle position and subsequent typing stays there.

These results establish candidate behavior in Chromium, not acceptance in macOS WKWebView or with every physical input method. During testing, resetting each synthetic document required `replaceAll(markdown, true)` to reset history; this must only be used when loading a new document, not during ordinary save acknowledgements.

## Mac integration evidence

- The full Mac suite passes 57 tests, including 10 editor cases. Real WKWebView tests cover unchanged source on opening, final input at lock, repeated closing snapshots, rendered-to-source handover, failed snapshots blocking exports, stale messages, read-only rejection, metadata saves, list continuation, middle insertion, undo/redo, literal HTML and blocked network requests. A simulated Chinese composition rejects stale replacement and survives lock/reopen; it is not a physical input-method certification.
- Isolated native-window checks with fictional data cover direct preview editing, list continuation, keyboard undo/redo, the native Edit menu, source switching, table/code/task rendering and long-document caret visibility. The outer native scroll view follows the caret and preserves editing focus.
- The detail toolbar uses consistent 32-point controls, 12-point group spacing and an adaptive compact layout. Chinese dark and English light layouts were checked at a 500-point detail width; the More menu remains functional. Current [notes](design/macos-native/current-notes.png) and [password](design/macos-native/current-password.png) screenshots contain only synthetic data.
- All assets and third-party notices are generated from a locked npm tree and embedded locally. The WebView uses a nonpersistent data store and no remote resources. The existing Rust encrypted persistence path owns all saving.
- Remaining scope: physical Chinese input methods, broader accessibility, macOS 13/Intel hardware, WebKit process-termination recovery and populated process/GPU memory measurement. These are not certified by compilation or simulated composition.

## Integration invariants

- Retain SwiftUI navigation, title and metadata; replace only the Markdown editing surface.
- Package editor scripts/styles/licenses locally, use a nonpersistent web data store and restrict resource/navigation access. Keep all note persistence on the existing encrypted native path.
- Do not reinitialize or replace the editor on each keystroke/autosave echo. Synchronize external changes with revision checks so older native updates cannot move the caret or overwrite newer text.
- Explicitly flush the latest editor state before locking, switching records, exporting or quitting. Test delayed bridge messages, locking during composition and stale callbacks after reopening.
- Preserve originals on open; serialize only actual edits. Milkdown normalizes Markdown formatting (for example list-marker spelling), so semantic round-trip tests must cover existing notes, links, code, tasks, tables and unsupported constructs before migration.
- Reaccept read-only/Trash behavior, native Edit-menu undo, copy/paste, dark mode, long notes and macOS 13 compatibility. This evaluation does not certify those integration paths.
