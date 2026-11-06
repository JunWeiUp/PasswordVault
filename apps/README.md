# Applications and shared code

| Directory | Role | Status |
| --- | --- | --- |
| `macos-nsh/` | Native Shell 0.4 / Rust / TSX Mac client | Current Mac development and local daily application; macOS 14+, Apple Silicon |
| `macos-legacy/` | SwiftUI / WebKit Mac client | **Legacy Mac client**; retained for compatibility, rollback and existing release tooling |
| `ios/` | SwiftUI mobile client and AutoFill extension | Active mobile client |
| `android/` | Kotlin/Compose mobile client | Active mobile client |
| `browser/` | Chromium extension and standalone Web | Active browser client |
| `shared/` | Cross-client source and assets | Shared capabilities, relay and web-based rich-note editor |

The current Mac client uses the official native RichEditor. The shared web editor
is still required by the legacy Mac, iOS, Android and browser clients. Do not
remove legacy Mac files without checking mobile Swift source/resource references.
Application IDs, encrypted formats and user data directories remain unchanged.
