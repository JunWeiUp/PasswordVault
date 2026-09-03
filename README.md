<div align="center">
  <img src="assets/branding/passwordvault-icon-512.png" alt="PasswordVault — a P-shaped vault and keyhole" width="112" height="112">
  <h1>PasswordVault</h1>
  <p>A local-first vault for passwords, authenticator codes, notes, and wallet credentials.</p>
  <p><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>
  <p>
    <a href="https://github.com/JunWeiUp/PasswordVault/actions/workflows/ci.yml"><img src="https://github.com/JunWeiUp/PasswordVault/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
    <a href="https://flutter.dev"><img src="https://img.shields.io/badge/built_with-Flutter-02569B?logo=flutter" alt="Built with Flutter"></a>
  </p>
</div>

**Developer preview.** PasswordVault is being prepared for its first public release. It has not received an independent security audit. Use disposable test credentials while the [security release blockers](docs/SECURITY_MODEL.md) are being resolved. Existing private development tags do not establish production readiness.

## What you can do

- Keep multiple accounts per website, match multiple domains, organize entries with categories, tags, colors, favorites, and pins.
- Generate TOTP authenticator codes and passwords; manage secure notes and wallet credential records.
- Fill website credentials through a Chromium Manifest V3 extension. Android includes an autofill service.
- Import CSV exports from Chrome, Bitwarden, LastPass, and 1Password; export JSON or CSV, optionally encrypted.
- Back up to your own WebDAV storage. Experiment with local network sync and encrypted shared vaults.
- Recover entries from the trash, view password history, and check for weak, reused, or expired passwords.
- Use **English by default**, or switch to **简体中文** on the lock screen or in **Settings → Appearance**.

The source currently uses `SecurePass` for some internal identifiers and legacy storage formats. The public project name is **PasswordVault**; those identifiers remain stable for compatibility.

## Platform status

| Platform | Status | How to try it |
| --- | --- | --- |
| Android | Primary native target; CI builds a debug APK | Build locally or download a CI artifact |
| Chrome / Edge extension | Experimental; unpacked installation | Build with `./build_extension.sh` |
| Web | Experimental; browser storage and CORS limitations apply | `flutter run -d chrome` |
| iOS | Project scaffold exists; release/device validation pending | Requires macOS, Xcode, and signing |
| Windows / macOS / Linux desktop | No desktop runner is included | Contributions welcome |

There is no Chrome Web Store, Google Play, or App Store listing yet. Published release assets will appear on the [Releases page](https://github.com/JunWeiUp/PasswordVault/releases).

## Run from source

Use **Flutter 3.41.7 / Dart 3.11.5**, the version pinned in [.flutter-version](.flutter-version). Android builds use Java 17, SDK 36, and NDK 27.0.12077973. Install these with Flutter's supported platform tools.

```bash
git clone https://github.com/JunWeiUp/PasswordVault.git
cd PasswordVault
flutter pub get
flutter gen-l10n
dart run build_runner build --delete-conflicting-outputs
flutter run -d chrome
```

For a connected Android device, use `flutter run`. See the [development guide](docs/DEVELOPMENT.md) for architecture, testing, and troubleshooting.

## Build and verify

```bash
flutter analyze --no-fatal-infos
flutter test
python3 tool/check_repository.py
node --test test/extension/*.test.cjs

# Development APK, no private signing credentials required
flutter build apk --debug

# Web and unpacked Chromium extension
./build_extension.sh
```

Load `build/chrome_extension` from `chrome://extensions` or `edge://extensions` with developer mode enabled. Keep this build directory stable: changing an unpacked extension's identity can change its local storage. Back up test data before reinstalling.

Release APKs require a private signing key. [Releasing](docs/RELEASING.md) explains signed APK/AAB builds, draft GitHub releases, checksums, and CI secrets.

## Security and privacy

Vault fields use AES-256-GCM; normal vault keys use Argon2id. These primitives alone do **not** guarantee the security of the complete application. The current implementation includes legacy backup derivation, platform-dependent secret storage, and experimental sharing. Read the [security model and limitations](docs/SECURITY_MODEL.md) before evaluating it.

Unencrypted CSV/JSON exports contain credentials. WebDAV contacts the server you configure; favicon loading can contact third-party services. Local network discovery and browser extension access have separate privacy implications. Details are in [PRIVACY.md](PRIVACY.md).

For vulnerability reports, follow [SECURITY.md](SECURITY.md). Never attach real vault exports, passwords, or private keys to issues.

## Contribute

Start with [CONTRIBUTING.md](CONTRIBUTING.md). Useful contributions include security fixes, migration tests, accessibility, translations, and platform validation. Commit messages and pull request titles use English Conventional Commits; discussion in English or Chinese is welcome.

- [Architecture and development](docs/DEVELOPMENT.md)
- [Translation guide](docs/INTERNATIONALIZATION.md)
- [Roadmap](docs/ROADMAP.md) and [changelog](CHANGELOG.md)
- [Report a bug](https://github.com/JunWeiUp/PasswordVault/issues/new/choose) or propose a feature

If you find the project useful, star it, share a reproducible example, or help review a release. The [launch kit](docs/LAUNCH.md) contains an accurate project description and announcement drafts.

## License

[MIT](LICENSE). Third-party components retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
