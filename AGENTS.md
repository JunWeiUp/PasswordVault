# Repository guidance

Respond to this repository's owner in Chinese unless asked otherwise. Public documentation, commit messages, and pull request titles default to English; keep the Chinese README synchronized.

- Preserve existing user changes. Do not discard vault data or overwrite signing material.
- Follow docs/CONTRIBUTING.md and the pinned native toolchains.
- Never commit credentials, keystores, real vault exports, local paths, or private agent journals.
- Git 提交时去掉用户敏感数据，把敏感数据放到 `.gitignore` 中。Only list sensitive file or directory paths in `.gitignore`, never the sensitive contents; untrack already tracked private files while preserving local copies.
- Keep database identifiers, app IDs, and legacy storage formats stable during branding/localization work.
- Security-sensitive changes need meaningful migration and failure-path tests.
- Preserve matching localization placeholders and run the relevant native/browser localization checks.
- Do not claim production readiness while docs/SECURITY_MODEL.md contains unresolved blockers.
- Run the checks documented in README.md and report any unverified platform behavior.

## Documentation structure

Maintain these canonical guides and update the relevant document when behavior changes. `docs/` is local-only: it is ignored by Git and must not be committed or published (the owner removed it from the public history).

```text
.
├── AGENTS.md
├── README.md / README.zh-CN.md
├── LICENSE
├── apps/ / crates/ / services/ / vendor/
├── config/signing/              # Public signing fingerprint and example only
├── private/                     # Ignored local keys, notes and retained data
├── native-test-output/dist/     # Existing loaded extension; preserve its path
└── docs/
    ├── DESIGN.md / CHANGELOG.md / TODO.md
    ├── CONTRIBUTING.md / CODE_OF_CONDUCT.md
    ├── SECURITY.md / PRIVACY.md / THIRD_PARTY_NOTICES.md
    ├── PROJECT-SPEC.md / ARCHITECTURE.md
    ├── COMPONENT-GUIDELINES.md / PAGE-STRUCTURE.md
    └── DEVELOPMENT.md / REGISTRY.md / DEPLOYMENT.md
```

Use `docs/DESIGN.md` for visual and interaction principles, `docs/TODO.md` for current priorities and progress, and `docs/CHANGELOG.md` for completed changes. The `docs/` guides own product scope, architecture/data organization, component conventions, page/route behavior, development workflow, artifact construction/distribution, and deployment respectively. Keep navigation in `README.md` and `README.zh-CN.md` synchronized.

Keep source directories aligned with the native toolchains. Security, privacy, installation, localization, branding, and release-note documents supplement this tree. `REGISTRY.md` describes application artifacts because this repository has no public component registry; `DEPLOYMENT.md` describes the configured GitHub release pipeline. Do not imply that a template-specific hosting provider is configured.

## Native migration checks

Every delivered browser-extension update must increment `apps/browser/package.json` and its lockfile version. Use `npm run release:local` to increment the patch version and validate/build; verify the loaded extension version after refreshing it. The manifest and popup version must come from package metadata, never independent hardcoded values.

Current Mac code lives in `apps/macos-nsh`; `apps/macos-legacy` is the legacy SwiftUI client. Browser and core code live in `apps/browser` and `crates/vault-core`. Use the pinned Rust toolchain and `bash tool/check_native.sh core|macos|browser`; see `docs/NATIVE-MIGRATION.md` for Swift tests and fixture setup. The owner has authorized removal of legacy Flutter clients. Preserve native legacy-data readers and compatibility fixtures; source removal does not waive parity or migration gates. Do not test against a real vault or report compilation as Touch ID, device, browser integration, or production-security acceptance.

## Isolated macOS tests

Run XCTest with `bash tool/test_macos_isolated.sh` (optional `-only-testing:…` arguments). It copies source/build prerequisites to `/tmp` and uses a distinct QA bundle ID/display name. Never launch test applications from a Documents-based repository, and never reset TCC or grant broad Documents access to make tests pass.

## Current and legacy Mac clients

`apps/macos-nsh` is the current NSH Mac client; `apps/macos-legacy` is the retained legacy SwiftUI client. Shared web-editor source lives in `apps/shared/note-editor`; its generated `dist/` is ignored. Mac NSH platform tools live in `tool/macos-nsh/`; `tool/nsh_mac.sh` remains the stable CLI entry point. Preserve legacy paths and identifiers still used by mobile/release tooling.
