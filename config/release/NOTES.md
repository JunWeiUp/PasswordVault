## Changes

- Unified personal relay sync across macOS, Windows, iOS and Android on top of the `common-relay` Rust SDK in `vault-core`, removing legacy peer libraries and aligning device-group state, retry/exit policy and transport behavior.
- Tightened the `vault-core` JSON command contract across all clients (including browser WASM dispatcher validation) and synchronized all four client stacks to `2.5.12`.
- Streamlined local build, device installation and release workflows, and modularized large browser extension and `vault-core` native modules.

## Downloads

Five packages: Android ARM64, macOS, Windows x64, iOS Simulator and Chromium extension.

A valid invitation grants full access to the vault; share it only with your own devices. Windows is an unsigned portable x64 package; extract the whole folder. Mac requires Apple Silicon / macOS 14+ and is not notarized. The iOS package is simulator-only. Preserve an encrypted backup before upgrading. A regular release does not imply completed production-security acceptance.

[Installation](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/INSTALL.md) · [License](https://github.com/JunWeiUp/PasswordVault/blob/main/LICENSE) · [Third-party notices](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/THIRD_PARTY_NOTICES.md)
