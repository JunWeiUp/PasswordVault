# Applications and shared code

| Directory | Role | Status |
| --- | --- | --- |
| `desktop/` | Native Shell 0.4 / Rust / TSX shared desktop client | Current Mac development and Windows x64 preview; macOS 14+ Apple Silicon, Windows 11 ARM VM validation |
| `macos-legacy/` | SwiftUI / WebKit Mac client | **Legacy Mac client**; retained for source archive and manual rollback; no legacy CI/release artifact |
| `ios/` | SwiftUI mobile client and AutoFill extension | Active mobile client |
| `android/` | Kotlin/Compose mobile client | Active mobile client |
| `browser/` | Chromium extension and standalone Web | Active browser client |
| `shared/` | Cross-client source and assets | Shared capabilities, relay and web-based rich-note editor |

The current Mac client uses the official native RichEditor. The shared web editor
is still required by the legacy Mac, iOS, Android and browser clients. Do not
remove legacy Mac files without checking mobile Swift source/resource references.
Application IDs, encrypted formats and user data directories remain unchanged.
