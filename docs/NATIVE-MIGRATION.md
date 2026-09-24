# Native migration: implementation and acceptance

The chosen **Native Notes** design is implemented by the macOS client in `apps/macos`, using SwiftUI and a Rust core. It contains no Flutter or Electron runtime. Mac 2.0.9 build 13 includes a locally bundled Milkdown note editor hosted in WKWebView; the existing NSTextView evidence below is historical and is separate from the replacement's scoped acceptance. The Chromium extension and standalone Web UI in `apps/browser` use TypeScript/Preact and the same core compiled to WebAssembly. Native Android Compose and iOS SwiftUI preview clients are implemented; their device and release gates are documented separately. Legacy Flutter clients remain available during migration.

This is a developer build. It is **not** a completed all-platform replacement or an independently audited release. Keep the legacy clients until the remaining acceptance gates below pass.

## Build and launch

Install rustup, Rust **1.96.0**, Node.js **22.12+**, Xcode with macOS command-line tools, and XcodeGen. The repository pins Rust and JavaScript dependencies. The scripts explicitly select the rustup compiler: a separate Homebrew `cargo`/`rustc` earlier in `PATH` can otherwise build against the wrong target or deployment version.

```bash
rustup toolchain install 1.96.0 --profile minimal --component rustfmt,clippy \
  --target aarch64-apple-darwin,x86_64-apple-darwin,wasm32-unknown-unknown
export PATH="$(dirname "$(rustup which --toolchain 1.96.0 rustc)"):$PATH"
cargo install wasm-bindgen-cli --version 0.2.128 --locked
brew install xcodegen

bash tool/check_native.sh core
bash tool/check_native.sh macos
bash tool/check_native.sh browser
open apps/macos/build/Build/Products/Release/PasswordVault.app
```

The Mac build produces a universal arm64/x86_64 app with a macOS 13 deployment target, an embedded signed native-messaging helper, and the existing PasswordVault icon. Local builds use ad-hoc signing; public distribution still needs Developer ID signing and notarization. Intel compilation does not establish Intel hardware acceptance. Touch ID requires supported hardware and a working Keychain signing/access setup.

For Swift state/model tests:

```bash
xcodebuild -project apps/macos/PasswordVault.xcodeproj -scheme PasswordVault \
  -configuration Debug -derivedDataPath apps/macos/build \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 test
```

The Xcode test host uses an isolated temporary directory. To manually test with synthetic notes, create a **new empty** temporary folder and run the seed example; it refuses to overwrite an existing vault. The example's disposable password is in its source. Use a short `/tmp/` path for native-bridge testing because Unix-domain socket paths are limited in length.

```bash
cargo run -p vault-core --example seed_demo -- /tmp/passwordvault-demo
open -n apps/macos/build/Build/Products/Release/PasswordVault.app \
  --args --vault-directory /tmp/passwordvault-demo
```

Normal data lives in the user's Application Support `PasswordVaultNative` directory, separate from all legacy databases. Never use a real vault for a test or copy the seeded directory into the normal data location.

For builds that must not replace a running development app, set `PASSWORDVAULT_DERIVED_DATA` to a separate ignored output directory when running `tool/check_native.sh macos`.

## Current note editor: Milkdown

The replacement keeps the SwiftUI workspace and existing Rust-backed encrypted save/recovery path. Assets and licenses are bundled locally, with a nonpersistent WebView and no network resources. The 57-test Mac suite and isolated-window observations cover lists, caret/history, simulated Chinese composition, source/lock handover, read-only rejection and content boundaries. See [scoped evidence and remaining gates](MARKDOWN-EDITOR-EVALUATION.md). Physical IME, process-termination recovery and older/Intel hardware remain unverified.

## Historical Mac 2.0.6 continuous note editing

This section records the earlier NSTextView implementation and its acceptance, before the later rendered projection and current Milkdown work.

