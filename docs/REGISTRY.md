# Build and distribution registry

## Native 2.x releases

Tags `v2.*` and later use `native-release.yml`; `v1.*` remains the legacy Flutter release workflow. Update `native-version.json` and the native platform manifests together, including both iOS targets. For browser releases use `PASSWORDVAULT_RELEASE_VERSION=2.2.1 npm run release:local` (omit the variable for the usual patch increment). Validate with `python3 tool/native_release.py versions` and `bash tool/check.sh repo`.

Native release checks run the complete native suite, then publish only after every job succeeds. Android public APKs use the protected `release` environment and the reviewed certificate; `previewRelease` is non-debuggable and keeps the separate native-preview application ID. Missing signing configuration fails the build. Ad-hoc Mac universal ZIPs, iOS Simulator ZIPs (not IPA), browser/Web ZIPs and committed-source ZIPs accompany the APKs. Apple archives retain executable permissions. The packager validates versions, simulator identity and checksums; the workflow verifies the tag still identifies the checked commit before publishing a regular Latest release.

See [native installation notes](NATIVE-RELEASE-NOTES.md) for signature-change migration, Mac Touch ID limitations, simulator/device differences and the exact public inventory. No Apple signing identities or provisioning material are published. Downloaded native builds do not replace or automatically migrate legacy vaults.

## Legacy 1.x delivery


## Scope

PasswordVault distributes an application, not a public component package. There is no component registry service or package publication job. `pubspec.yaml` sets `publish_to: 'none'`; reusable widgets are consumed directly from this repository. This guide records the build inputs, validation, and distribution boundaries for the existing application targets.

## Inputs and outputs

| Input | Output / consumer | Validation |
| --- | --- | --- |
| `lib/`, `android/`, locked Dart dependencies | Android debug APK or signed APKs/AAB | Repository and Flutter checks, Android build, release signature checks |
| `lib/`, `web/`, SQLite WASM and Drift worker | `build/web/` | `bash tool/check.sh web`; matched SQLite assets and locally bundled renderer |
| Web output plus `chrome/` manifest, scripts, icons, and locales | `build/chrome_extension/` | Extension locale tests and `tool/check_repository.py --extension-build` |
| Platform build outputs, release notes, licenses, reviewed certificate | `release_assets/` | `tool/package_release.py` and complete checksum inventory verification |

[`build_extension.sh`](../build_extension.sh) creates Web output, copies it into the extension directory, overlays the extension shell/assets, and removes development sources and maps from distributed directories. [`tool/package_release.py`](../tool/package_release.py) stages release assets and build metadata without including private signing material.

## Version and asset rules

- Keep the numeric version in `chrome/manifest.json` equal to the version in `pubspec.yaml`; the Flutter build number is maintained separately.
- Release tags must be unique, exist at the reviewed commit, and match the manifest base version.
- Keep the SQLite WASM binary and Drift worker compatible with `pubspec.lock`; regenerate/check them as described in [ARCHITECTURE.md](ARCHITECTURE.md#data-compatibility).
- Include licenses and third-party notices. Do not distribute source maps, private journals, keystores, credentials, or real vault data.

## Distribution inventory

Pull-request/main CI exposes temporary artifacts for affected platforms; documentation-only changes do not rebuild clients. Manual workflows run the full build matrix. See [CI selection](CI.md). Release delivery packages three architecture-specific APKs, one AAB, Web and extension ZIPs, a signing-certificate fingerprint, `BUILD.json`, installation instructions, licenses, and `SHA256SUMS`.

The public distribution target is GitHub Releases. No app-store or component-registry publication is configured. [DEPLOYMENT.md](DEPLOYMENT.md) owns signing setup, artifact retention, release commands, certificate/checksum verification, and device smoke checks. [GETTING_STARTED.md](GETTING_STARTED.md) explains installation for testers.

## Native V2 artifacts

`tool/check_native.sh macos` builds the local note-editor resources, generates UniFFI Swift bindings, combines arm64/x86_64 Rust static libraries, and builds the Mac app/helper with XcodeGen. `tool/check_native.sh browser` produces WASM, runs TypeScript/security tests, and packages an unpacked extension with a fixed public identity and an 8 MiB size ceiling. There is no component registry. `apps/browser/identity.json` contains only the public manifest key; its matching native allowlist is a resource in the Mac app. Never commit a signing private key or pairing token. See [NATIVE-MIGRATION.md](NATIVE-MIGRATION.md).

### Mac note-editor resources

| Input | Bundled output | Required verification |
| --- | --- | --- |
| `apps/macos/NoteEditor/editor.js`, `style.css`, `build.mjs`, `package.json`, `package-lock.json` | `apps/macos/Resources/NoteEditor.html` | Locked Milkdown 7.22.2 build, script-hash CSP, no external runtime assets; real WKWebView lifecycle/interaction tests |
| Licenses of packages present in the esbuild dependency graph | `apps/macos/Resources/NoteEditor-LICENSES.txt` | Build fails on a missing bundled dependency license; include the notices in the Mac resource bundle |
| `Sources/MarkdownNoteEditor.swift` and AppStore note leases | Native WebKit/SwiftUI host and encrypted save handover | Session/permission checks, final snapshots, source-mode handover, lock/retirement races and failure paths |

The HTML and generated notice file are ignored build products. Commit their source inputs and npm lockfile, not `node_modules`, machine-local paths or note data. XcodeGen includes `Resources` in the app bundle, so generate these files before project generation and check their presence in the signed artifact. Editor JavaScript is bundled as an IIFE for Safari 16; do not distribute source maps or fetch editor code from a CDN. Note text is injected only into the running nonpersistent web view, never into a packaged resource.

The current editor increment targets **Mac 2.0.9 build 13**; the browser package remains **2.0.9** because this editor change does not modify its deliverable. These are candidate/version metadata, not a claim that acceptance, installation, notarization or public distribution is complete. Record final test and isolated-window results before advancing the release status.
