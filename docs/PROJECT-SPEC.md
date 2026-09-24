# Project specification

## Positioning and goals

PasswordVault is a local-first home for passwords, TOTP codes, secure notes, and wallet credentials. Its primary workflow is to find an entry, use a credential, and return to the previous task. The default language is English, with Simplified Chinese available before and after unlock.

The product aims to keep related credentials together, make search and everyday tools easy to reach, adapt to compact and wide screens, and let users rehearse backup and recovery. It remains a developer preview with unresolved [security blockers](SECURITY_MODEL.md); available features are not evidence of production safety.

## Native migration scope

The approved target is SwiftUI on Mac/iOS, Kotlin/Compose on Android, and a lightweight standalone Web/Chromium client with a shared Rust core. Mac and extension come first. macOS 13+ (arm64/x86_64), iOS 16+, and Android 7+ are targets; only the Mac and browser source increment exists today. Mac defaults to Simplified Chinese and supports English. Notes are text/Markdown without attachments. The selected design is [Native Notes](design/macos-native/README.md).

See [implemented paths, evidence, and pending parity](NATIVE-MIGRATION.md). Native biometric, network, browser-fill, and lower-OS/hardware acceptance must be distinguished from compilation and unit tests.

## Legacy functional scope

| Area | Current source scope |
| --- | --- |
| Accounts | Multiple accounts and domains, search, categories, tags, favorites, pins, history, and trash |
| Codes | Manual TOTP entry and Android/iOS QR scanning; single-account SHA-1, 6-digit TOTP with the supplied refresh interval |
| Other entries | Secure notes and wallet records, including address, network, mnemonic, and private-key fields |
| Tools | Password generation and weak, reused, or expired password checks |
| Autofill | Android autofill service and experimental Chromium Manifest V3 extension |
| Data portability | CSV import, JSON/CSV export, and WebDAV backup/restore with existing encryption options |
| Collaboration | Experimental local discovery, LAN synchronization, and shared vaults |
| Presentation | Light/dark/system themes, responsive navigation, English and Simplified Chinese |

HOTP, other TOTP algorithms/digit lengths, and Google Authenticator migration QR codes are outside the current scanner scope. Manual key entry remains available when camera access is denied. The product has no managed cloud account service or automatic hosted synchronization.

## Platform scope

| Target | Current boundary |
| --- | --- |
| Android | Runner, autofill integration, and signed APK/AAB pipeline; physical-device checks remain necessary |
| iOS | Runner and camera integration exist; device, signing, and release validation remain pending |
| Web | Experimental Flutter build; browser storage and WebDAV CORS limitations apply |
| Chromium extension | Experimental unpacked extension; storage, message boundaries, and actual browser behavior need validation |
| Native desktop | New SwiftUI macOS client builds for arm64/x86_64; macOS 13/Intel hardware and Touch ID acceptance remain pending. No Windows or Linux client exists. |

## Acceptance and maintenance

Changes should preserve existing vault data and identifiers, describe failures accurately, and support the relevant empty, loading, error, and recovery states. Use synthetic fixtures for screenshots, imports, backups, and tests. Security-sensitive changes require migration and failure-path evidence.

Use [TODO.md](../TODO.md) for priorities and progress, [CHANGELOG.md](../CHANGELOG.md) for completed changes, [DESIGN.md](../DESIGN.md) for presentation, and [ARCHITECTURE.md](ARCHITECTURE.md) for implementation boundaries. Installation instructions remain in [GETTING_STARTED.md](GETTING_STARTED.md).
