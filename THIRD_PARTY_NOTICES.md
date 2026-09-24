# Third-party notices

PasswordVault is MIT licensed. Dependencies, Flutter engine assets, SQLite, icons, and generated runtime bundles retain their respective licenses.

## Retained Flutter clients

The authoritative legacy dependency versions are in `pubspec.lock`. Review their package license files before distributing binaries. Flutter includes an asset license registry in built applications (`NOTICES` / `NOTICES.Z`); retain it in web and extension packages. The app's About section links to Flutter's license viewer.

Notable components include Flutter (BSD-3-Clause), Drift (MIT), sqlite3.dart (MIT), SQLite (public domain), and cryptography (Apache-2.0). This list is descriptive and not a replacement for the complete bundled notices.

The legacy extension package includes locally bundled Flutter/CanvasKit and Drift runtime assets. Do not remove their notices during packaging.

Documentation renders use Roboto and Material Icons from the pinned Flutter SDK. The capture harness also includes Roboto Mono by the Roboto Mono Project Authors, distributed under the SIL Open Font License 1.1; see [the included license](docs/images/fonts/OFL.txt). This font is used only by the screenshot harness and is not registered as an application asset.

## Native clients

Native Rust dependency versions are locked in `Cargo.lock`; browser JavaScript dependencies are locked in `apps/browser/package-lock.json`. The new Preact extension does not contain Flutter or CanvasKit. Rust/SQLCipher, UniFFI, Preact and platform dependencies retain their own licenses; these notices do not replace a complete distribution license inventory. The BIP39 word-list attribution is in [BIP39-NOTICE.txt](docs/BIP39-NOTICE.txt).

The macOS Markdown editor pins Milkdown 7.22.2 (MIT) and includes ProseMirror/remark dependencies from `apps/macos/NoteEditor/package-lock.json`. Its build generates `NoteEditor-LICENSES.txt` from the licenses of every package contributing to the bundle, and embeds it with the local editor HTML in the app's Resources directory. Do not remove that notice file when packaging the Mac app. Esbuild is a build tool and is not shipped in the application.
