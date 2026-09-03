# Development

## Toolchain

Use Flutter **3.41.7**, Dart **3.11.5**, Java **17**, Android SDK **36**, and NDK **27.0.12077973**. `.flutter-version` is consumed by CI. `pubspec.lock` is committed to keep resolution repeatable. `flutter doctor -v` diagnoses platform setup.

```bash
flutter pub get
flutter gen-l10n
dart run build_runner build --delete-conflicting-outputs
flutter analyze --no-fatal-infos
flutter test
python3 tool/check_repository.py
node --test test/extension/*.test.cjs
```

Analyzer warnings and errors fail CI; informational migration/style notices are reported without failing. Add translations before referencing generated localization classes. The database's generated `.g.dart` is committed and must match its source.

## Layout

| Path | Responsibility |
| --- | --- |
| `lib/core/database` | Drift schema, migrations, native and WASM connections |
| `lib/core/security` | Encryption and platform secret storage |
| `lib/core/l10n`, `lib/l10n` | Locale selection, messages, generated accessors |
| `lib/features/vault` | Vault UI, repository, sharing, password health |
| `lib/features/totp` | Authenticator engine and code cards |
| `lib/features/backup` | WebDAV backup and restore |
| `lib/features/sync` | Local discovery, sync endpoints, sharing protocol |
| `chrome` | Manifest V3 worker, content script, translations |
| `web` | Flutter web shell and Drift WASM assets |
| `tool` | Portable repository and release checks |

Riverpod owns application state; GoRouter handles navigation. The internal package name `password`, Android ID `com.securepass.vault`, and existing storage identifiers are retained to avoid breaking data compatibility.

## Build

`flutter build apk --debug` needs no release credentials. `./build_extension.sh` creates `build/web` and `build/chrome_extension`; it bundles rendering assets locally. Source maps should not be distributed as release assets. See [RELEASING.md](RELEASING.md) for signing.

The project uses the official Google/Maven Central/Gradle endpoints by default. Developers in restricted networks can configure local proxies or trusted mirrors; do not commit machine-specific paths or force regional mirrors on all contributors.

For WebDAV, browsers enforce CORS. Configure your server to allow your chosen origin and methods. Ordinary browsers cannot host the local sync server. An APK build alone does not validate runtime SQLite loading, autofill, biometrics, or network behavior; device smoke tests are required before releases.

## Data compatibility

Do not rename stored category strings, protocol fields, app IDs, salts, or database names as part of a translation. Changes to master passwords, key derivation, and encrypted backups need migration tests using disposable fixtures. Never use a developer's real vault as a test fixture.
