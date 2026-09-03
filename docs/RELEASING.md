# Releasing

CI runs analysis, tests, localization/repository validation, secret scanning, and Android/Web/extension builds. It uses the Flutter version in `.flutter-version` and the committed dependency lockfile. Pull requests do not receive Android release credentials.

Tag pushes reuse CI's quality and security gates, then create signed release APKs and an AAB, package Web and the Chromium extension, calculate SHA-256 checksums, and create a **draft prerelease**. The release job builds its own artifacts, so the reusable checks skip duplicate debug/Web builds. Normal branch and pull-request CI still builds Android and Web. A maintainer reviews the draft before publication. No store deployment is configured.

## One-time setup

1. Complete [public history cleanup](PUBLICATION.md). The private development keystore and its passwords were tracked; do not reuse them for public distribution. Decide how existing installations will migrate before changing the signing identity.
2. Generate a new private keystore outside the repository with Java's `keytool`. Keep a protected backup and record its certificate fingerprint. Do not place passwords in shell history.
3. Create a GitHub environment named `release`. Configure required reviewers and restrict deployment to reviewed release tags where your GitHub plan supports it.
4. Configure environment secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, and `ANDROID_CERT_SHA256`. The certificate fingerprint must match the new public signing identity. The Base64 value is the keystore file; encoding is not encryption.
5. Enable private vulnerability reporting and choose required branch checks from a successful CI run. Configure squash merge and require the English Conventional Commit PR title.

`tool/configure_signing.py` writes an ephemeral keystore under `RUNNER_TEMP`, escapes Java properties correctly, and fails if a secret is absent. An `always()` cleanup removes it after packaging. Signing credentials must never be supplied to fork pull requests.

## Local release

Copy `android/key.properties.example` to `android/key.properties` and fill in the path and credentials locally. Use a private key that has never appeared in Git. Release Gradle tasks fail when signing settings are absent.

```bash
flutter build apk --release --split-per-abi
flutter build appbundle --release
./build_extension.sh
```

Before distribution, verify APK signatures using Android SDK `apksigner verify --print-certs`, compare the fingerprint with `android/release-certificate.sha256`, and smoke-test on a device.

## Prepare a version

- Update the version/build number in `pubspec.yaml`, the numeric version in `chrome/manifest.json`, and `CHANGELOG.md`.
- Use a tag such as `v1.1.0-preview.1` for the current `1.1.0` preview. The base version must match both manifests. Do not overwrite an existing tag.
- Push a reviewed commit and its tag after the history/publication decision. `tool/check_repository.py --release` validates the tag and version.
- Review the generated draft, asset sizes, checksum verification, Android certificate, and platform smoke tests.
- Publish only when the intended release status is accurate. Production releases additionally require closing the security blockers; a signed release-mode binary is not a production security endorsement.

A failed or missing signing secret must fail the release. The pipeline never silently substitutes a debug signature or publishes unsigned binaries.
