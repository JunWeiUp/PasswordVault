# Repository guidance

Respond to this repository's owner in Chinese unless asked otherwise. Public documentation, commit messages, and pull request titles default to English; keep the Chinese README synchronized.

- Preserve existing user changes. Do not discard vault data or overwrite signing material.
- Follow CONTRIBUTING.md and the pinned Flutter toolchain.
- Never commit credentials, keystores, real vault exports, local paths, or private agent journals.
- Git 提交时去掉用户敏感数据，把敏感数据放到 `.gitignore` 中。Only list sensitive file or directory paths in `.gitignore`, never the sensitive contents; untrack already tracked private files while preserving local copies.
- Keep database identifiers, app IDs, and legacy storage formats stable during branding/localization work.
- Security-sensitive changes need meaningful migration and failure-path tests.
- Generate localizations before analysis; retain matching placeholders across ARB files.
- Do not claim production readiness while docs/SECURITY_MODEL.md contains unresolved blockers.
- Run the checks documented in README.md and report any unverified platform behavior.

## Documentation structure

Maintain these canonical guides and update the relevant document when behavior changes:

```text
.
├── AGENTS.md
├── README.md
├── DESIGN.md
├── CHANGELOG.md
├── TODO.md
└── docs/
    ├── PROJECT-SPEC.md
    ├── ARCHITECTURE.md
    ├── COMPONENT-GUIDELINES.md
    ├── PAGE-STRUCTURE.md
    ├── DEVELOPMENT.md
    ├── REGISTRY.md
    └── DEPLOYMENT.md
```

Use `DESIGN.md` for visual and interaction principles, `TODO.md` for current priorities and progress, and `CHANGELOG.md` for completed changes. The `docs/` guides own product scope, architecture/data organization, component conventions, page/route behavior, development workflow, artifact construction/distribution, and deployment respectively. Keep navigation in `README.md` and `README.zh-CN.md` synchronized.

Keep source directories aligned with the Flutter toolchain. Security, privacy, installation, localization, branding, and release-note documents supplement this tree. `REGISTRY.md` describes application artifacts because this repository has no public component registry; `DEPLOYMENT.md` describes the configured GitHub release pipeline. Do not imply that a template-specific hosting provider is configured.

## Native migration checks

Every delivered browser-extension update must increment `apps/browser/package.json` and its lockfile version. Use `npm run release:local` to increment the patch version and validate/build; verify the loaded extension version after refreshing it. The manifest and popup version must come from package metadata, never independent hardcoded values.

New native code lives in `apps/macos`, `apps/browser`, and `crates/vault-core`. Use the pinned Rust toolchain and `bash tool/check_native.sh core|macos|browser`; see `docs/NATIVE-MIGRATION.md` for Swift tests and fixture setup. Preserve the legacy Flutter clients until the parity gates pass. Do not test against a real vault or report compilation as Touch ID, device, browser integration, or production-security acceptance.
