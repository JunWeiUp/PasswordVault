# Changelog

User-facing changes are recorded in English. Versions follow Semantic Versioning; build numbers are recorded in `pubspec.yaml`.

## Unreleased — public developer preview

- English-first README, Chinese README, contributor guidance, and documented platform status.
- English and Simplified Chinese application catalogs with a persistent language selector.
- Internationalized browser extension messages and consistent PasswordVault branding.
- Pinned Flutter toolchain, repository validation, extension checks, and separated CI/release workflows.
- Signed release builds, checksum generation, and draft prerelease publication.
- Explicit security, privacy, licensing, and release-readiness documentation.
- Removal of tracked Android signing material from the current tree; historical removal is required before public visibility.

## Private development history

The existing `v1.0.0`–`v1.0.4` tags were private development snapshots. They included vault management, TOTP, browser autofill, WebDAV backup, local sharing, trash, and password history. They were not independently audited production releases. Do not install old APKs as a supported release.
