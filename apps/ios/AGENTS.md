# iOS (SwiftUI) — agent notes

The Xcode project is generated from `project.yml` by XcodeGen and ignored by Git:
run `xcodegen generate --spec apps/ios/project.yml` after adding or removing files
(`tool/check_quick.sh ios|ios-test` does it). vault-core comes from `Generated/`
(`VaultCore.xcframework`, `VaultCore.swift`), built by `bash tool/build_mobile_core.sh ios`.

## Where things are
- `Sources/MobileCore.swift` (session) and `Sources/MobileVaultStore.swift` (app state). Build
  core requests with the generated `CoreRequest.xxx(...)` (`Sources/CoreRequest.generated.swift`).
- `../shared/Relay/` — personal relay (`VaultRelay.swift`) compiled into the app target: a thin
  loop around vault-core's shared sync session (`CoreMeshSync` in `RelayCore.swift`); the sync
  rules live in the core's `relay_net::mesh_sync`.
- `Autofill/` — the credential-provider extension; it compiles only the files listed for
  `PasswordVaultAutofill` in `project.yml` (add new shared files there when it needs them).
- Tests: `Tests/` and `../shared/RelayTests/`.

## Checks
- `bash tool/check_quick.sh ios` (simulator build) and `bash tool/check_quick.sh ios-test`
  (unit tests on the nearest installed iPhone simulator; the live relay tests skip without a local relay).
- From the repo root: `python3 tool/check_changed.py`.

## Rules
- `VaultRelay` is `@MainActor`; helpers called from tests or other actors must be `nonisolated`.
- Simulator/unsigned builds are not device acceptance (Face ID, AutoFill entitlements).
