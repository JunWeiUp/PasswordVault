# Native Android client

Kotlin/Compose, Android API 24+, Java 17, SDK 36 and NDK 27.0.12077973. Android system Autofill is available on API 26+; the post-login save activity uses API 28+. Older supported systems retain manual credential creation/copy. The reserved `release` variant keeps `com.securepass.vault`; debug/compact and the publicly signed `previewRelease` variant use `.nativepreview` and never replace the legacy production package. Public release APKs are non-debuggable and require the protected release certificate; local debug builds cannot be updated across a signing-key change. See [native release installation](../../docs/NATIVE-RELEASE-NOTES.md).

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

Biometric authentication, old signed-app upgrade continuity, physical-camera capture and manufacturer-specific Autofill behavior still need device acceptance. Do not uninstall an existing production vault to work around a signing mismatch. See [mobile acceptance](../../docs/MOBILE-IMPLEMENTATION.md).
