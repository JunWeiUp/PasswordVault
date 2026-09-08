<div align="center">
  <img src="assets/branding/passwordvault-icon-512.png" alt="PasswordVault — a P-shaped vault and keyhole" width="72" height="72">
  <h1>PasswordVault</h1>
  <h3>Everyday credentials. A little more order.</h3>
  <p>A local-first home for passwords, authenticator codes, notes, and wallet credentials.</p>
  <p><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>
  <img src="docs/images/vault-hero.png" alt="PasswordVault concept illustration: a blue vault surrounded by account cards and authenticator symbols" width="1120">
  <br><br>

**[Try the developer preview ↗](https://github.com/JunWeiUp/PasswordVault/releases/tag/v1.1.0-preview.4)** &nbsp; · &nbsp; **[Build from source](#run-from-source)**

<sub>Android 7.0+ · Experimental Chromium extension and Web · <a href="docs/GETTING_STARTED.md">Installation & first steps</a></sub>

[![CI](https://github.com/JunWeiUp/PasswordVault/actions/workflows/ci.yml/badge.svg)](https://github.com/JunWeiUp/PasswordVault/actions/workflows/ci.yml)
[![Flutter](https://img.shields.io/badge/Flutter-3.41.7-02569B?logo=flutter)](.flutter-version)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**[Take a look](#take-a-look)** · **[Get started](#get-started-in-three-steps)** · **[Features](#feature-reference)** · **[Development](#run-from-source)**

</div>

> **Developer preview — use synthetic credentials.** PasswordVault has not received an independent security audit. The [security release blockers](docs/SECURITY_MODEL.md) include persistent master-password storage, password-change migration, legacy backups, and experimental sharing. The redesign shown below is from the current source; the linked preview package may have an earlier interface.

<table>
<tr>
<td width="33%" valign="top">

### Find the right account.

Search titles, usernames, and domains. Narrow the list with categories and tags; favorite or pin the entries you use most.

</td>
<td width="33%" valign="top">

### Keep the related things together.

Passwords, TOTP codes, notes, and wallet records share one app. Each has its own view, with the controls it needs.

</td>
<td width="33%" valign="top">

### Make the next step clear.

Create a password, check password health, or manage a backup. Everyday tools have a visible home instead of getting lost in settings.

</td>
</tr>
</table>

## Take a look

### Room to browse. Focus when you need it.

A persistent search field, clear content hierarchy, and navigation that adapts to the available width. A blue primary action marks the next step; quieter surfaces leave room for the entries themselves.

<a href="docs/images/vault-desktop.png"><img src="docs/images/vault-desktop.png" alt="PasswordVault wide layout with side navigation, search, filters, and sample account entries" width="1120"></a>

### The same vault, sized for your screen.

Compact screens use bottom navigation. Light and dark appearances share the same layout, labels, and actions. Start with a test entry, or clear a search that has no matches and continue browsing.

<p align="center">
  <a href="docs/images/vault-mobile.png"><img src="docs/images/vault-mobile.png" alt="Compact PasswordVault layout with search, account cards, and bottom navigation" width="32%"></a>&nbsp;
  <a href="docs/images/vault-dark.png"><img src="docs/images/vault-dark.png" alt="PasswordVault account list in dark appearance using synthetic entries" width="32%"></a>&nbsp;
  <a href="docs/images/lock.png"><img src="docs/images/lock.png" alt="PasswordVault lock screen with language selection and master-password form" width="32%"></a>
</p>

<sub>These are Flutter widget renders of the current source with synthetic data, not captures from a physical device. The wide view is a responsive app layout, not a native desktop release. The opening image is a concept illustration. [Image sources and reproduction](docs/images/README.md).</sub>

<details>
<summary><b>A closer look at the password generator</b></summary>

Choose length and character types, regenerate, then copy. In the browser extension, the generator also offers filling into the current page.

<p align="center"><a href="docs/images/generator.png"><img src="docs/images/generator.png" alt="Password generator with a generated example, copy and regenerate actions, length slider, and character options" width="460"></a></p>

</details>

## Get started in three steps

1. **Choose a preview.** Install an Android APK, load the unpacked Chromium extension, or run the current source to see the redesign. [Installation details](docs/GETTING_STARTED.md#choose-a-build).
2. **Create a test vault.** Choose a disposable master password and add a fictional account such as `hello@example.com`. English is the default; switch to 简体中文 on the lock screen or in **Settings → Appearance**.
3. **Try your everyday flow.** Search for the account, generate a password, and copy a sample credential. Before importing anything, rehearse export and restoration with synthetic entries. [First session and recovery checks](docs/GETTING_STARTED.md#your-first-session).

**[Installation & troubleshooting](docs/GETTING_STARTED.md)** · **[Report a bug](https://github.com/JunWeiUp/PasswordVault/issues/new/choose)** · **[Product design guide](docs/PRODUCT_DESIGN.md)**

## Feature reference

| Area | What is in the source |
| --- | --- |
| Accounts | Multiple accounts per website, multiple domains, categories, tags, colors, favorites, pins, password history, and trash |
| Other entries | TOTP authenticator codes, secure notes, and wallet credential records |
| Everyday tools | Password generator and weak, reused, or expired password checks |
| Autofill | Chromium Manifest V3 extension; Android autofill service |
| Import and export | CSV import from Chrome, Bitwarden, LastPass, and 1Password; JSON/CSV export with encryption options |
| Backup | Backup and restore using your configured WebDAV server |
| Collaboration | Experimental local network sync and encrypted shared vaults |
| Appearance | English and 简体中文; light, dark, and system themes; compact and wide layouts |

Feature availability in the source does not establish security or runtime validation. Sharing, browser storage, biometrics, autofill, and recovery have specific [security](docs/SECURITY_MODEL.md) and [platform limitations](docs/DEVELOPMENT.md#build).

### Platform status

| Platform | Status | How to try it |
| --- | --- | --- |
| Android | Signed developer-preview APKs; Android 7.0+ | Download the APK for your architecture; most recent devices use `arm64-v8a` |
| Chrome / Edge extension | Experimental; unpacked installation | Extract the extension ZIP, or run `bash tool/check.sh web` |
| Web | Experimental; browser storage and CORS limitations apply | Self-host the Web ZIP, or run `flutter run -d chrome` |
| iOS | Project scaffold exists; device and release validation pending | Requires macOS, Xcode, and signing |
| Windows / macOS / Linux desktop | No desktop runner is included | The wide screenshots demonstrate responsive layout only |

The [existing developer preview](https://github.com/JunWeiUp/PasswordVault/releases/tag/v1.1.0-preview.4) includes downloads and checksums. There is no Chrome Web Store, Google Play, or App Store listing. Source version: **1.1.0+6** in [pubspec.yaml](pubspec.yaml); a source version is not proof that a matching package has been published.

## Run from source

Use **Flutter 3.41.7 / Dart 3.11.5**, pinned in [.flutter-version](.flutter-version). Android builds use Java 17, SDK 36, and NDK 27.0.12077973. See [Development](docs/DEVELOPMENT.md) for the complete toolchain and architecture.

```bash
git clone https://github.com/JunWeiUp/PasswordVault.git
cd PasswordVault
flutter pub get --enforce-lockfile
flutter gen-l10n
dart run build_runner build --delete-conflicting-outputs
flutter run -d chrome
```

For a connected Android device, use `flutter run`. The internal package name `password`, Android application ID `com.securepass.vault`, and legacy `SecurePass` identifiers remain stable for data compatibility.

### Build and verify

The same entry point runs locally and in CI:

```bash
# Repository, release-tool, and browser-extension tests
bash tool/check.sh repo

# Locked dependencies, generated code, formatting, analysis, and Flutter tests
bash tool/check.sh flutter

# Development APK; no release signing credentials required
bash tool/check.sh android

# Web and unpacked Chromium extension
bash tool/check.sh web

# All of the above
bash tool/check.sh all
```

Load `build/chrome_extension` from `chrome://extensions` or `edge://extensions` with developer mode enabled. Keep the unpacked directory stable: changing the extension's identity can change its storage. Back up synthetic test data before reinstalling.

### CI and release delivery

Pull requests, branch pushes, and manual runs use separate repository, Flutter quality, and secret-scanning jobs. CI checks localization and generated code, formatting, analysis, tests, and Git history, then builds **android-debug**, **web-preview**, and **chromium-extension-preview** artifacts. Build artifacts are retained for 14 days; coverage for 7 days. Passing CI is build evidence, not an independent security audit.

A version tag or a manual run for an existing tag starts release delivery. Automation verifies the version and Android signing identity, packages APK/AAB, Web, and extension assets with build metadata and SHA-256 checksums, and publishes a **developer prerelease directly, without draft mode**. Branch pushes produce CI artifacts; push a new version tag to publish a release. See [Releasing](docs/RELEASING.md) for signing secrets, artifacts, and the review checklist.

## Security and privacy

Vault fields use AES-256-GCM; normal vault keys use Argon2id. These primitives alone do not establish the security of the complete app. The current implementation persists the master password, including in browser storage on Web, and changing it lacks transactional vault re-encryption. Legacy backup derivation, LAN sharing, and extension storage also need review. Read the complete [security model and release blockers](docs/SECURITY_MODEL.md) before evaluating the app.

CSV/JSON exports may contain plaintext credentials. WebDAV contacts the server you configure; favicon loading can contact third parties, and local discovery exposes network metadata. See [PRIVACY.md](PRIVACY.md). Do not describe this preview as audited, zero-knowledge, or production-safe.

Report vulnerabilities through [SECURITY.md](SECURITY.md). Never attach real passwords, private keys, or vault exports to an issue.

## Contribute

Start with [CONTRIBUTING.md](CONTRIBUTING.md). Security fixes, migration tests, accessibility checks, translations, and device validation are especially useful. Use synthetic data in screenshots and bug reports. Commit messages and PR titles use English Conventional Commits; discussion in English or Chinese is welcome.

| Guide | Contents |
| --- | --- |
| [Getting started](docs/GETTING_STARTED.md) | Installation, first session, and troubleshooting |
| [Product design](docs/PRODUCT_DESIGN.md) | Navigation, interaction patterns, visual direction, and review criteria |
| [Development](docs/DEVELOPMENT.md) | Architecture, toolchain, and platform checks |
| [Internationalization](docs/INTERNATIONALIZATION.md) | Adding and maintaining translations |
| [Releasing](docs/RELEASING.md) | CI, signing, packaging, and publication |
| [Roadmap](docs/ROADMAP.md) · [Changelog](CHANGELOG.md) | Priorities and recorded changes |

## License

[MIT](LICENSE). Third-party components retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
