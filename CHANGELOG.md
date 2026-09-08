# Changelog

User-facing changes are recorded in English. Versions follow Semantic Versioning; build numbers are recorded in `pubspec.yaml`.

## Unreleased

- Responsive Accounts-first workspace with persistent search, keyboard shortcuts, compact navigation, and wide-screen tool shortcuts.
- Shared light/dark design system, revised setup and unlock forms, a responsive password generator, and adaptable account cards.
- Correct account-type selection, visible filter resets, keyboard-safe search, and guarded editor/generator routes while locked.
- Reliable default/additional-account copying with completion and failure feedback.
- Product-led English/Chinese documentation, an original concept illustration, and five reproducible Flutter widget captures using fictional data.
- Unified local/CI checks, reviewed-tag release dispatch, non-overwriting signing setup, build metadata, and complete release checksum verification.

The source redesign is not included in the preview package below. Existing security release blockers remain open.

## 1.1.0-preview.3 — 2026-09-03

- English-first README, Chinese README, contributor guidance, and documented platform status.
- English and Simplified Chinese application catalogs with a persistent language selector.
- Internationalized browser extension messages and consistent PasswordVault branding.
- Original P-shaped vault icon across README, Android, iOS, Web, and Chromium, with reproducible platform exports.
- Pinned Flutter toolchain, repository validation, extension checks, and separated CI/release workflows.
- Signed release builds, checksum generation, and draft prerelease publication.
- Explicit security, privacy, licensing, and release-readiness documentation.
- Removal of tracked Android signing material and private development journals from the published history; rotation of the public release signing key.

## Private development history

The existing `v1.0.0`–`v1.0.4` tags were private development snapshots. They included vault management, TOTP, browser autofill, WebDAV backup, local sharing, trash, and password history. They were not independently audited production releases. Do not install old APKs as a supported release.
