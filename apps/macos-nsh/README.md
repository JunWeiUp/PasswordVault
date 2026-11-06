# PasswordVault for Mac — Native Shell preview

This is the current Mac client on [Native Shell](https://nsh.dev) 0.4.0.
It uses a Rust crate with a TSX interface, and the interface follows
[the complete Mac design](../../docs/design/index.html). The SwiftUI app in
[`apps/macos-legacy`](../macos-legacy/README.md) is retained as the legacy client for compatibility,
rollback and the existing release workflow.

- **Platform:** macOS 14+ on Apple Silicon only. Native Shell requires macOS 14, and its
  prebuilt runtimes are arm64-only.
- **Core:** `crates/vault-core` is linked directly into the app crate (`src/lib.rs`).
  TSX sends JSON commands through `Vault.command` and never receives key material. Slow
  operations run on Native Shell's blocking threads.
- **Data:** by default, the vault lives in
  `~/Library/Application Support/PasswordVaultNSHPreview/vault`, separate from the
  SwiftUI app's `PasswordVaultNative`. To point the app elsewhere, pass
  `--vault-directory <dir>` or set `PASSWORDVAULT_VAULT_DIRECTORY`.
- **Bundle ID:** `com.securepass.vault.nshpreview`. Production identifiers are unchanged.

## Commands

Run these commands from the repository root. The wrapper pins NSH 0.4.0 and
Rust 1.98.0 while requiring [huacnlee/cargo](https://huacnlee.github.io/cargo/).
Install NSH with `NSH_VERSION=v0.4.0 NSH_INSTALL_DIR="$HOME/.nsh-0.4.0"`
using the official installer, or set `NSH_BIN` to another 0.4.0 executable.
The Cargo bridge in `tool/nsh-cargo/cargo` links generated NSH executables to
the paths NSH expects because the fork ignores `--target-dir`; compilation
and shared caches remain owned by the fork. It never invokes upstream Cargo.

```sh
bash tool/nsh_mac.sh check                      # Rust build + TypeScript check
cd apps/macos-nsh && cargo run --example seed -- /tmp/pv-nsh-qa/vault   # synthetic vault (with the pinned toolchain)
PASSWORDVAULT_VAULT_DIRECTORY=/tmp/<copy>/vault bash tool/nsh_mac.sh test   # headless UI tests
```

`nsh_mac.sh test` refuses to run unless `PASSWORDVAULT_VAULT_DIRECTORY` points
inside a temporary directory. Always create a fresh synthetic vault there; do not
point tests at existing vault data.

Real-window tests run only on a yomado virtual screen whose name contains
`PasswordVault QA`, never on a physical display. `bash tool/macos-nsh/gui.sh` finds that
screen, syncs a `/tmp` copy (apps are not launched from the Documents checkout), uses a
fresh synthetic vault, and saves screenshots in `/tmp/pv-nsh-shots`. Use only synthetic
vaults.

### Signed preview (Touch ID)

`bash tool/macos-nsh/package.sh` builds `native-test-output/mac-nsh-preview/PasswordVault NSH
Preview.app` (ignored by Git). It reads the team from the ignored
`private/signing/macos/Signing.local.xcconfig`. A throwaway Xcode stub with the preview bundle
ID gets a matching development profile; the script embeds that profile and signs with the
`keychain-access-groups` entitlement. It never replaces `/Applications/PasswordVault.app`.

To check Touch ID by hand, use a synthetic vault (password in `examples/seed.rs`):

```sh
rm -rf /tmp/pv-nsh-preview /tmp/pv-nsh-manual && mkdir /tmp/pv-nsh-preview
cp -R "native-test-output/mac-nsh-preview/PasswordVault NSH Preview.app" /tmp/pv-nsh-preview/
cp -R /tmp/pv-nsh-qa /tmp/pv-nsh-manual
open -n "/tmp/pv-nsh-preview/PasswordVault NSH Preview.app" --args --vault-directory /tmp/pv-nsh-manual/vault
```

### Daily install

`bash tool/macos-nsh/install.sh <backup dir>` installs the signed build as
`/Applications/PasswordVault.app`. The bundle's Info.plist sets `PVVaultDirectoryName =
PasswordVaultNative` (the shipping vault folder); builds without that key stay on the isolated
preview folder. The script keeps the SwiftUI app as `PasswordVault (SwiftUI).app`, refuses to
overwrite an existing copy, and points the Chrome/Edge/Edge Beta/ego native-host manifests at
`pv-browser-host`. Back up the vault folder and the manifests first. To roll back, quit, delete
the new app, rename the SwiftUI app back, and restore the manifests from the backup.

Closing the window hides it; the app keeps running, unmounts its interface, and drops decrypted
items until the Dock icon shows the window again.

## Status

| Area | State |
| --- | --- |
| Unlock, first-run vault creation, lock | Implemented. Headless-tested |
| Sidebar, list, search, filters, context menus, app menu | Implemented |
| Accounts, codes, payment cards, identities, crypto wallets: view and edit | Implemented. Saves preserve password history and peer heads |
| Plain notes, note categories (add/remove, keeping notes) | Implemented |
| Trash: restore, permanent delete, empty | Implemented. Headless-tested |
| Password generator (random, PIN), password health | Implemented |
| Quick Access + global shortcut (⇧⌘Space / ⌥⌘P / off; `src/hotkey.rs`) | Implemented. Registration fails visibly when another app (e.g. the SwiftUI client) holds the shortcut; tests never register it |
| Settings: appearance, idle lock, change master password | Implemented |
| Backup & import: encrypted export/import via native open/save panels (`src/files.rs`), CSV/1PUX review, WebDAV (HTTPS only, no redirects/cookies, never overwrites) | Implemented (`src/backup.rs`, `ui/settings/`). Real panels, real WebDAV servers and network cancellation unverified |
| Recovery key, emergency archive, recovery-key password reset, version history | Implemented (`src/recovery_io.rs`, `ui/recovery/`, `ui/history/`). Native print/open/save panels unverified |
| Rich notes and attachments | Official native `RichEditor` with Rust ProseMirror state; supported rich-v1 documents round-trip with a preservation gate; see `ui/notes/README.md`. Physical Chinese IME and VoiceOver unverified |
| Touch ID, sleep/screen-lock locking, system idle | Implemented (`src/macos/README.md`); Keychain/Touch ID and physical sleep unverified — needs a signed preview bundle with keychain entitlements; signals are polled every 500 ms |
| Relay sync and device groups (`src/relay/`, `ui/relay/`) | Implemented against protocol vectors and loopback servers: groups, invitations/QR, approval, presence, grants/revocation, item/peer sync, encrypted journal, file transfer. Production admission/WSS and QR image auto-password joining passed with synthetic vaults through the NSH headless component driver; native image-picker UI, camera, phone interoperability and long-offline/memory behavior unverified; see `src/relay/README.md` |
| Browser extension bridge (`src/browser/`, `pv-browser-host`) | Core flows implemented (status, pairing, matches, fill, save, lock, background save, startup unlock). `open-entry`, login update, OTP, structured fill and passkeys are not yet supported (fail closed). Real browsers unverified; see `src/browser/README.md` |
| AI access (`src/ai/`, `pv-mcp`) | Local MCP + script mode, default off, read-only, per-request secret approval, audit without content, fixed socket path. Real AI clients unverified; see `src/ai/README.md` |
| Devices & services (`ui/devices/`, core `device` type) | Implemented behind an explicit format-7 upgrade with snapshot; enabling it pauses relay sync and requires all clients to update. Other clients' device UI not yet built; see `docs/DEVICE-ITEMS.md` |

Passing compilation or headless tests is not acceptance for Touch ID, the browser, devices,
or production security. See `docs/SECURITY_MODEL.md`.

The signed package reuses the macOS AppIcon asset catalog through `tool/macos-nsh/icon.sh`, which installs `AppIcon.icns` and its Info.plist reference before signing.
