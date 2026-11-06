# Downloads

Each release provides five packages:

| Package | Use |
| --- | --- |
| Android ARM64 APK | Android 8.0+ phones; preserve the installed signing identity and encrypted backup. |
| macOS ZIP | Apple Silicon, macOS 14+; extract the app to Applications. |
| iOS Simulator ZIP | Xcode 26.3 / iOS 26.2 Simulator; not an iPhone IPA. |
| Extension ZIP | Extract to a permanent folder and load unpacked in Chrome or Edge. |
| Web ZIP | Extract and serve over HTTPS or localhost. |

Developer preview. Mac public builds are ad-hoc signed, not notarized; Touch ID
is not guaranteed. Keep a verified encrypted backup before upgrading or switching
signing identities. Never uninstall the only vault copy to resolve a signature
mismatch. Separate vaults do not automatically merge.

CI verifies signatures and SHA-256 checksums before upload. BUILD.json and
SHA256SUMS are internal validation records, not extra public downloads. GitHub
also exposes each uploaded asset's digest. License texts and component notices
remain linked from the release description and repository.