Preview now uses one native NSTextView for the entire note, with source-preserving reading styles and a plain Source alternative. Command-Z / Shift-Command-Z and the native Edit menu route to a private per-note undo manager. Restyling and encrypted autosave do not add undo steps. Undo/redo publish their final text back into the save queue; leaving the editor clears its undo history. Formatting pauses during marked-text composition. Links remain available through the native context menu without turning a normal text click into navigation.

All 32 Swift tests passed, including Unicode/selection preservation, cross-paragraph replacement and undo/redo, marked-text preservation, and immediate-lock saving. Isolated Mac UI checks passed for direct text editing, native shortcut undo/redo after autosave, newline input followed by immediate lock/reopen, switching notes without cross-note undo, and 35-paragraph end-of-document editing with one outer scrollbar. Full third-party input-method and VoiceOver acceptance remain separate. Synthetic data only; normal vault contents were not used for acceptance.

## Historical Mac 2.0.5 idle and preview acceptance

The encrypted `settings.macNeverIdleLock` Boolean disables only the Mac idle timer. Keep the shared `autoLockMinutes` numeric setting intact: other clients do not interpret zero consistently. Selecting a finite Mac timeout clears the Boolean. Manual lock and existing screen-lock/sleep observers remain active.

In this historical increment, note preview used a native multiline editor for the active paragraph and preserved Markdown source through the encrypted debounce/recovery path. That paragraph editor was subsequently replaced. Editable titles retained the note format; both preview and full editing checked shared-note permissions, and Trash remained read-only. The idle-lock setting described above remains applicable.

Mac build 9 passed 29 Swift tests, including Never persistence/re-enabling the timeout and preview changes followed immediately by locking/reopening. A separate synthetic-vault app was used to verify the visible Never option, Chinese multiline keyboard input, switching to the correct following paragraph, and persisted content after lock/unlock. SignedRelease built successfully and the installed replacement retained its signing identity. No real vault was used for acceptance. Physical sleep/wake, fresh Touch ID authentication, macOS 13/Intel and a full VoiceOver pass were not repeated for this increment.

## Mac sidebar categories

Use **+** beside Notes to create a category, including an empty one. Select a category and use **−**, or right-click it and choose Delete category, to remove it while preserving the notes. The default All notes view cannot be deleted. Empty categories are encrypted alongside the document and included in encrypted backups. Deleting a category first flushes pending edits, then atomically removes its references from active and trashed notes; shared-note edit permissions still apply. Click anywhere on the Tools row to expand or collapse its destinations.

## Chrome / Edge and standalone Web

1. Build `apps/browser/dist` with the command above.
2. Load that directory as an unpacked extension through Chrome/Edge's extension developer page.
3. In the Mac app, choose **Settings → Browser → Register Chrome / Edge connection** (also registers Edge Beta). Keep the app at that path after registration, or register again after moving it.
4. In the extension choose **Connect to Mac**, then confirm its pairing request in the Mac app. Saved-account rows open the matching record in Mac; a separate **Fill** button fills the webpage. The extension can also save an explicitly reviewed page credential or lock the vault. Account navigation transmits only identifiers and origin, not a credential payload.
5. Alternatively choose **Independent vault**. It has separate encrypted browser storage and does not copy the Mac vault. Open **Manage vault** for notes, accounts, codes, wallet records, backup/import, generator, audit, and settings.

For standalone Web, serve `apps/browser/dist` with an HTTP server on loopback or use HTTPS when hosting it. `file://` is unsupported. Extension APIs are used only on extension pages. The web build does not need the native helper.

Manual Fill/Read uses a top-frame script on demand. Login reminders now run by default on all HTTP/HTTPS websites, with host permissions and small origin-guarded login listeners declared in the manifest. The popup can turn reminders off for one exact origin; the exception persists and applies to open tabs. Save detection handles validated form submission and explicit login gestures in bounded form-less panels, including same-origin iframes. Field tracking remembers dynamically mounted and revealed passwords without polling for credentials. Only the main document displays notices, and a shallow root observer repairs a pending notice after page replacement. The worker checks browser-owned tab origins and obtains matching account counts; the icon shows that count (capped at `99+`), `0` on a password form with no saved accounts, or `+` for a pending login. An observed lock clears these badges. There are no remote fonts, favicon fetches, Flutter engine, or CanvasKit. The MV3 service worker uses static JavaScript imports and initializes WASM only for independent mode. Password bootstrap runs in a disposable Worker. Closing that worker releases its KDF allocation; browser worker eviction locks an independent vault. The complete package has an 8 MiB build budget; the release build reports the measured package size. Package size is **not** a process-memory benchmark; memory parity against the old extension remains an acceptance gate, including after backup/import and password changes.

