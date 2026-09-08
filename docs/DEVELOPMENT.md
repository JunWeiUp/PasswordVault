# Development

## Toolchain

Use Flutter **3.41.7**, Dart **3.11.5**, Java **17**, Android SDK **36**, and NDK **27.0.12077973**, Gradle **8.13**, AGP **8.13.1**, and Kotlin **2.2.20**. The Android minimum is API 24, matching the locked secure-storage and cryptography plugins. `.flutter-version` is consumed by CI. `pubspec.lock` is committed to keep resolution repeatable. `flutter doctor -v` diagnoses platform setup.

Use the same check entry points as GitHub Actions. Repository checks need Python 3.11+ and a Node.js version supporting `node --test`.

```bash
bash tool/check.sh repo
bash tool/check.sh flutter
```

The Flutter command installs locked dependencies, generates localizations and database code, checks the SQLite WASM version and generated-code drift, then runs formatting, analysis, and tests with coverage. For initial setup without the check sequence, run `flutter pub get --enforce-lockfile`, `flutter gen-l10n`, and `dart run build_runner build --delete-conflicting-outputs`.

Analyzer warnings and errors fail CI; informational migration/style notices are reported without failing. Add translations before referencing generated localization classes. The database's generated `.g.dart` is committed and must match its source.

## Layout

| Path | Responsibility |
| --- | --- |
| `lib/core/database` | Drift schema, migrations, native and WASM connections |
| `lib/core/security` | Encryption and platform secret storage |
| `lib/core/l10n`, `lib/l10n` | Locale selection, messages, generated accessors |
| `lib/core/theme`, `lib/core/widgets` | Shared visual theme and reusable presentation components |
| `lib/features/vault` | Vault UI, repository, sharing, password health |
| `lib/features/totp` | Authenticator engine and code cards |
| `lib/features/backup` | WebDAV backup and restore |
| `lib/features/sync` | Local discovery, sync endpoints, sharing protocol |
| `chrome` | Manifest V3 worker, content script, translations |
| `web` | Flutter web shell and Drift WASM assets |
| `tool` | Portable repository and release checks |

Riverpod owns application state; GoRouter handles navigation. The internal package name `password`, Android ID `com.securepass.vault`, and existing storage identifiers are retained to avoid breaking data compatibility.

`lib/main.dart` initializes the app and router; `vault_workspace_page.dart` owns responsive navigation, search, lists, and settings. The workspace uses side navigation from 840 logical pixels and bottom navigation below that width. See [PRODUCT_DESIGN.md](PRODUCT_DESIGN.md) for interaction details and [images/README.md](images/README.md) for source-rendered screenshot reproduction.

## Build

`bash tool/check.sh android` creates a debug APK without release credentials. `bash tool/check.sh web` calls `build_extension.sh` to create `build/web` and `build/chrome_extension`; rendering assets are bundled locally. `bash tool/check.sh all` runs the full check and development-build sequence. Source maps should not be distributed as release assets. See [RELEASING.md](RELEASING.md) for CI artifacts and signing.

The project uses the official Google/Maven Central/Gradle endpoints by default. Developers in restricted networks can configure local proxies. To opt into the Aliyun Maven mirrors for one build, run `PASSWORDVAULT_USE_MAVEN_MIRRORS=true flutter build apk --debug`. Do not commit machine-specific paths or force regional mirrors on all contributors.

For WebDAV, browsers enforce CORS. Configure your server to allow your chosen origin and methods. Ordinary browsers cannot host the local sync server. An APK build alone does not validate runtime SQLite loading, autofill, biometrics, or network behavior; device smoke tests are required before releases.

## Data compatibility

Do not rename stored category strings, protocol fields, app IDs, salts, or database names as part of a translation. Changes to master passwords, key derivation, and encrypted backups need migration tests using disposable fixtures. Never use a developer's real vault as a test fixture.

When updating Drift/sqlite3, run `python3 tool/update_sqlite_wasm.py` to download the matching upstream WebAssembly asset and verify its package-published checksum. Commit the updated binary and regenerated worker. CI and extension builds reject mismatched assets.
