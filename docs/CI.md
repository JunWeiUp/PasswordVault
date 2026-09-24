# CI selection and caching

Normal CI runs on pull requests and pushes to `main`/`master`. A feature-branch push with an open PR produces one source-validation run per workflow, not an additional branch-push run. PR title/body edits run only `PR metadata`; they do not cancel or overwrite source test results. New source revisions cancel superseded runs of the same workflow/ref.

## Which jobs run

Repository/release-tool checks and the existing secret scans remain on every source-validation run, including documentation-only changes. Platform jobs use `tool/ci_changes.py` and Git's complete changed-file list (not a truncated API result):

| Change | Platform jobs |
| --- | --- |
| Documentation/README/screenshots under `docs/` | No application builds |
| `apps/android/` | Native Android |
| `apps/ios/` | Native iOS |
| `apps/macos/` | Mac build and Swift tests |
| `apps/browser/` | Browser/WASM build and tests, on Linux |
| `crates/`, Cargo pins, Rust toolchain or `.cargo/` | All five native jobs |
| `lib/`, pubspec or Flutter toolchain | Flutter quality, Android and Web/extension builds |
| Legacy `android/` or `web/`/`chrome/` | Flutter quality plus that platform's build |
| Shared `assets/` or unclassified build inputs | All platform jobs |

Changes to multiple platforms select their union. Mobile build-script changes run both mobile jobs; routing/cache infrastructure changes conservatively run all jobs. Deleted files and both sides of a rename are included. PRs compare their merge base with the head; pushes compare the exact before/after revisions. A missing comparison falls back to the complete matrix. A routing-job failure also fails the required quality check instead of silently accepting skipped jobs.

The existing required check names remain stable; an unaffected job reports Skipped rather than leaving a workflow-level path filter waiting indefinitely. No branch protection or signing/security checks are removed. Legacy preview builds run alongside quality checks rather than waiting for them; they remain development artifacts, and a failed required check still prevents a normal merge. Release packaging continues to depend on all release checks.

## Build reuse and scope

- Rust registry/Git downloads and `target/` are cached per runner OS/architecture and platform job, keyed by toolchain, lockfile and core source. Cargo revalidates restored build inputs. Caches never include private signing material or real vaults.
- Node setup caches npm downloads using each client's lockfile; the browser job caches the pinned `wasm-bindgen` CLI separately. Android uses the existing pinned Gradle cache action.
- Browser builds no longer wait behind the Mac build and Swift tests, or consume a macOS runner.
- Android CI sets `PASSWORDVAULT_ANDROID_ABI=arm64-v8a`, matching the existing compact APK's ABI. Local builds default to both ARM64 and x86_64.
- iOS CI sets `PASSWORDVAULT_IOS_SIM_ARCH=host`, compiling the runner's simulator architecture **and** the ARM64 device library. Local builds still default to the universal simulator XCFramework. Simulator tests and failure diagnostics remain enabled.
- Public/tag release behavior is unchanged: complete quality/security checks, protected signing, asset checksums, and verification before publication.

## Complete run and validation

Use Actions → **CI** and **Native clients** → **Run workflow** on the reviewed ref to request all jobs. Manual and release/tag runs bypass change filtering. A cold cache still requires full compilation; cache reuse improves later builds, not the first run.

`bash tool/check.sh repo` includes routing tests (docs/platform/core, rename/delete, missing diffs and release/manual paths) and shell-orchestration tests for default/selective mobile architectures. Run `actionlint` on the workflows and `bash -n tool/build_mobile_core.sh` for static validation.

Baseline evidence: native run [35974763779](https://github.com/JunWeiUp/PasswordVault/actions/runs/35974763779) took about 24 minutes for iOS (about 12 minutes in core compilation), 10 minutes for Mac/browser and Android, and 5 minutes for the core. These are measurements of the previous workflow, not a promised duration for every future run. Measure cold and warm runs separately after this change is merged.
