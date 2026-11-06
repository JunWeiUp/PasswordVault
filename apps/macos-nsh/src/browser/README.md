# Preview browser bridge

The Rust `pv-browser-host` binary speaks the existing little-endian, length-prefixed
Native Messaging v2 protocol (`com.securepass.vault.native_v2`). The extension is
unchanged. `tool/macos-nsh/package.sh` builds, embeds and signs the helper separately
before signing the outer preview bundle, and copies the existing BrowserIdentity.
No build or startup operation registers hosts. The settings action explicitly
registers Chrome, Edge, Edge Beta or ego lite; replacing a shipping-app registration
requires the settings confirmation. Unregister refuses another app's manifest.

## Integration

- Import `BrowserPage` from `ui/browser` into Settings and map `browser` to it.
- Call `connectBrowser()` once after the store's first `Vault.command` has opened
  the shared session; retain its cleanup for UI teardown. It starts the socket and
  polls pairing requests. No second Vault instance is created.
- Call native `Browser.cancelStartup()` **before** every manual/system lock. It
  synchronizes with acceptance of a single-use startup nonce. Polling status cannot
  generate a startup challenge. After startup, refresh core status to reflect a
  successful native unlock. Browser-side lock similarly requires UI status refresh.
- Refresh the item list after browser writes (the page also provides a refresh action).

## Trust and storage

The socket is mode 0600 inside the exclusively locked vault directory. Both sides
verify the live peer audit token with Security.framework and compare its validated
code hash to the embedded helper/app. Desktop-only helper mode additionally checks
its signed parent. Browser input cannot submit native-only operations or grants.
Startup grants travel over the verified socket, never helper stdout.

Pairing reads legacy scalar tokens and per-extension token arrays. Approval carries
a request-specific challenge and expires after 35 seconds. The helper preserves
legacy Keychain service names, account derivation and JSON fields; old raw 64-byte
grants remain append-only. Keychain access is noninteractive and default ACLs trust
the creator executable. A signing identity/ACL change can require reauthorization;
this implementation never silently widens old ACLs. Revocation uses core epochs.
Revoking an extension also invalidates **all** background grants, since the existing
core epoch is vault-wide. Helper offline saves use the core append/receipt API.

## Scope and acceptance

Implemented: status, pair, matches, fill, save, lock, open, configure-sync,
disable-sync, disable-auto-unlock, sync-save, authorized matches/fill and desktop
startup unlock. Additional extension operations (`open-entry`, `update-login`, OTP,
structured details and passkeys) fail closed as unsupported in this preview; they
still need their native consent/navigation flows. This is not full SwiftUI parity.

Browser mode targets the isolated default `PasswordVaultNSHPreview/vault` directory.
Custom `--vault-directory` apps do not redirect browser-mode helpers: use synthetic
unit tests, never register a fixture over the user's real browser registration.
Desktop startup helper mode receives the selected directory only from its verified
parent. Offline queues live in extension IndexedDB, so the Mac page cannot enumerate
or directly merge them; the extension retries and removes only acknowledged entries.

Tests replay the request shapes used by `apps/browser/src/background.ts`, including
v2 token/syncToken envelopes, scope rejection, legacy data, locked polling, save/fill,
lost acknowledgements, epoch revocation and temporary registration directories.
Run from the repository root with a fresh copy of the synthetic seed:

```sh
PASSWORDVAULT_VAULT_DIRECTORY=/tmp/<fresh-copy>/vault bash tool/nsh_mac.sh check
PASSWORDVAULT_VAULT_DIRECTORY=/tmp/<fresh-copy>/vault bash tool/nsh_mac.sh test --filter browser
```

Current verification: `check` passed; nine Rust tests and one headless settings test
passed with `test --filter browser`. The packaging script passes `bash -n`; the
new helper packaging step itself has not been executed.

Real installed browsers, helper Keychain migration across signatures, signed positive
peer validation, physical login-Keychain locking, packaged cold-start unlock and
visual/VoiceOver acceptance remain unverified. Unit dispatch tests are not an
end-to-end browser/security acceptance result. No real host registrations or loaded
extension assets are modified by tests.
