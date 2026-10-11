# Browser offline saving

Current setup: [browser account access and optional Mac startup unlock](BROWSER-AUTHORIZATION.md) describes browser 2.2.9 / Mac 2.0.12. The 2.2.8 save-only flow below remains the compatibility/security baseline; old grants do not gain read or startup scope automatically.

## Background saving (browser 2.2.8 / Mac 2.0.11)

Install the matching Mac app and register the browser connection once in Settings → Browser. In the extension's **连接 Mac** mode, enter the existing Mac vault master password under **无需打开 Mac 即可保存** and choose **开启后台保存**. Setup and subsequent confirmed/manual saves do not open the Mac UI. Reading/filling existing accounts still uses normal pairing and desktop unlock. This is local extension-to-Mac account saving, not general two-way/cloud synchronization.

The helper verifies the password and keeps an append-only API capability in its login-Keychain entry; the browser never receives the vault root key or persists the master password. The capability persists until **关闭后台保存**, Mac's **撤销全部后台保存授权**, or a master-password change. Locking the vault UI intentionally leaves append permission in place. Login-Keychain locking, access denial or signing changes can prevent synchronization; retain the queued data and configure again if needed. See [security model](SECURITY_MODEL.md#background-save-authorization).

Saving starts immediately; failures retry while the browser is available. Empty queues have no sync alarm. The helper runs only for a native message and exits when the browser closes its input; it has no resident service, UI, WebView, note editor or browser WASM engine. With the app active, writes use its serialized core. With it quit, the helper briefly owns the same exclusive lock. A request acknowledged after a durable transaction is removed from the browser queue. Receipt IDs and encrypted records commit together, so interrupted/failed writes and lost acknowledgements can retry safely. Receipts survive item deletion, but are local database metadata rather than portable backup contents.

### Scoped measurements and verification

Measured using /usr/bin/time -l around one Debug native helper per request on the development Apple Silicon Mac, using disposable fixtures. Values are process peaks, not incremental whole-system/browser memory, and grow with vault size:

| Request | Maximum resident size | Peak memory footprint | Wall time |
| --- | --- | --- | --- |
| Save into small vault with desktop absent | about 17.6 MB | about 4.6 MB | 0.02–0.03 s |
| Save into 1,000-account synthetic vault | about 22.2 MB | about 9.2 MB | 0.03 s |
| Initial password authorization | about 82 MB | about 73 MB | 0.11–0.13 s |

Password authorization runs the existing Argon2 KDF; routine saves do not. Every measured helper exited after its request. This is not a guarantee for all database sizes or platforms.

Rust tests cover cold reopen, unchanged lock state, password changes, revoked/tampered grants, strict origins, exclusive ownership, exact/different credential cases, lost acknowledgements, deletion retries and transaction rollback on receipt failure. Swift tests use the real helper and login Keychain against isolated directories, including a running locked desktop and the populated fixture. Browser worker tests verify trusted UI configuration, no persisted master password, append-only delivery, stable retry IDs, acknowledgement handling, no native-mode WASM, and removal of idle alarms. The 380×600 real-DOM fixture checks wrong-password handling, configuration, revocation and overflow. These are separate helper/worker/DOM checks; full installed Chrome/Edge transport, macOS 13/Intel, signed-upgrade and physical Keychain lock/unlock remain acceptance gates.

Reproduce with the core/macos/browser modes of tool/check_native.sh, the full Swift test scheme (or only PasswordVaultTests/BackgroundSyncTests in Debug), and runBackgroundSync in apps/browser/tests/popup-scenarios.mjs.

## Existing offline queue


Browser 2.2.4 supports confirmed login/signup captures in native mode even before Mac is connected. Open the extension and choose **保存网页中的账号**, or use the reminder after submitting a login/signup form. Review and edit before saving. The popup reports the number of staged records.

The queue is separate from the independent master-password vault. It uses device-local AES-GCM encryption with a non-extractable CryptoKey in extension IndexedDB. It is not protected by a master password and does not resist an attacker controlling that browser profile/runtime; see [security model](SECURITY_MODEL.md). Do not uninstall the extension or clear browser extension data before synchronization.

When Mac is paired and unlocked, opening the popup or the one-minute background alarm retries synchronization. Failed records remain local. Exact username/password matches on the core's website scope are skipped to handle a lost acknowledgement; different passwords create separate records, preserving desktop data. An acknowledged record is removed locally. Without background-save authorization, no automatic pairing or unlock occurs. With authorization, the append-only path above also works while the main app is quit or locked. Independent-vault mode does not synchronize this queue.

Limits: 500 staged records; credentials must be nonempty and at most 4096 UTF-8 bytes each. Unconfirmed reminder candidates still expire after two minutes. Same-origin navigation is permitted; cross-origin save requests and page-origin access to queue APIs are rejected. Corrupt ciphertext fails closed, retains the record and reports incomplete sync; repair UI is not yet available.

Signup capture accepts one password or a password plus an explicitly identified, matching confirmation field (or two new-password fields). Current-password plus confirmation is rejected. Existing same-origin iframe and per-site reminder controls remain in force. Submission does not establish registration success: the user confirms success before saving. No real AIACC registration is performed by the tests.

Validation: `bash tool/check_native.sh browser`; `npm --prefix apps/browser run release:local` bumps/builds/checks/tests a local release. `tests/offline-queue.test.mjs` covers encryption, key non-extractability, restarts, failure retention and tampering; worker tests cover locked/unavailable capture and deduplicated retry. `tests/fixtures/signup.html` is a synthetic registration fixture modeled on AIACC. Native-host end-to-end and full browser/profile attack resistance are separate acceptance gates.
