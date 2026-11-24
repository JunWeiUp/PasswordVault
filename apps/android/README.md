# Native Android client

Kotlin/Compose, Android API 26+, Java 17, SDK 36 and NDK 27.0.12077973. Android system Autofill is available on API 26+; the post-login save activity uses API 28+. Older supported systems retain manual credential creation/copy. The reserved `release` variant keeps `com.securepass.vault`; debug/compact and the publicly signed `previewRelease` variant use `.nativepreview` and never replace the legacy production package. Public release APKs are non-debuggable and require the protected release certificate; local debug builds cannot be updated across a signing-key change. See [native release installation](../../docs/releases/NATIVE-RELEASE-NOTES.md).

```sh
rustup target add aarch64-linux-android x86_64-linux-android
bash tool/build_mobile_core.sh android
./apps/android/gradlew -p apps/android :app:clean :app:assembleCompact :app:assembleCompactAndroidTest :login-fixture:assembleDebug -PtestBuildType=compact -PtargetAbi=arm64-v8a
```

Use a clean build for delivery so incremental APK packaging does not retain unused ZIP gaps.

The compact APK is `app/build/outputs/apk/compact/app-compact.apk`. Omit `-PtargetAbi` for an arm64/x86_64 universal APK; use `x86_64` for that ABI alone. Native libraries and JNA retain 16 KB page compatibility. R8 removes unused code/resources; JNA/UniFFI reflection names remain intact. The compact developer preview keeps debug signing, the isolated package ID, and test-visible app/Kotlin APIs so the delivered binary can be instrumented. It remains a developer preview. The `debug` variant remains available for fast development; `release` requires the original production signing key and uses its own narrower keep rules. The vault is stored only under Android's no-backup directory; secrets are not written to preferences or saved Compose state. Biometric preferences contain only the Keystore-wrapped root key and IV. Screenshots/recents are blocked by `FLAG_SECURE`. The UI test can opt out only in a Debug build and only with a separate UUID-named synthetic test vault; the production vault and Autofill activity cannot use that exception.

Tests use fictional data and temporary directories. On an isolated emulator, install the main debug APK, its instrumentation APK, and the `login-fixture` debug APK, then run:

```sh
adb shell am instrument -w com.securepass.vault.nativepreview.test/androidx.test.runner.AndroidJUnitRunner
```

`AutofillFlowTest` temporarily changes the emulator's Autofill provider and restores its previous value. It preserves an existing preview vault with a different password by skipping that test. `login-fixture` is a separate test application with no network or automatic form submission; it is not included in the vault APK.

Biometric authentication, old signed-app upgrade continuity, physical-camera capture and manufacturer-specific Autofill behavior still need device acceptance. Do not uninstall an existing production vault to work around a signing mismatch. See [mobile acceptance](../../docs/platforms/MOBILE-IMPLEMENTATION.md).

## Sync status and manual retry

Personal device groups use symmetric bidirectional sync: scanning an invitation
joins the group and starts syncing with every member. There is no primary
confirmation, vault grant, pause or conflict list; the newer edit wins and older
versions stay in entry history. Existing legacy journals migrate on first sync
with an encrypted `before-mesh-sync/` snapshot. Sync now wakes polling/reconnect
waits immediately; known transfer units show measured progress.

Isolated test screenshots and evidence live in ignored
`native-test-output/android-sync-progress/`. Production windows retain
`FLAG_SECURE`. Isolated test results do not establish production relay or
physical-device acceptance.

## Session behavior and sharing

The main workspace retains its in-process unlocked session across app switches until the configured idle timeout (1, 5, 15 or 60 minutes; default 60). Returning checks expiry before rendering and does not extend the deadline. Monotonic elapsed time includes sleep. Screen/device lock and manual Lock remain immediate; process restart requires authentication. The separate system Autofill authorization activity retains its lock-on-close policy. The master password is not persisted.

Backgrounding checkpoints unfinished edits as encrypted drafts. Completed checkpoints recover after process death; failed writes report an error and retain encrypted recovery in memory, so quitting before a successful write can still lose changes. Screenshots and app-switcher previews remain protected.

Android no longer offers shared-vault creation, invitations, members, nearby discovery or LAN sync. Shared-vault filters/assignment controls and the WebSocket transport dependency are removed. Existing encrypted records, ownership metadata and backup compatibility are retained; imported read-only records remain read-only. Other clients and other devices' copies are not modified.

Validation: an isolated ARM64 emulator passes `BackgroundSessionTest`, `DraftAndIdleTest`, `CoreLifecycleTest`, `MigrationBehaviorTest` and `LegacyEditingTest#longSelectionKeepsImportedSharedMetadataWithoutSharingControls` (10 tests). Coverage includes Home/return, Activity recreation, screen-off locking, idle expiry, biometric deadline reset, encrypted draft restart/discard, legacy metadata and read-only permissions. This does not replace manufacturer-specific device acceptance.

## Mac-aligned Android workspace

The Compose workspace starts with Notes and uses five root destinations: Notes,
Accounts, Codes, Wallets and Settings. A navigation drawer adds All items,
Favorites, Devices & services and Trash. Detail/edit screens hide the root
navigation. Accounts open in detail first; editing and saving return to that
record. Wallets groups the existing `creditCard`, `identity` and `crypto` types
without changing their identifiers or stored formats.

Search, note category chips, wallet type filters and collection positions remain
within their destination. Settings has dedicated General, Security, Autofill &
Passkeys, Backups & import, Recovery key and About pages. Existing native dialogs,
repository operations and relay enrollment remain the functional authority.
Background/idle behavior is unchanged by the design prototype. Notes uses compact
search/category controls, plain masonry cards and grouped list rows. Collection
tools remain available from the Notes sort sheet. Markdown notes retain the native
editor; rich-v1 notes display their complete document inline through an isolated
read-only WebView, with encrypted image reads and external requests denied. The
reader is removed on background/lock and cannot write entries or drafts.

Devices & services displays existing format-7 records and reads encrypted text
attachments through the core. It never executes commands or connects to hosts.
Secrets and device documents start concealed; leaving/backgrounding a detail
clears its reveal state and any clipboard content still owned by that detail.
Recovery phrases require reveal confirmation and have no copy action.

Run `WorkspaceNavigationTest` with the lifecycle/draft, migration, rich-note and
recovery suites on an isolated emulator. Supply `-e designTheme dark` for the
navigation test's dark fixture, and separately check a narrow display with a
larger system font. Physical fingerprint/camera, manufacturer Autofill and signed
in-place upgrades remain device acceptance tasks.

Page-by-page visual evidence for the current alignment is retained in ignored
`native-test-output/android-alignment/`; see `comparison.html`,
`SCENE-COVERAGE.md` and `ACCEPTANCE.md` there for actual coverage and limitations.
The earlier `native-test-output/android-refresh/` acceptance predates this review.
Six JVM tests and seventeen distinct scoped instrumentation tests pass across
recorded runs; the final six-test focused rerun includes the repaired account
action flow. Navigation/editing also passes in dark mode and at 360dp/1.3× font
size. The local evidence records individual runs and failures before fixes;
screenshots do not establish hardware or service-state acceptance.
Full Lint still reports nine API/state-usage errors, and three release-tool tests
encounter the existing browser/native version mismatch. These checks are not fully
green.
