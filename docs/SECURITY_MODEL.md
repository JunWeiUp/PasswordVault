# Security model and release blockers

Status: developer preview. This document records a source review, not a penetration test or an independent audit.

## Native V2 increment

The new clients in `apps/` use `crates/vault-core`, separate from the legacy mechanisms below. Native storage requires SQLCipher and an authenticated encrypted document. Browser IndexedDB stores an authenticated ciphertext bundle. Argon2id (64 MiB, 3 passes, 1 lane, random salt) wraps a random root; versioned random-salt backups replace weak legacy writes. Header replacement changes the master password without rewriting the root or sharing identity. Lock releases the active key, and optional Mac Keychain access uses biometryCurrentSet/ThisDeviceOnly access control scoped to the vault directory. This code path does not persist a master password.

V2 sharing binds peer, recipient, vault, request/response, time and replay ID to authenticated messages. Authorization comes from the local roster, not packet claims. Revocation prevents subsequent owner exchanges but cannot retract a previously shared copy. The native extension bridge validates its helper's code identity, uses a private socket, a fixed extension allowlist and revocable pairing capability, and exposes a narrow site-scoped command set. Manual fill/read content scripts are injected only for user actions; default-on login reminders use a top-frame submit listener and HTTP/HTTPS host permissions, with persistent per-origin disable exceptions. Account matching uses exact hostnames across ports as requested; different subdomains remain isolated, and saved HTTPS entries are not offered on HTTP. In-flight navigation checks still bind fills to the actual origin. Icon counts require a matching-account lookup; page scripts receive status only, not vault credentials. While a reminder is pending, shallow root observers restore its UI after SPA replacement; only opaque ID/origin/expiry metadata is re-announced across same-origin navigation. Pending credentials remain in worker memory for at most two minutes and are exposed only to trusted extension UI after a vault-access check. Detection does not automatically save or prove login success. Manual fill/read requests likewise do not retain captured credentials in persistent storage.

The Mac Markdown editor uses pinned, locally bundled Milkdown/ProseMirror code in a nonpersistent WKWebView. A hash-based script policy and `connect-src`, image, media, font and frame restrictions disable network resources; note text is passed through structured JavaScript arguments, never inserted into the HTML template. Raw HTML is rendered as literal text. The native bridge accepts main-frame messages bound to a per-editor ID and rechecks edit permissions. Revision checks reject stale content. Lock, source-mode changes and note switching capture the last editor state before encrypted persistence, then destroy the web document. Closing results remain reusable until the store consumes them. Source loading failures keep the existing record, and failed snapshots block exports. This reduces accidental plaintext persistence; it does not provide zeroization of JavaScript/WebKit memory or isolate secrets from an already-compromised host.

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
