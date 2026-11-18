## Changes

- Mac and Windows (NSH 0.6.0): AI access moves to Tools with clipboard delivery for secrets, 15-minute or until-lock approvals and first-request grants. Accounts show their two-factor code in the list and detail, link existing code entries after confirmation, and list several websites. Identity documents can be shown and edited. The sidebar, toolbar, settings, Touch ID and relay pages are reorganized.
- iOS: codes from a scan, image, link or manual key; multi-select and context menus; read-only Devices & services; a passphrase generator; identity document fields; a step-by-step first run; and Sync & devices organized around the device group.
- Android: account health and strength, save-failure recovery, setup QR codes, a card-face header, format-7 device entries, a passphrase generator, identity documents, fingerprint re-verification and an IME-safe input mode.
- Browser extension: popup and full page follow the extension design, page language and theme, with refined account tiles, sync state and fill confirmation.
- Core: upper-case `otpauth://` links import correctly, `;` separates account websites for matching, and passphrases can be generated.

## Downloads

Five packages: Android ARM64, macOS, Windows x64, iOS Simulator and Chromium extension.

A valid invitation grants full access to the vault; share it only with your own devices. Windows is an unsigned portable x64 package; extract the whole folder. Mac requires Apple Silicon / macOS 14+ and is not notarized. The iOS package is simulator-only. Preserve an encrypted backup before upgrading. A regular release does not imply completed production-security acceptance.

[Installation](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/INSTALL.md) · [License](https://github.com/JunWeiUp/PasswordVault/blob/main/LICENSE) · [Third-party notices](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/THIRD_PARTY_NOTICES.md)
