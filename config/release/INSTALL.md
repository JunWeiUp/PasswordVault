# Downloads

Each release provides six packages:

| Package | Use |
| --- | --- |
| Android ARM64 APK | Android 8.0+ phones; preserve the installed signing identity and encrypted backup. |
| macOS ZIP | Apple Silicon, macOS 14+; extract the app to Applications. |
| Windows x64 ZIP | Extract the entire folder and run `PasswordVault.exe`; keep its `nsh` subfolder beside it. |
| iOS Simulator ZIP | Xcode 26.3 / iOS 26.2 Simulator; not an iPhone IPA. |
| Extension ZIP | Extract to a permanent folder and load unpacked in Chrome or Edge. |
| Web ZIP | Extract and serve over HTTPS or localhost. |

Mac public builds are ad-hoc signed, not notarized; Touch ID
is not guaranteed. Keep a verified encrypted backup before upgrading or switching
signing identities. Never uninstall the only vault copy to resolve a signature
mismatch. Separate vaults do not automatically merge.

CI verifies signatures and SHA-256 checksums before upload. BUILD.json and
SHA256SUMS are internal validation records, not extra public downloads. GitHub
also exposes each uploaded asset's digest. License texts and component notices
remain linked from the release description and repository.

## Windows

The Windows x64 portable package is included in regular releases starting with
2.4.1. Install the [Microsoft Visual C++ v14 x64 runtime](https://aka.ms/vc14/vc_redist.x64.exe)
if it is not already installed (see [Microsoft requirements](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist)). It was exercised on Windows 11 ARM using x64 emulation. The package is not
Authenticode-signed; verify its release digest before running it. Existing vaults
remain in `%LOCALAPPDATA%/PasswordVaultNSHPreview/vault` across upgrades. Close the
app before replacing the extracted program folder; never delete its data directory.

Vault editing, notes, backup/import, native file dialogs and personal relay sync
are available. Browser native messaging, AI local IPC, global shortcuts, external
terminal handoff and recovery-key printing are not enabled on Windows. Touch ID
is Mac-only. Primary-device transfer is not included on any platform in this release.
