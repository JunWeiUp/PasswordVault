# Repository guidance

Respond to this repository's owner in Chinese unless asked otherwise. Public documentation, commit messages, and pull request titles default to English; keep the Chinese README synchronized.

- Preserve existing user changes. Do not discard vault data or overwrite signing material.
- Follow docs/development/CONTRIBUTING.md and the pinned native toolchains.
- Never commit credentials, keystores, real vault exports, local paths, or private agent journals.
- Git 提交时去掉用户敏感数据，把敏感数据放到 `.gitignore` 中。Only list sensitive file or directory paths in `.gitignore`, never the sensitive contents; untrack already tracked private files while preserving local copies.
- Keep database identifiers, app IDs, and legacy storage formats stable during branding/localization work.
- Security-sensitive changes need meaningful migration and failure-path tests.
- Preserve matching localization placeholders and run the relevant native/browser localization checks.
- Do not claim production readiness while docs/security/SECURITY_MODEL.md contains unresolved blockers.
- Run the checks documented in README.md and report any unverified platform behavior.

## Agent quick start

- Each code area has its own short guide: `crates/vault-core/AGENTS.md`, `apps/desktop/AGENTS.md`, `apps/android/AGENTS.md`, `apps/ios/AGENTS.md`, `apps/browser/AGENTS.md` (entry files, the one check command, area rules). They are tracked; `docs/` is local-only.
- Verify a change with `python3 tool/check_changed.py` (`--dry-run` shows the plan); it picks checks from the diff and rebuilds mobile core bindings when `crates/` changes.
- New core command: `python3 tool/new_op.py ...`; which client calls what: `python3 tool/core_contract.py matrix [--missing <client>]`. Clients build requests with the generated typed builders (`CoreRequest`), never hand-written op strings. Desktop UI calls the core only through `call()` (results typed from `commands.json`) or a named `coreApi` helper; the browser extension's ops are checked by `core_contract.py check` (non-registry ops must be declared there).

## Documentation structure

Maintain these canonical guides and update the relevant document when behavior changes. `docs/` is local-only: it is ignored by Git and must not be committed or published (the owner removed it from the public history). For a fast codebase map, invariants, and verification commands across all four client stacks, read `docs/development/AI-MAP.md` first.

```text
.
├── AGENTS.md
├── README.md / README.zh-CN.md
├── LICENSE
├── apps/ / crates/ / vendor/
├── config/signing/              # Public signing fingerprint and example only
├── private/                     # Ignored local keys, notes and retained data
├── native-test-output/dist/     # Existing loaded extension; preserve its path
└── docs/
    ├── README.md               # Categorized documentation index
    ├── product/                # Scope, features and progress
    ├── design/                 # Visual/interaction guides and index.html
    ├── architecture/           # Data, device and synchronization protocols
    ├── development/            # Contribution, toolchains, CI and localization
    ├── platforms/              # Native platform implementation and validation
    ├── browser/                # Extension behavior and acceptance
    ├── security/               # Security, privacy and third-party notices
    ├── releases/               # Changelog, packaging and distribution
    ├── migrations/             # Migration decisions and historical evidence
    └── images/                 # Documentation image assets
```

UI changes follow the local design hub `docs/design/index.html`: the **PC 端完整界面** tab (`#mac`) is the baseline for Mac/Windows UI and the **移动端完整界面** tab (`#android`) for iOS/Android UI; the **其他** tab is historical reference only. Bump the design version (`private/tools/design_version.py bump`) before each design change. Use `docs/design/DESIGN.md` for visual and interaction principles, `docs/product/TODO.md` for current priorities and progress, and `docs/releases/CHANGELOG.md` for completed changes. The `docs/` guides own product scope, architecture/data organization, component conventions, page/route behavior, development workflow, artifact construction/distribution, and deployment respectively. Keep navigation in `README.md` and `README.zh-CN.md` synchronized.

