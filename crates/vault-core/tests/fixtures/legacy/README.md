# Synthetic legacy backup vectors

These files contain fictional records only. Generate them with the pinned Dart SDK:

```sh
dart run tool/generate_legacy_backup_fixtures.dart
```

The generator uses the repository's legacy `VaultItem.toJson` model and the installed Dart `cryptography` API, rather than the Rust implementation under test. The fixed nonces and fixture password are exclusively for reproducible tests.

- `webdav-1.3.json`: Argon2id with the backup's salt and parameters; password is ` Legacy fixture password! `, including both outer spaces.
- `manual-2.0.json`: legacy fixed-salt Argon2id; exporter trims the fixture password.
- `manual-3.0.json`: legacy SHA-256 derivation; exporter trims the fixture password.
- `expected.json`: expected fictional records, including additional accounts, password history, nullable fields, Trash, notes, TOTP and wallet data.

`legacy_interop.rs` verifies field preservation, wrong-password and corruption atomicity, persistence after reopening, merging with existing native records, and repeated-import deduplication.
