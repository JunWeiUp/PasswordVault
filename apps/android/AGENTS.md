# Android (Kotlin/Compose) — agent notes

Sources: `app/src/main/java/com/securepass/vault/`. vault-core is loaded through UniFFI
bindings generated into `app/src/main/generated` (ignored by Git) by
`bash tool/build_mobile_core.sh android` — rerun it after changing `crates/`.

## Where things are
- `VaultRepository.kt` — the vault session, state and every core call. Build requests with
  the generated `CoreRequest.xxx(...)` (`CoreRequest.generated.kt`, never edit by hand).
- `PersonalRelay.kt` — personal device-group sync over vault-core's relay stack via
  `RelayCore.kt` (`CoreGroups`, `RelayConnection`, `RelayFileClient`).
- UI screens are Compose files in the same package (`VaultWorkspace.kt`, `SettingsScreen.kt`,
  `EntryEditor.kt`, ...).

## Checks
- `bash tool/check_quick.sh android` — compile main + instrumented tests, JVM unit tests.
- Device tests run on an emulator only:
  `ANDROID_SERIAL=<emulator> ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.securepass.vault.<Test>`
- From the repo root: `python3 tool/check_changed.py`.

## Rules
- JVM unit tests (`app/src/test`) cannot load vault-core; anything that calls the core
  (including relay links, signing, envelopes) belongs in `app/src/androidTest`.
- Never run tests on physical phones, uninstall the app to bypass a signature mismatch, or
  replace release signing material.
- Keep database identifiers, app IDs and legacy storage formats stable.