Missing/forbidden native-host registration is separate from a reachable locked Mac. Both extension surfaces offer connection instructions and retry. Native status verifies the pairing capability while unlocked; revoked capabilities are discarded so pairing can be requested again. Locking alone preserves the saved capability. Older native builds remain compatible through an operation-level authorization check. Polling pauses during user actions, including the Mac pairing dialog. Captured URLs retain their full address, while account matching intentionally ignores ports for an exact hostname. For example, a record saved at http://127.0.0.1 matches http://127.0.0.1:4387. Subdomains and unrelated hosts remain separate, and HTTPS records are not offered to HTTP pages. Navigation checks still use the actual origin so a page cannot silently change destinations during a fill.

Browser vault writes use an IndexedDB compare-and-swap transaction so two tabs cannot overwrite each other's newer encrypted bundle. A conflicting tab must unlock again. Neither the master password nor an unlocked root key is persisted in browser storage. The native pairing token is a revocable capability and is stored separately in extension storage.

## Implemented paths and remaining parity

| Area | Implemented native capability | Remaining work or acceptance |
| --- | --- | --- |
| Mac interface | Three columns, categories, search, Chinese/English, light/dark, notes, Markdown editing/preview, favorites, pins, trash, keyboard shortcuts | Scoped Milkdown acceptance recorded; physical input methods, broader accessibility and macOS 13/Intel device passes remain open |
| Accounts | Direct creation and in-place editing, main/additional credentials and histories, email/domains/expiry, linked TOTP, shared metadata, copy/generation and health audit | Broader website, device and accessibility acceptance; see [Mac field parity](MAC-MOBILE-PARITY.md) |
| Codes | SHA-1 / 6-digit TOTP, period preservation, strict otpauth import, Mac image/camera QR review | Physical camera permission/denial flows; browser QR UI |
| Wallets | Existing ETH/EVM BIP39 generation and BIP44 derivation, address/private-key/mnemonic records | More device fixtures; no signing or transactions |
| Native storage | SQLCipher plus authenticated document encryption, root wrapping, lock/idle/sleep/session lock, password changes, encrypted recovery drafts | Independent review; physical sleep/wake and Touch ID enrollment/biometry changes |
| Backups | V2 randomized encrypted writes, old SHA-256/Argon2 readers, CSV/JSON, explicit plaintext export, Mac/mobile WebDAV and supported mobile SQLite migration | Real server coverage; automatic legacy desktop SQLite/Web OPFS discovery and remaining migration formats |
| Sharing | V2 authenticated packets, pinned peer identity, role checks, replay window, owner member revocation, Mac discovery/invites | Multi-device network test, owner/key rotation and conflict UX; legacy client interoperability requires upgrade |
| Extension | Native pairing; exact-hostname matching, same-origin iframe menus/reminders, editable save review, multi-account fill and Mac navigation; independent encrypted vault | Google Chrome UI, broader site coverage and full process/GPU memory comparison. Scoped Edge/ego/helper results are recorded in [browser acceptance](BROWSER-ACCEPTANCE.md) |
| Standalone Web | CRUD, TOTP, backup/import, generator/audit, lock, encryption | WebDAV/sharing/QR UI and complete bilingual/theme parity |
| Mobile | Android Compose and iOS SwiftUI previews; platform Autofill, encrypted lifecycle, backup/WebDAV, sharing and supported legacy SQLite migration | Hardware/older-OS/accessibility, eligible iOS signing and original-key upgrades; see [mobile acceptance](MOBILE-IMPLEMENTATION.md). Legacy Flutter remains available |

