## Changes

- Add extension parity to NSH Mac (`update-login`, `open-entry`, one-time-code and card/identity requests with per-request Mac confirmation), refresh extension-saved accounts in the open Mac window immediately, detect plaintext `type="text"` password fields, offer "Update account" and change-password account inference/selection in the save banner, and show the pending offline-sync count in the popup.
- Preserve the browser "auto-unlock Mac at startup" option across certificate-signed Mac updates by binding Keychain grants to the signed designated requirement with CDHash fallback for ad-hoc builds.
- Add optional titles for Devices & Services entries and script/document rows, display titles by default when set, include them in search, and expose non-secret script labels to AI projections.

## Downloads

Five packages: Android ARM64, macOS, Windows x64, iOS Simulator and Chromium extension.

A valid invitation grants full access to the vault; share it only with your own devices. Windows is an unsigned portable x64 package; extract the whole folder. Mac requires Apple Silicon / macOS 14+ and is not notarized. The iOS package is simulator-only. Preserve an encrypted backup before upgrading. A regular release does not imply completed production-security acceptance.

[Installation](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/INSTALL.md) · [License](https://github.com/JunWeiUp/PasswordVault/blob/main/LICENSE) · [Third-party notices](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/THIRD_PARTY_NOTICES.md)
