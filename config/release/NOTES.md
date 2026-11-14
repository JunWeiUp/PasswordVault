## Changes

- Replace primary-device sync with symmetric bidirectional sync. Devices that join a group by scanning an invitation sync both ways automatically; there is no primary confirmation, per-device authorization, pending queue or conflict list. The newer edit wins and older versions stay in entry history.
- Existing groups upgrade in place on first sync with an encrypted pre-upgrade snapshot; unconfirmed mobile edits are kept and old conflict versions move to entry history. Update every device in a group; older versions stop exchanging until updated.
- Show sync progress on Android, refresh the Android workspace layout, add a low-memory Mac background service and broader desktop search, and fix Mac unlock stalls caused by repeated executable validation.

## Downloads

Six packages: Android ARM64, macOS, Windows x64, iOS Simulator, Chromium extension and Web.

A valid invitation grants full access to the vault; share it only with your own devices. Windows is an unsigned portable x64 package; extract the whole folder. Mac requires Apple Silicon / macOS 14+ and is not notarized. The iOS package is simulator-only. Preserve an encrypted backup before upgrading. A regular release does not imply completed production-security acceptance.

[Installation](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/INSTALL.md) · [License](https://github.com/JunWeiUp/PasswordVault/blob/main/LICENSE) · [Third-party notices](https://github.com/JunWeiUp/PasswordVault/blob/main/config/release/THIRD_PARTY_NOTICES.md)