Shared records retain deletion tombstones in Trash for synchronization; permanent deletion of shared entries is currently rejected. Revocation stops future owner exchanges, but cannot erase copies that a former member already received. Do not advertise remote erasure or retrospective revocation.

## Validation evidence

- Rust tests exercise encrypted disk canaries, wrong passwords/keys, lock denial, KDF bounds, altered backups, legacy imports, atomic malformed import, password rotation, exclusive process ownership, TOTP vectors, site boundaries, encrypted draft recovery, sharing roles/replay/revocation, identity restoration, multi-account/exact-host boundaries, and a public ETH development vector.
- Swift tests preserve unknown fields, reject insecure/traversing WebDAV settings, scope Keychain accounts by vault directory, and verify the latest rapid note edit survives lock/unlock.
- Browser worker tests reject untrusted senders, derive origins from browser-owned tab state, reject stale navigation, and confirm that native mode does not instantiate/fetch WASM. Browser tests use the actual WASM build for encrypted storage/unlock/tamper, legacy records, password changes, domain checks, and persistence rollback. IndexedDB tests reject concurrent stale writes. A package test enforces MV3 constraints.
- Connection regression tests cover missing/forbidden hosts, locking without revocation, revoked tokens, cancelled pairing, and successful re-pairing. Swift tests additionally verify pairing-token rejection and preserve captured website ports while rejecting non-origin URLs.
- A real-DOM synthetic fixture passed all nine fill/capture checks, including native input/change events, same-form selection, hidden/read-only fields, duplicate injection, sender/origin rejection, and no automatic form submission. Reproduce with `python3 -m http.server 4387 --bind 127.0.0.1 --directory apps/browser`, open `/tests/fixtures/page-integration.html`, and click its test button after building the extension. Open the fixture through HTTP, not by double-clicking its HTML file: the production content script intentionally rejects file URLs. The fixture now disables checks and explains the setup in file mode, instead of reporting misleading partial results. It mocks extension messaging and uses only fictional credentials; it does not validate Chrome/Edge transport or native pairing.
- Signed native-helper integration was exercised against a disposable fixture: app-approved pairing, account match/fill, rejected tokens/origins/unsupported operations, locked-vault denial, and unsigned socket-client rejection. Reproduce with an unlocked Debug `seed_demo` fixture using `python3 tool/smoke_native_bridge.py --fixture-dir /tmp/passwordvault-demo`; the script refuses directories without the synthetic marker and never prints tokens/passwords. This is helper protocol evidence, not a Chrome UI fill test.
- Local GUI checks use only synthetic data. In ego lite, the installed MV3 extension and an independent encrypted test vault completed login submission → reminder → extension confirmation → save → clear form → fill, with no automatic form submission. Repeated saved credentials suppressed the reminder; disabling/re-enabling a site, lock feedback, and icon badge transitions `1 → + → 2`, zero-account password forms (`0`), and account counts on pages without forms were verified. This is real extension UI evidence for independent mode, not native Mac pairing acceptance or a runtime memory benchmark.

