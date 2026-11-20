## Changes

- Mac and Windows (NSH 0.6.0): Optional line numbers in the note rich editor and Markdown source pane (Settings toggle, on by default).
- Local AI (MCP): Tools consolidate into five — `find`, `read`, `create`, `update` and `delete` — across entries and knowledge-base notes, with `passwordvault:<id|slug|title>` references. Reading a password or other secret still needs approval; writes save an AI-attributed encrypted history revision and deletion only moves to the Trash, so every change is restorable. Non-secret extras are kept as `Label: value` lines in the note instead of scattered custom fields, and `update` can remove fields.

## Downloads

Five packages: Android ARM64, macOS, Windows x64, iOS Simulator and Chromium extension.

A valid invitation grants full access to the vault; share it only with your own devices. Windows is an unsigned portable x64 package; extract the whole folder. Mac requires Apple Silicon / macOS 14+ and is not notarized. The iOS package is simulator-only. Preserve an encrypted backup before upgrading. A regular release does not imply completed production-security acceptance.

[Installation](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/INSTALL.md) · [License](https://github.com/JunWeiUp/PasswordVault/blob/main/LICENSE) · [Third-party notices](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/THIRD_PARTY_NOTICES.md)
