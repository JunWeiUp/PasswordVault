# Security model and release blockers

Status: developer preview. This document records a source review, not a penetration test or an independent audit.

## Native V2 increment

The new clients in `apps/` use `crates/vault-core`, separate from the legacy mechanisms below. Native storage requires SQLCipher and an authenticated encrypted document. Browser IndexedDB stores an authenticated ciphertext bundle. Argon2id (64 MiB, 3 passes, 1 lane, random salt) wraps a random root; versioned random-salt backups replace weak legacy writes. Header replacement changes the master password without rewriting the root or sharing identity. Lock releases the active key, and optional Mac Keychain access uses biometryCurrentSet/ThisDeviceOnly access control scoped to the vault directory. This code path does not persist a master password.

V2 sharing binds peer, recipient, vault, request/response, time and replay ID to authenticated messages. Authorization comes from the local roster, not packet claims. Revocation prevents subsequent owner exchanges but cannot retract a previously shared copy. The native extension bridge validates its helper's code identity, uses a private socket, a fixed extension allowlist and revocable pairing capability, and exposes a narrow site-scoped command set. Manual fill/read content scripts are injected only for user actions; default-on login reminders use a top-frame submit listener and HTTP/HTTPS host permissions, with persistent per-origin disable exceptions. Account matching uses exact hostnames across ports as requested; different subdomains remain isolated, and saved HTTPS entries are not offered on HTTP. In-flight navigation checks still bind fills to the actual origin. Icon counts require a matching-account lookup; page scripts receive status only, not vault credentials. While a reminder is pending, shallow root observers restore its UI after SPA replacement; only opaque ID/origin/expiry metadata is re-announced across same-origin navigation. Pending credentials remain in worker memory for at most two minutes and are exposed only to trusted extension UI after a vault-access check. Detection does not automatically save or prove login success. Manual fill/read requests likewise do not retain captured credentials in persistent storage.

The Mac rich editor uses pinned local Tiptap/ProseMirror in a nonpersistent WKWebView, with no network or key access. Configuration sequence/revision checks precede changes to editability. Native session-bound `pvnote://` image requests require an unlocked matching note session. Attachment bytes are domain-separated AES-GCM ciphertext in SQLCipher; names, summaries, originals and drafts are encrypted. V3 archives authenticate the manifest and all files before transactional restore. Lock hides and destroys the document and invalidates resource tasks; it does not guarantee complete Swift/JavaScript/WebKit memory zeroization. Explicit attachment/Markdown exports are plaintext. See [rich-note boundaries and migration](RICH-NOTES.md).