Public protocol references: [UniFFI](https://mozilla.github.io/uniffi-rs/latest/), [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [wasm-bindgen](https://wasm-bindgen.github.io/wasm-bindgen/), [BIP32 implementation](https://docs.rs/bip32/0.5.3/bip32/), and [EIP-55](https://eips.ethereum.org/EIPS/eip-55). These explain API/format choices; they are not an audit of this project.

### Login submission reminders

Login reminders are enabled by default after installation/update permissions are granted. Use **Turn off login reminders for this site** in the popup to add a persistent exception, or enable it again there. A validated form submission or explicit login action in an unambiguous form-less panel can trigger a page banner and a `+` badge, including in same-origin frames. Only the top document shows the banner. **Review and save** opens the extension popup, falling back to an extension confirmation tab in Chromium shells that cannot open action popups. This tab remains bound to the originating browser tab, including for capture/fill. The user can edit the captured account/password, reveal or conceal the password, then explicitly save or cancel. Detecting a submission does not establish that the website accepted the login. Already-saved matching username/password pairs are suppressed. Turning off a site stops accepting submissions from that origin; matching-account badges remain available.

When updating an unpacked extension, reload it from the browser extension page as well as turning it off/on if its manifest permissions changed. Disabling and enabling alone may retain the old permission declaration. Refresh existing website tabs to load the new content script.

Pending credentials exist only in service-worker memory for up to two minutes; they are never placed in browser storage. Dismissal, successful save, observed lock/revocation, mode changes, cross-origin navigation, tab closure, permission removal, or worker eviction discard them. Expiry is also checked before returning data. Same-origin redirects retain pending data while the worker stays alive. Page messages receive only reminder status; credentials are returned only to the trusted extension popup after verifying the vault remains accessible. Background checks derive page origins and tabs from browser sender state, not payload fields. Cross-origin frames, closed shadow roots and ambiguous panels remain outside automatic detection; use manual entry or an accessible top-frame login form. Worker eviction discards pending data and cannot preserve a capture for later review. See [the versioned browser matrix](BROWSER-ACCEPTANCE.md) for the distinction between real extension, signed-helper and mocked-bridge evidence.

### Manual browser login fixture

With the same local HTTP server, open `http://127.0.0.1:4387/tests/fixtures/login.html` in Edge or Chrome. The fictional “晴空笔记” page offers personal/work samples, simulated login, logout, and clearing fields for another fill attempt. It keeps fields visible after login so the extension can read them via **Save account from page**. This page neither mocks extension APIs nor loads the content script; it uses the installed extension for capture/fill. It accepts any nonblank fictional username and a test password of at least eight characters; it is not an authentication service and sends/persists no credentials. Use the matching updated native build to preserve the local server's custom port when saving accounts.

### Mac interaction verification

The native WebDAV list requests metadata in one PROPFIND, without downloading each backup. Successful per-file properties, missing metadata, invalid sizes/dates, namespace prefixes, folder/origin boundaries, and sorting have dedicated tests. Swift interaction tests cover immediate entry creation, encrypted autosave, Trash search/restoration, pending-edit export/import, real filesystem write failure and retry, cross-record saving, settings rollback, and permanent deletion across lock/reopen. Historical modal-draft checks do not describe the current in-place Mac creation flow.

Synthetic native-window verification includes local mock WebDAV upload/download/merge, wrong-passphrase recovery, connection errors, empty folders, and dark/narrow-window layout. See [interaction review](design/macos-native/INTERACTION-AUDIT.md). This does not certify real server compatibility, VoiceOver, Touch ID hardware, or production security.

### Restoring legacy WebDAV JSON

Use **Restore…** beside `backup_enc_*.json`, then enter the **legacy master password used when that backup was created**. It is unrelated to the WebDAV login password or a new native backup passphrase. Legacy passwords shorter than ten characters are accepted for restore; new backup password requirements are unchanged. A filename only selects helpful guidance—the core validates the actual format.

Legacy salt-bearing WebDAV (1.3), fixed-salt manual (2.0), and SHA-256 manual (3.0) backups are covered by independent Dart-generated synthetic fixtures. See `crates/vault-core/tests/fixtures/legacy/README.md`. A very old device-key-only backup without its original salt/key may require exporting again from the old app; a new native password cannot recreate an unavailable legacy key. Real user backups were not downloaded or decrypted during these compatibility tests.

### Local developer build 2.0.3

The browser footer and extension manifest identify version 2.0.3. Its shared Rust core matches accounts by exact hostname across ports in native and WASM builds. Vite module preloads are disabled for extension pages to avoid Chromium cross-world resource mismatch warnings. Rebuild/update both the Mac application and browser extension when changing shared core matching behavior; updating extension JavaScript alone does not replace the native core.


### Multiple browser connections and navigation checks

The Mac stores an array of pairing capabilities per approved extension identity, preserving legacy single-token entries. Pairing Edge, ego lite, or another browser profile adds a connection; rotating one capability does not invalidate the others. Capacity errors reject the new request without evicting existing clients. Revoke-all still invalidates every connection. Swift regression tests cover legacy migration, persistence, rotation, capacity, and revocation.

Real ego lite checks with fictional accounts in an independent vault passed immediate same-origin redirect and save, delayed redirect, opening the confirmation before navigation, dismissal followed by navigation, confirmation cancellation followed by reload, and cross-host redirect cancellation. The destination fixture has no password input. The extension Errors view remained empty. Pending credentials remain memory-only with a two-minute lifetime; a browser/service-worker restart can discard them. Cross-origin navigation deliberately cancels pending capture even though saved accounts match by hostname across ports.

### Touch ID signing

Ad-hoc builds cannot enroll a credential in the Data Protection Keychain on the tested Mac: LocalAuthentication reports available/enrolled biometrics, while a synthetic enrollment returns `errSecMissingEntitlement` (-34018). Do not work around this by moving the unlock key to a plaintext file or by weakening biometric access control.

`SignedRelease` is the Apple Development signing configuration. Set the intended development team in Xcode, enable automatic signing for `com.securepass.vault.macos`, and provision the application's private Keychain group using `Keychain.entitlements`. The matching macOS provisioning profile and signing identity must be available. The repository does not embed a personal/company team ID or provisioning profile. Public distribution requires its own Developer ID signing/notarization process.

Enrollment reports missing signing entitlement, unavailable biometrics, missing fingerprints, lockout, cancellation, and expired credentials separately. Duplicate enrollment updates the protected key and propagates update failure; it cannot silently report success with a stale credential. A Personal Team signed build has now passed a synthetic Data Protection Keychain enrollment on the test Mac. Reading the synthetic credential without authentication was denied with `errSecInteractionNotAllowed`, and the test credential was removed. The signed app was installed without changing the vault. The user confirmed successful fingerprint unlock with the installed Personal Team build. Biometric-set-change and other physical failure paths remain separate hardware checks.

### Extension update versions

For each delivered extension update run `npm --prefix apps/browser run release:local`. It increments the patch version in package metadata and the lockfile, then checks, builds and tests. The generated manifest and visible popup footer use that same version. A retry of the same release may use `npm run build` without another increment. Copy the unpacked build to the user's installed directory, reload the extension, and verify the running version; changing files alone does not reload a service worker.


For local automatic signing, place the intended `DEVELOPMENT_TEAM` in `apps/macos/Signing.local.xcconfig` (ignored by Git), then build:

```sh
xcodebuild -project apps/macos/PasswordVault.xcodeproj -scheme PasswordVault \
  -configuration SignedRelease -xcconfig apps/macos/Signing.local.xcconfig \
  -derivedDataPath native-test-output/personal-signed-build \
  -destination 'platform=macOS,arch=arm64' \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

The generated Personal Team profile in this validation has a seven-day lifetime; plan to re-provision development builds when required. Keep private keys, certificates, `.mobileprovision`/`.provisionprofile` files, local signing configuration, Xcode user data, and build logs out of Git. `Keychain.entitlements` remains a portable source template and contains no personal team identifier or credential.


### Closing and reopening the Mac window

Closing the red window control leaves the app, idle-lock timer and native browser bridge running. Reopening the app restores access to the window without creating a second bridge listener. Explicit Quit / Command-Q still flushes pending edits, locks the vault and terminates. The primary scene uses `WindowGroup`, since a primary SwiftUI `Window` exits on close ([Apple documentation](https://developer.apple.com/documentation/swiftui/window)).

Mac 2.0.3 build 5 passed 25 Swift tests including repeated window startup retaining the bridge socket. Local UI verification confirmed that the process and signed-helper status survive closing the window, the window reopens, and Command-Q exits. The browser package was unchanged at 2.0.3.


### Local build 2.0.4: navigation reminders, idle lock and deletion

The old reminder could disappear when a single-page site replaced the document root after a delayed login. The new observer restores its own banner after root replacement, uses a manual popover top layer where supported, and disconnects its shallow root observers on dismissal/expiry. The worker announces credential-free pending metadata after capture and on same-origin URL/load completion; each notice keeps the original expiry. Cross-origin navigation still cancels capture. No secret is written to page storage to survive navigation.

Real ego lite checks reproduced the disappearing banner on 2.0.3 and verified the same two-second SPA scenario on 2.0.4, as well as full-page delayed navigation, decline then reload, confirmation/save after redirect, cross-host cancellation, and an empty extension Errors view. The fixture now includes a two-second SPA root-replacement option.

New vault defaults and UI fallbacks use 60 minutes; existing configured values remain user-controlled, with a new 1-hour picker option. The browser idle detector also uses one hour. A successful authenticated native fill/save refreshes Mac activity; background matching/status polling does not. System lock/sleep and explicit locking still lock immediately. The user-requested current Mac vault was set to 1 hour through the settings UI.

All entry detail types show Delete directly. Active entries move to Trash after confirmation and can be restored; trashed entries expose a separate permanent-delete confirmation. Synthetic tests cover notes, passwords, TOTP and wallets. The visible note confirmation was checked and cancelled against the installed app; no real item was deleted during QA.

Disk encryption remains active while the UI is unlocked: SQLCipher protects the database, authenticated document encryption protects the entire serialized document, and recovery drafts are sealed before file writes. A regression test scans all files in a disposable live vault for note/password/TOTP/wallet/settings/draft canaries and rejects unkeyed database reads. Displaying or filling data necessarily decrypts it in memory; encryption at rest does not protect against malware controlling an unlocked process. Explicit plaintext exports remain plaintext and are not the normal storage path.

Validation: 20 Rust tests plus clippy, 27 Swift tests, and 19 browser tests passed. Both native and WASM core builds were refreshed; the installed Mac is Personal Team signed version 2.0.4 build 6, and both browser extensions were reloaded from the existing unpacked directory.


Mac 2.0.4 build 7 adds the same deletion flow to each middle-column row's context menu. Right-clicking an unselected row targets that row, with its title shown before confirmation. Active records move to Trash; Trash rows offer Restore and separately confirmed permanent deletion. The extension package is unchanged.


### Menu regression and next acceptance increment

Mac 2.0.4 build 8 fixes inherited primitive button styles in row/category context menus and the detail overflow menu. The previous build reproduced disabled Favorite/Pin/Delete actions in an isolated synthetic vault. The replacement completed Favorite → Unfavorite label, Pin → Unpin label, deleting an unselected named row after confirmation, and restoring it through the Trash context menu. Category and overflow menu actions were enabled. The installed app retains Personal Team signing.

In the following acceptance increment, the installed extension in both Edge and ego lite used native Mac mode to fill a fictional localhost username and a nonempty password without submitting the form. Existing connections survived the Mac update. This is real browser/native UI evidence for those two browsers, not a claim that the Google Chrome UI has been tested. See the [browser acceptance baseline](BROWSER-ACCEPTANCE.md) for the scoped memory measurements.


### Mac 2.0.7: direct creation and rendered editing

Mac build 11 removes the creation/edit sheet and brings account/authenticator/wallet details to native mobile field coverage. Notes use a rendered-to-source mapping with hidden Markdown syntax and source-based undo. See [field parity and scoped acceptance](MAC-MOBILE-PARITY.md) for the 46-test baseline, synthetic UI evidence and unsupported Markdown dialect boundaries. Native/universal builds and Personal Team signing preserve existing identifiers and storage. Browser remains at 2.0.7 without a code change in this increment.


### Browser-to-Mac record navigation

Mac 2.0.8 build 12 adds authenticated `open-entry` to the native bridge. Browser 2.0.9 exposes it through saved-account rows while retaining a dedicated Fill button. No credential payload is needed for navigation. See [the scoped browser/Mac acceptance](BROWSER-ACCEPTANCE.md) for lifecycle, matching and window restoration evidence.
