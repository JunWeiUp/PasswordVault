# PasswordVault Desktop — Native Shell

This is the shared desktop client on [Native Shell](https://nsh.dev) 0.7.0.
It uses a Rust crate with a TSX interface, and the interface follows
[the complete Mac design](../../docs/design/index.html). It is the only Mac client; the legacy
SwiftUI client was removed from the source tree (see Git history).

- **Platforms:** macOS 14+ on Apple Silicon, and a Windows x64 preview. Windows
  checks currently run on Windows 11 ARM through x64 emulation.
- **Core:** `crates/vault-core` is linked directly into the app crate (`src/lib.rs`).
  TSX sends JSON commands through `Vault.command` and never receives key material. Slow
  operations run on Native Shell's blocking threads.
- **Data:** by default, the vault lives in
  `~/Library/Application Support/PasswordVaultNSHPreview/vault`, separate from the
  SwiftUI app's `PasswordVaultNative`. To point the app elsewhere, pass
  `--vault-directory <dir>` or set `PASSWORDVAULT_VAULT_DIRECTORY`.
- **Bundle ID:** `com.securepass.vault.nshpreview`. Production identifiers are unchanged.

## Shared desktop architecture

`App.tsx`, `ui/` and the Rust business modules are shared by desktop platforms.
`src/platform.rs` selects native services; `src/macos/` retains Keychain and
macOS system events. Unsupported biometrics report unavailable and reject key
operations. Windows uses LOCALAPPDATA for its isolated preview vault.

macOS and the Windows x64 preview share this source. Windows local IPC and private-ACL acceptance remain unfinished. System lock/sleep
events and idle time have native adapters with synthetic event coverage.
Windows native open/save and multi-file dialogs are implemented using rfd;
selected document files are opened without following reparse points. The Windows library and NSH interface checks pass on Windows 11 ARM through
x64 emulation; native-window account and rich-editor tests also pass. Native
file-dialog cancellation/selection and physical sleep/lock still need manual acceptance. Recovery-key printing is unsupported on Windows.
Mac-specific packaging stays in `tool/macos-nsh/`; `tool/nsh_mac.sh` remains
the compatible macOS command. IDs and encrypted storage formats are unchanged.

## Windows preview

See [Windows build and packaging](../../tool/windows-desktop/README.md). Platform
capabilities gate unsupported browser/AI IPC, terminal handoff, recovery printing
and global shortcuts. Windows uses the system title bar and Ctrl-key hints.

## Commands

Run these commands from the repository root. The wrapper pins NSH 0.7.0 and
Rust 1.98.0 while requiring [huacnlee/cargo](https://huacnlee.github.io/cargo/).
Install NSH with `NSH_VERSION=v0.7.0 NSH_INSTALL_DIR="$HOME/.nsh-0.7.0"`
using the official installer, or set `NSH_BIN` to another 0.7.0 executable.
The Cargo bridge in `tool/nsh-cargo/cargo` links generated NSH executables to
the paths NSH expects because the fork ignores `--target-dir`; compilation
and compilation caches remain owned by the fork. Desktop wrappers isolate dependency
metadata because core and desktop use different pinned rustc versions. It never invokes upstream Cargo.

```sh
bash tool/nsh_mac.sh check                      # Rust build + TypeScript check (0 warnings)
bash tool/nsh_mac.sh test-fast ts-api           # pure TS unit tests (auto-seeds /tmp vault)
bash tool/nsh_mac.sh test-fast devices          # single headless UI suite (~8s, auto-seeds /tmp vault)
bash tool/nsh_mac.sh test-fast --rust ai::      # targeted Rust unit tests (~2s)
bash tool/nsh_mac.sh test-smoke                 # full suite skipping 27s memory test
bash tool/nsh_mac.sh test-full                  # full suite including memory test
bash tool/macos-nsh/deploy.sh                   # --auto: ~3-5s QuickJS bundle swap when only TS changed, else full signed install
```

Desktop logic, view-models, typed API adapters (`ui/api/`), formatting and UI
workflows stay in TypeScript so UI iterations ship via `--ui-only` without
recompiling Rust. Standalone native helpers (`helpers/pv-mcp`,
`helpers/pv-browser-host`) live as lightweight workspace members so helper
changes never rebuild the full desktop UI library.

`nsh_mac.sh test` refuses to run unless `PASSWORDVAULT_VAULT_DIRECTORY` points
inside a temporary directory (`test-fast`, `test-smoke` and `test-full` manage
an isolated cached synthetic seed vault under `/tmp` automatically). Always use
fresh synthetic vaults; never point tests at existing vault data.

Real-window tests run only on a yomado virtual screen whose name contains
`PasswordVault QA`, never on a physical display. `bash tool/macos-nsh/gui.sh` finds that
screen, syncs a `/tmp` copy (apps are not launched from the Documents checkout), uses a
fresh synthetic vault, and saves screenshots in `/tmp/pv-nsh-shots`. Use only synthetic
vaults.

### Search

List search and Quick Access share matching across visible entry details, note
text, additional logins, custom fields, card/identity information, device services
and public documents, plus note attachment names/link targets. Separate keywords
with spaces to match across fields. Search ignores case, full-width variants and
Latin accents, and prioritizes title matches. List search respects the current
type, category and chips; All Items searches across active types, while Trash is
searched separately. Quick Access includes notes and shows up to eight results.

Passwords/history, OTP seeds, private keys, recovery phrases, card security codes,
concealed values and secret document bodies are excluded. Binary attachment
contents and OCR are not searched. The lazy in-memory search index is cleared on
lock/window hiding; it does not add a disk index or change the vault format.

```sh
node --test tool/test_desktop_search.mjs
PASSWORDVAULT_VAULT_DIRECTORY="$(mktemp -d /tmp/pv-search-qa.XXXXXX)/vault" bash tool/nsh_mac.sh test tests/search.test.tsx
```

The component fixture uses fictional in-memory records and never opens a vault.
These checks do not verify the installed app, physical input methods or Windows.

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
| Relay sync and device groups (`src/relay/`, `ui/relay/`) | Implemented against protocol vectors and loopback servers: groups, scan-to-join invitations/QR, presence, symmetric bidirectional sync (newest change wins, older versions in entry history, no grants/primary/conflict list), encrypted journal, file transfer. Production admission/WSS and QR image auto-password joining passed with synthetic vaults through the NSH headless component driver; native image-picker UI, camera, phone interoperability and long-offline/memory behavior unverified; see `src/relay/README.md` |
| Browser extension bridge (`src/browser/`, `pv-browser-host`) | Core flows implemented (status, pairing, matches, fill, save, lock, background save, startup unlock, `open-entry`, login update, OTP, structured fill). Passkey registration/assertion (including PRF) use a window prompt with credential choice and master-password reauthentication. Real browsers unverified; see `src/browser/README.md` |
| AI access (`src/ai/`, `pv-mcp`) | Local MCP + script mode with five tools (`search`, `get`, `get_secret`, `add`, `ask_user`), one-click pairing, default off, per-request secret approval (incl. device service paths/private commands), direct creation of new entries without approval (never edits existing data), audit without content, fixed socket path. Real AI clients unverified; see `src/ai/README.md` |
| Devices & services (`ui/devices/`, core `device` type) | Implemented behind an explicit format-7 upgrade with snapshot; symmetric sync carries format 7 to updated clients. Other clients' device UI not yet built; see `docs/architecture/DEVICE-ITEMS.md` |

Passing compilation or headless tests is not acceptance for Touch ID, the browser, devices,
or production security. See `docs/security/SECURITY_MODEL.md`.

The signed package reuses the macOS AppIcon asset catalog through `tool/macos-nsh/icon.sh`, which installs `AppIcon.icns` and its Info.plist reference before signing.

## macOS background service

The packaged UI connects to a separate Rust owner over a versioned Unix socket.
The embedded `PasswordVault Background.app` has its own bundle identity and is
built with `--no-default-features --features background-service --bin pv-background`,
without NSH/JavaScript. A per-vault user LaunchAgent starts on demand, with no
RunAtLoad/KeepAlive and no added login startup. Closing the last window saves drafts
before exiting the UI; a failed save retains it. Quit stops the owner too. Native
sleep/screen/idle locking, browser approval and relay transport belong to the service.
The existing browser protocol and storage identifiers remain unchanged.

SQLCipher contains rebuildable, individually sealed browser projections updated in
the same transaction as the canonical document. Domain matches/fills and settings
reads do not hydrate the whole document. Editing/import/sync may temporarily hydrate
it. A recent, live authenticated UI keeps that document warm for editing; locking
wipes it, and UI exit/crash or a five-second heartbeat timeout releases it. Browser
requests never renew the UI lease. Existing writers invalidate the
projection digest and cause rebuilding on the next unlock. Allocator cache controls
apply only to the service process; they do not reduce KDF memory or encryption.

Build the service, native helper and synthetic probe in `apps/desktop`:

```sh
cargo build --release --no-default-features --features background-service --bin pv-background --bin pv-browser-host --example service_probe
```

Then from the repository root:

```sh
python3 tool/test_background_service.py --launchd --memory
```

This signs disposable bundles under `/tmp`, uses fictional accounts and a synthetic
HOME, verifies real Native Messaging frames and wrong-peer rejection, restarts the
service locked, and unregisters its test agent. It never registers a real browser or
opens a daily vault. `tool/nsh_mac.sh test` separately enables the in-process fixture
adapter for explicit temporary vaults; those component tests do not prove IPC or
AppKit lifecycle behavior. The fixture adapter refuses paths outside `/tmp`.

Production security blockers in the local security model remain open. Physical
Touch ID, sleep and live browser consent need separate device acceptance. Memory
numbers from fixtures are measurements, not guarantees for a user's vault.

Synthetic macOS evidence (Apple Silicon; physical footprint, not RSS): after the
same small fixture was unlocked and its window closed, the retained build-26 UI
used about 44 MB after settling, versus 11 MB for the new background owner with its UI exited.
With 1,000 fictional accounts plus an 8 MB note, the service also settled around
11 MB after 50 queries. Transient unlock/import peaks are higher. Native QA verified
save failure retains the draft/window, successful close exits the UI, reopening
preserves the session, and Quit stops both processes. These are fixture results;
physical Touch ID/sleep and the owner's live browser remain unverified.

Explicit Quit persists a non-secret stop marker and disables in-flight UI polling
before stopping the service. Browser polling cannot restart it afterwards. Opening
the desktop UI clears that marker; closing only its window does not set it.

### Foreground responsiveness checks

UI native methods that use IPC run via `control_async` on blocking workers; timer
polling uses `pollEvery` to allow only one outstanding request and suppress late
results after disposal/lock. Warm requests use their real connection directly,
without an extra reachability connection. Peer UID/audit-token/code validation
stays enabled. Policy-status polling reads settings without listing vault contents.

```sh
node --test tool/test_ui_polling.mjs
python3 tool/test_background_service.py --launchd --latency --memory
```

The signed persistent-client benchmark reads a small note beside 1,000 accounts
and an unrelated 8 MB note. In the local comparison, repeated reads fell from
about 201 ms median to 22 ms, and the service returned to about 11 MB after the
frontend exited. A two-second native UI sample previously spent about 36% in
synchronous timer calls; the fixed engine sample contained no blocking IPC frames.
The optional `--service-binary` argument benchmarks a retained older service with
the same fixture/client. No real vault is used.
