# Development

## Native toolchain and checks

Use [the native guide](NATIVE-MIGRATION.md#build-and-launch) for Rust 1.96.0, Xcode/XcodeGen, Node.js 22.12+, and wasm-bindgen 0.2.128. Run `bash tool/check_native.sh core|macos|browser|all`. Swift tests use the Xcode scheme shown in that guide. Source-generated bindings, local app bundles, and JavaScript build output are ignored. Commit Cargo.lock and package-lock.json.

### Local Mac note editor

The Markdown component is built from `apps/macos/NoteEditor`, with Milkdown **7.22.2**, esbuild and a committed npm lockfile. Build-time npm installation may access the registry; the resulting editor runs from bundled resources without runtime network access. The Mac check already runs these steps before XcodeGen and compilation:

```bash
npm --prefix apps/macos/NoteEditor ci --ignore-scripts
npm --prefix apps/macos/NoteEditor run build
```

The build emits ignored `apps/macos/Resources/NoteEditor.html` and `NoteEditor-LICENSES.txt`. Regenerate them before directly building the Xcode project after a clean checkout or editor change. Do not hand-edit the generated HTML: its inline script hash and CSP must match the bundled bytes. The build fails if it cannot collect a license for a bundled dependency. See [artifact rules](REGISTRY.md#mac-note-editor-resources).

`tool/check_native.sh macos` compiles the app/helper; it does not replace Swift/WKWebView interaction tests. After preparing the project/resources, run the editor suite or the full scheme using an isolated derived-data directory:

```bash
xcodebuild -project apps/macos/PasswordVault.xcodeproj -scheme PasswordVault \
  -configuration Debug -derivedDataPath native-test-output/milkdown-tests \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 \
  -only-testing:PasswordVaultTests/MilkdownEditorTests test
```

Use only disposable synthetic vaults. Exercise final input followed by lock/reopen, overlapping retirement/lock, rendered-to-source handover and failed handover, stale messages, read-only/Trash, unchanged-source opening, metadata writes, load/process failure, HTML/network restrictions, and actual ProseMirror list/undo behavior. Record native keyboard/Chinese composition, source round trips, long-document scrolling, minimum-window and appearance checks separately. A failing case remains open until diagnosed and rerun; a build or partial suite is not full acceptance. The Milkdown increment is currently undergoing this validation, so do not reuse prior NSTextView test counts or scores.

## Legacy toolchain

Use Flutter **3.41.7**, Dart **3.11.5**, Java **17**, Android SDK **36**, and NDK **27.0.12077973**, Gradle **8.13**, AGP **8.13.1**, and Kotlin **2.2.20**. The Android minimum is API 24, matching the locked secure-storage and cryptography plugins. `.flutter-version` is consumed by CI. `pubspec.lock` is committed to keep resolution repeatable. `flutter doctor -v` diagnoses platform setup.

Use the same check entry points as GitHub Actions. Repository checks need Python 3.11+ and a Node.js version supporting `node --test`.

```bash
bash tool/check.sh repo
bash tool/check.sh flutter
```

The Flutter command installs locked dependencies, generates localizations and database code, checks the SQLite WASM version and generated-code drift, then runs formatting, analysis, and tests with coverage. For initial setup without the check sequence, run `flutter pub get --enforce-lockfile`, `flutter gen-l10n`, and `dart run build_runner build --delete-conflicting-outputs`.

Analyzer warnings and errors fail CI; informational migration/style notices are reported without failing. Add translations before referencing generated localization classes. The database's generated `.g.dart` is committed and must match its source.

## Architecture and UI

See [ARCHITECTURE.md](ARCHITECTURE.md) for source directories, state/data flow, and compatibility constraints; [PAGE-STRUCTURE.md](PAGE-STRUCTURE.md) for screens and routes; and [COMPONENT-GUIDELINES.md](COMPONENT-GUIDELINES.md) for widget implementation and accessibility.

## Build

`bash tool/check.sh android` creates a debug APK without release credentials. `bash tool/check.sh web` calls `build_extension.sh` to create `build/web` and `build/chrome_extension`; rendering assets are bundled locally. `bash tool/check.sh all` runs the full check and development-build sequence. Source maps should not be distributed as release assets. See [DEPLOYMENT.md](DEPLOYMENT.md) for CI artifacts and signing.

The project uses the official Google/Maven Central/Gradle endpoints by default. Developers in restricted networks can configure local proxies. To opt into the Aliyun Maven mirrors for one build, run `PASSWORDVAULT_USE_MAVEN_MIRRORS=true flutter build apk --debug`. Do not commit machine-specific paths or force regional mirrors on all contributors.

For WebDAV, browsers enforce CORS. Configure your server to allow your chosen origin and methods. Ordinary browsers cannot host the local sync server. An APK build alone does not validate runtime SQLite loading, autofill, biometrics, or network behavior; device smoke tests are required before releases.

## Dependency and schema changes

Follow the [data compatibility rules](ARCHITECTURE.md#data-compatibility). Regenerate the database and localizations before analysis, and include migration/failure-path tests when changing storage or encryption. Package and runtime asset validation is documented in [REGISTRY.md](REGISTRY.md).
