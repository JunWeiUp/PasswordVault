# Applications and shared code

| Directory | Role | Status |
| --- | --- | --- |
| `desktop/` | Native Shell 0.5 / Rust / TSX shared desktop client | Current Mac development and Windows x64 preview; macOS 14+ Apple Silicon, Windows 11 ARM VM validation |
| `ios/` | SwiftUI mobile client and AutoFill extension | Active mobile client |
| `android/` | Kotlin/Compose mobile client | Active mobile client |
| `browser/` | Chromium extension | Active browser client |
| `shared/` | Cross-client source and assets | Shared capabilities, relay and web-based rich-note editor |

The four client stacks share the Rust core in `crates/vault-core`. The Mac client
uses the official native RichEditor; the shared web editor is used by iOS, Android
and the browser extension. The legacy SwiftUI Mac client was removed (see Git
history); its shared Swift files now live in `ios/Sources`.
Application IDs, encrypted formats and user data directories remain unchanged.
