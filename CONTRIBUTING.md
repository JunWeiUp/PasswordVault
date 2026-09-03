# Contributing to PasswordVault

Thank you for helping build a useful, understandable vault. English is the default for documentation, commit messages, and pull request titles. English and Chinese discussions are both welcome. The [Chinese README](README.zh-CN.md) provides a starting point.

Read the [development guide](docs/DEVELOPMENT.md), then open an issue describing a reproducible problem or proposed change. For vulnerabilities, use [SECURITY.md](SECURITY.md) instead of a public issue.

## Development workflow

1. Fork and create a focused branch from `main`.
2. Install the pinned Flutter SDK; run `flutter pub get`, `flutter gen-l10n`, and database code generation.
3. Make a focused change. Add meaningful tests for behavior, security boundaries, or migrations; avoid implementation-only assertions.
4. Run the checks in the README and format changed Dart files with `dart format`.
5. Open a pull request that explains the problem, resulting behavior, and validation. Include screenshots for UI changes using synthetic data only.

Never commit keystores, credentials, real vault exports, local journals, or private signing configuration. Keep lockfiles committed. Dependency updates should include build and migration evidence.

## Commits and pull requests

Use English Conventional Commits:

```text
feat(l10n): add Spanish translations
fix(backup): preserve newer records when restoring
ci(android): verify signed release artifacts
docs: clarify browser storage limitations
```

Supported types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`. Use imperative descriptions; explain breaking changes in the body with `BREAKING CHANGE:`. Do not rewrite someone else's branch history without coordination. Maintainers normally squash PRs using their validated title.

## Translations

Edit ARB catalogs rather than generated Dart. Keep placeholders equivalent, preserve product names, and avoid translating stored identifiers or user data. See [INTERNATIONALIZATION.md](docs/INTERNATIONALIZATION.md).

## Review expectations

Explain any change to encryption, key storage, backup formats, domain matching, or permissions. Include compatibility tests before removing legacy readers. Do not weaken CI or hide failing tests. A passing test suite is not a security audit.

Contributions are provided under the project's [MIT license](LICENSE). Respect others and follow the [Code of Conduct](CODE_OF_CONDUCT.md).