Tests provide evidence for storage/migration/error boundaries, **not independent audit closure**. Personal Team signed fingerprint unlock was confirmed by the user. Every record kind, settings and sealed recovery drafts were checked for plaintext leakage while a synthetic vault remained unlocked. Remaining V2 gates: biometric-set-change/failure paths and broader lock lifecycle, Mac 13/Intel, real WebDAV/LAN multi-device tests, remaining native-messaging/Chrome acceptance, automatic desktop SQLite/Web OPFS discovery and migration, signing/notarization, and adversarial review. Swift/JavaScript copies cannot guarantee complete memory erasure; malware on an unlocked device can read secrets. See [native evidence](NATIVE-MIGRATION.md#validation-evidence).

## Legacy design

Secret vault fields use AES-256-GCM. Normal vault keys use Argon2id with 32 MiB memory, two iterations, one lane, and a stored salt. Sharing code uses X25519, HKDF-SHA256, and AES-GCM. Metadata is not necessarily encrypted.

The platform storage wrapper uses Android/iOS secure storage on native devices and SharedPreferences on Web. The current master-password provider persists the password itself and caches derived keys. On Web this defeats an at-rest protection claim against someone who can read browser storage. Native secure storage does not by itself prove that every read is gated by biometrics.

## Legacy and project-wide production blockers

| Finding | Source area | Required evidence before closing |
| --- | --- | --- |
| Signing keystore and credentials entered Git history | Historical Android signing files | All refs scanned after removal; old key rotated; release continuity decided |
| Master password persists, including browser storage | `master_key_provider.dart`, `secure_storage_service.dart` | Tested verifier-based unlock, migration, lock/expiry behavior, and key-lifetime review |
| Master-password changes call setup without transactional vault re-encryption | Settings and master-password provider | Round-trip tests for every item type, history, shared keys, and failure rollback |
| Legacy SHA-256 password derivation remains in encrypted backup paths | Encryption service, import/export, backup provider | Versioned KDF envelope for new writes and compatibility/tamper tests |
| LAN sharing uses custom HTTP endpoints and authorization logic | `local_sync_service.dart` | Threat-model review and negative authentication, replay, CORS, and membership tests |
| Browser extension stores metadata and pending credentials | Worker/content scripts | Storage/message-boundary review, expiry tests, real browser verification |

These are concrete reasons to use synthetic credentials for now. Do not describe the project as zero-knowledge, audited, production-safe, or guaranteeing that it never stores a master password.

## Limits and recovery

- CSV/JSON exports may be plaintext. Encryption options do not protect a plaintext export already copied elsewhere.
- Lost passwords, browser profile deletion, extension identity changes, and broken migrations can cause loss of access. Test backups and restoration before relying on a build.
- Key rotation cannot revoke data a former member already downloaded.
- Malware or a compromised browser/device can observe secrets while unlocked.
- Favicon requests and local network discovery expose metadata; see [PRIVACY.md](../PRIVACY.md).

Report newly found vulnerabilities through [SECURITY.md](../SECURITY.md). Update this document with test and review evidence as blockers are resolved.

### Native-mode browser offline staging

Confirmed offline captures use AES-256-GCM with a fresh 96-bit nonce and record ID as authenticated additional data. Ciphertext and a non-extractable CryptoKey reside in extension-origin IndexedDB. This prevents plaintext credential storage, but **does not provide master-password protection**: an attacker controlling the browser profile, extension runtime or OS may use the local key. Non-extractability is not hardware protection. Locking the desktop does not disable collection of new user-confirmed captures. Existing desktop secrets remain inaccessible while locked. Unconfirmed candidates remain memory-only with a two-minute expiry. Staged records survive restarts until acknowledged by the paired/unlocked desktop or the explicitly authorized background-save path; uninstalling the extension or clearing its site data loses unsynced records. No production-security acceptance is implied.


### Background save authorization

Browser 2.2.8 / Mac 2.0.11 provides opt-in append permission independently of the UI lock. The trusted extension UI sends the master password once over Native Messaging to the identity-checked helper. The helper verifies the existing encrypted header and stores a native capability containing root material and a header/revocation fingerprint in the local **login Keychain**, with an explicit trusted-helper application ACL. The helper disables login-Keychain user interaction for its process, so denied/locked access returns an error rather than opening a system dialog. The ACL uses Apple's [SecAccessCreate](https://developer.apple.com/documentation/security/secaccesscreate(_:_:_:)) API. This is not the biometric/Data Protection Keychain path and is not iCloud synchronization. The browser receives neither root material nor a reusable master password; its random 256-bit token selects a helper-owned Keychain entry scoped to vault path and extension identity.

The native grant necessarily contains enough material to decrypt the vault. Its append-only restriction is enforced by native code, not by cryptographic write-only keys. Compromise of the helper, OS or its Keychain grant can expose existing data. Locking the vault UI or screen is not revocation of this explicitly persistent save capability, and a login Keychain can remain unlocked while the screen is locked. Reads/fills still require the normal unlocked, paired desktop. Disable background saving in the extension, revoke all in Mac settings, or change the master password to invalidate future background requests. Already accepted in-flight writes may finish. Invalid grants are removed when the helper next reads them; inaccessible old-signature Keychain entries may require manual cleanup. Revocation cannot erase previously copied root material.

The helper removes browser-supplied native grant fields, permits only narrow append requests, and forwards root material only over the existing signed-peer local socket when the desktop owns the database. Rust rechecks the current header/revocation fingerprint under its session mutex. File locking prevents a second writer; record mutation and idempotency receipt commit in one SQLCipher transaction. Configuring this capability does not unlock the UI, expose general core commands, weaken Argon2, or change the legacy data format. Scoped tests and memory measurements are in [background saving](BROWSER-OFFLINE-SAVE.md); independent review and platform acceptance remain open.


### Explicit browser reads and startup unlock

Browser 2.2.9 / Mac 2.0.12 adds separately declared scopes to the protected native authorization envelope. Old save-only grants remain save-only; enabling site-account reads or startup unlock requires password verification and visible UI consent. The native helper gates read requests to matches/fill, revalidates the grant against current header/revocation state and uses the exclusive/serialized core session. Temporary reads preserve desktop lock state. Password reveal additionally validates trusted extension UI and current browser-owned origin before and after retrieval; it clears on blur/navigation/timeout, and browser session locking denies further reads until reauthorization.

A cold-start unlock requires a helper launched by the signed desktop executable plus the AppStore's pending single-use nonce. The helper sends no root material on stdout; the signed-peer socket carries it to the pending app instance only. Browser-origin requests, stale/replayed challenges, revoked grants and lock races fail closed. A missing grant leaves normal password entry usable. Window reopening and status polling cannot repeat startup unlock.

The startup option is persistent: a later full app restart may unlock again even after an earlier manual lock. It does not promise a new OS authentication ceremony; a login Keychain can remain unlocked across screen locking. Disable startup unlock or revoke the authorization to require password entry on later launches. The newest opted-in plugin is the startup source; disabling that source leaves other read/save grants intact. Root-bearing grants remain sensitive native secrets; these scope restrictions do not protect against a compromised OS/helper. [Full behavior and scoped evidence](BROWSER-AUTHORIZATION.md).

## Personal relay boundary

Opt-in synchronization upgrades the local document to format 4 after an encrypted snapshot. Pairing pins device keys, the Mac explicitly authorizes a single-use invitation, and business commits precede ACK. Server tokens are not vault keys. Metadata, static-key forward-secrecy limits and separate release/security gates remain. See [personal relay](PERSONAL-RELAY.md).

## Native local relay credentials

Relay credentials are encrypted by the unlocked vault core in a separate local file using AES-256-GCM, a purpose-separated vault-root subkey and vault-ID authenticated data. The master password protects the root through the existing vault header/KDF; it is not serialized into the credential file. Locked core commands cannot read or write this metadata. Credential files are not document export or replication content. Migration from legacy Keychain/Keystore storage validates a durable encrypted readback before attempting legacy cleanup; denied or corrupt storage cannot silently regenerate a device identity. This storage change is not an independent audit or a guarantee against a compromised unlocked app/OS.

### Relay device-list authorization

Mac's per-device read/write switch grants vault access through an encrypted, recipient-bound grant/ack exchange. Mobile enrollment pins the sole verified manager as the authority allowed to offer access; ambiguous manager configurations retain manual pairing. Ordinary group members cannot request vault contents. Persisted revisions reject stale grants, recipient key changes invalidate grants, and local revocation blocks subsequent Mac exchanges before network delivery. This policy delegates acceptance of vault offers to the pinned enrollment manager; it does not cryptographically retract existing downloaded copies. See [relay protocol](PERSONAL-RELAY.md#device-list-authorization-protocol).
