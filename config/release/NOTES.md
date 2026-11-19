## Changes

- Mac and Windows (NSH 0.6.0): Personal knowledge base notes with hierarchical folders, structured properties and `slug` routes, `[[wikilinks]]` and backlinks, diff version history, and 100 MB encrypted chunked assets (`blobs/`) with Quick Look, local PDF/Office text extraction, and one-click external-edit encrypted write-back.
- Local AI (MCP): Category-level access scopes (`accounts`, `profiles`, `devices`, `notes`, `noteAssets`) with top-pinned sidebar `AI Access`, interactive paired-client management (non-secret fingerprints, encrypted remarks, duplicate-name warnings, pause/resume, audit filtering, and one-click unused token cleanup), and six note/asset MCP tools (`note_list`, `note_read`, `note_update`, `note_attach`, `note_read_asset`, `note_history`). Devices & services document library supports per-row deletion.
- Core: Per-note encrypted `note_bodies` storage, 64 KiB AES-256-GCM chunked `blobs/` with HMAC-SHA256 deduplication and reference-counted GC, and generic JSON passthrough primitives.
- iOS & Android: Linked live 2FA codes with countdown and copy on account detail, password strength indicators, and device/entry list refinements.
- Browser extension: Quick password copy and strength indicators, passkey and vault UI refinements, and updated English localization.

## Downloads

Five packages: Android ARM64, macOS, Windows x64, iOS Simulator and Chromium extension.

A valid invitation grants full access to the vault; share it only with your own devices. Windows is an unsigned portable x64 package; extract the whole folder. Mac requires Apple Silicon / macOS 14+ and is not notarized. The iOS package is simulator-only. Preserve an encrypted backup before upgrading. A regular release does not imply completed production-security acceptance.

[Installation](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/INSTALL.md) · [License](https://github.com/JunWeiUp/PasswordVault/blob/main/LICENSE) · [Third-party notices](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/THIRD_PARTY_NOTICES.md)
