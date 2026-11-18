# Experiment: mobile UI on Native Shell (NSH)

**Status: concluded, not adopted (2026-11-18).** The iOS and Android apps keep their native
SwiftUI and Jetpack Compose interfaces. Nothing in this folder is built by CI, linked into an
app or shipped in a release.

## Question

Could iOS and Android share the desktop client's NSH (TSX + Rust) UI, embedded in the existing
native apps, so that one TSX code base serves Mac, Windows, iOS and Android?

## What was built

A pilot of one screen, the verification-codes list, embedded in both mobile apps:

| Path | Contents |
| --- | --- |
| `ui/` | NSH TSX project shared by both platforms (`App.tsx`, `ui/Codes.tsx`, `ui/host.ts`) and its headless tests (`tests/codes.test.tsx`, host app stubbed). |
| `ios/NshScreen.swift` | `NshAppView` wrapper and host handlers; replaced the codes tab. |
| `ios/integration.diff` | `project.yml` (link `NativeShell.xcframework`, copy the `nsh` bundle), tab wiring and the UI-test change. |
| `android/NshScreen.kt` | `NshView` in Compose and host handlers; replaced the codes page. |
| `android/NshCodesTest.kt` | Instrumentation test on an emulator. |
| `android/integration.diff` | Gradle (`nsh.aar`, `assets/nsh`) and workspace wiring. |
| `tool/fetch-embed.sh` | Downloads the pinned NSH 0.5.1 embedding SDKs into the ignored `vendor/nsh-embed/` and verifies their SHA-256. |
| `tool/build-bundle.sh` | Builds `ui/` into `ui/build/nsh` (`bundle.nshc`, about 40 KB). |
| `tool/build_mobile_core.diff` | Hooks both scripts into `tool/build_mobile_core.sh`. |

### Boundary

The TSX page reaches the app only through `nsh/host` calls granted in `ui/nsh.json`
(`vault.*`, `clipboard.copy`); it has no network, file or clipboard capability. Secrets never
enter JavaScript: the host computes codes natively (`vault.codes`) and performs copies itself, so
iOS local-only/expiry and Android sensitive-clip protections still apply.

## Results

Functionally the pilot worked on both platforms: an iOS 27 simulator and a Pixel 9 (ARM64)
emulator showed live codes from the vault, copying and opening details went through the host,
and accessibility labels were exposed. The TSX tests passed, and so did the iOS UI flow and the
Android instrumentation test.

The blocker is size. NSH ships as one prebuilt runtime (JS engine, layout and text engines, the
full component library, GPU/shader stack, SVG, math layout, TLS, Rust unwind tables). Pages
reach components dynamically, so the linker cannot remove unused parts; the codes page used a
tiny fraction of it.

| | Native (main) | With NSH | Change |
| --- | --- | --- | --- |
| iOS Release arm64 executable, stripped | 12.5 MB | 64.1 MB | +51.6 MB |
| iOS executable, gzip (download estimate) | 5.2 MB | 26.0 MB | +20.8 MB |
| Android ARM64 APK (`.so` stored) | 13.3 MB | 68.1 MB | +54.8 MB |
| Android ARM64 APK (`.so` compressed, estimate) | 13.3 MB | ~33 MB | ~+20 MB (install still +49 MB) |

iOS `__text` grew from 6.6 MB to 40.9 MB; the largest contributors were `nsh_base` (5.9 MB),
the NSH core/engine (~4.7 MB), `nsh_platform_ios` with its Swift layer (~4.4 MB), the JS engine
(~3.4 MB) and `wgpu`/`naga` (~1.7 MB). Unwind and exception tables added about 8 MB. For
comparison, the desktop releases already carry the same runtime: the v2.5.4 macOS ZIP is
32.5 MB (92 MB installed) and the Windows ZIP 26.8 MB (68.9 MB unpacked).

Not measured: launch time, memory, IME input (the codes page has no text field) and physical
devices.

## Decision

The owner chose to keep native mobile UIs because of the size cost. Options left open: a
source build of NSH without unused features (GPU, SVG, math, TLS) and with `panic=abort`, which
might save 30–50% but needs a custom build per NSH upgrade.

## Reproducing

From the repository root, on a branch:

```sh
bash experiments/mobile-nsh/tool/fetch-embed.sh
bash experiments/mobile-nsh/tool/build-bundle.sh
git apply experiments/mobile-nsh/ios/integration.diff experiments/mobile-nsh/android/integration.diff
cp experiments/mobile-nsh/ios/NshScreen.swift apps/ios/Sources/
cp experiments/mobile-nsh/android/NshScreen.kt apps/android/app/src/main/java/com/securepass/vault/
cp experiments/mobile-nsh/android/NshCodesTest.kt apps/android/app/src/androidTest/java/com/securepass/vault/
```

Then build as usual (`tool/build_mobile_core.sh`, `xcodegen`, Gradle). The diffs were made
against `main` at 218fddb; NSH and its SDKs are pinned to 0.5.1. Run Android tests only on an
emulator (`ANDROID_SERIAL=emulator-…`); the app's screen protection makes system screenshots
black, so read the view hierarchy instead.