Keep source directories aligned with the native toolchains. Security, privacy, installation, localization, branding, and release-note documents supplement this tree. `REGISTRY.md` describes application artifacts because this repository has no public component registry; `DEPLOYMENT.md` describes the configured GitHub release pipeline. Do not imply that a template-specific hosting provider is configured.

## Native migration checks

Every delivered browser-extension update must increment `apps/browser/package.json` and its lockfile version. Use `npm run release:local` to increment the patch version and validate/build; verify the loaded extension version after refreshing it. The manifest and popup version must come from package metadata, never independent hardcoded values.

Mac and Windows code lives in `apps/desktop` (NSH); iOS in `apps/ios`, Android in `apps/android`, the browser extension in `apps/browser` and the shared core in `crates/vault-core`. All Rust uses one pinned toolchain (`rust-toolchain.toml`, 1.98.0); keep `apps/desktop/rust-toolchain.toml` identical. Use `bash tool/check_native.sh core|macos|browser`; see `docs/migrations/NATIVE-MIGRATION.md` for fixture setup. The owner has authorized removal of legacy Flutter clients. Preserve native legacy-data readers and compatibility fixtures; source removal does not waive parity or migration gates. Do not test against a real vault or report compilation as Touch ID, device, browser integration, or production-security acceptance.

## Technology stacks

The owner consolidated the project to four client stacks over one Rust core: NSH (TSX + Rust) for Mac and Windows, SwiftUI for iOS, Kotlin/Compose for Android, and the TypeScript Chromium extension. The legacy SwiftUI Mac client and the standalone Web package were removed at the owner's request; do not reintroduce them or add another client stack without a new owner request. Move shared business logic into `crates/vault-core` rather than duplicating it per client.

## Mac client and isolated tests

`apps/desktop` is the only Mac client. The shared web note editor in `apps/shared/note-editor` is used by the browser extension and the Android/iOS apps (desktop uses the NSH editor); its generated `dist/` is ignored. Mac NSH platform tools live in `tool/macos-nsh/`; `tool/nsh_mac.sh` remains the stable CLI entry point (including `test-fast`, `test-smoke` and `test-full` with cached synthetic `/tmp` vaults, and `tool/macos-nsh/deploy.sh` for 3–5 s `--ui-only` bundle swaps vs full signed installs). Keep desktop UI, workflows, view-models, formatting, and typed adapters (`apps/desktop/ui/` and `ui/api/`) in TypeScript so routine iterations avoid touching Rust; keep Rust (`crates/vault-core`, `apps/desktop/src/`, and lightweight helper members `apps/desktop/helpers/{pv-mcp,pv-browser-host}`) as a thin, stable layer for cryptography, SQLCipher, large-file streaming, OS services, and IPC policy. Shared branding assets live in `assets/branding/` and the browser identity in `apps/browser/identity.json`. Run desktop UI tests with `bash tool/nsh_mac.sh test` (or `test-fast`/`test-smoke`) against a fresh synthetic vault in a temporary directory, and real-window checks with `bash tool/macos-nsh/gui.sh` (it stages a `/tmp` copy). Never launch test applications from a Documents-based repository, and never reset TCC or grant broad Documents access to make tests pass.

## Dependency update policy

Dependabot automatic version-update PRs are disabled at the owner's request.
Do not restore `.github/dependabot.yml` or enable automatic dependency-update PRs
without a new owner request. Dependency updates are reviewed and run manually.

## Release presentation

Keep release notes concise and publish exactly five application packages: one Android ARM64 APK, one Chromium extension ZIP, one iOS Simulator ZIP, one NSH macOS ZIP and one Windows x64 ZIP. Do not publish extra x86 APKs, source archives or standalone metadata/documentation attachments. Keep internal signature/checksum verification and link license notices in the description.

## CI cost policy

Keep automatic PR checks lightweight. Native builds run only on explicit workflow dispatch or releases; tests default off and are opt-in. Do not reintroduce main-push duplication, metadata-only workflows or redundant release Android builds without an owner request. Preserve tag/signature/package verification and the five release artifacts.
