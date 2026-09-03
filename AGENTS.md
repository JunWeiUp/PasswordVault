# Repository guidance

Respond to this repository's owner in Chinese unless asked otherwise. Public documentation, commit messages, and pull request titles default to English; keep the Chinese README synchronized.

- Preserve existing user changes. Do not discard vault data or overwrite signing material.
- Follow CONTRIBUTING.md and the pinned Flutter toolchain.
- Never commit credentials, keystores, real vault exports, local paths, or private agent journals.
- Keep database identifiers, app IDs, and legacy storage formats stable during branding/localization work.
- Security-sensitive changes need meaningful migration and failure-path tests.
- Generate localizations before analysis; retain matching placeholders across ARB files.
- Do not claim production readiness while docs/SECURITY_MODEL.md contains unresolved blockers.
- Run the checks documented in README.md and report any unverified platform behavior.
