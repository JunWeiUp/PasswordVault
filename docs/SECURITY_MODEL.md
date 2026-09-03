# Security model and release blockers

Status: developer preview. This document records a source review, not a penetration test or an independent audit.

## Current design

Secret vault fields use AES-256-GCM. Normal vault keys use Argon2id with 32 MiB memory, two iterations, one lane, and a stored salt. Sharing code uses X25519, HKDF-SHA256, and AES-GCM. Metadata is not necessarily encrypted.

The platform storage wrapper uses Android/iOS secure storage on native devices and SharedPreferences on Web. The current master-password provider persists the password itself and caches derived keys. On Web this defeats an at-rest protection claim against someone who can read browser storage. Native secure storage does not by itself prove that every read is gated by biometrics.

## Blockers for a production release

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
