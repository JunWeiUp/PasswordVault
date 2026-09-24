# Android APK size

Sizes below are measured from signed local APK files, in decimal MB. These are download/package sizes, not installed storage or process memory.

| Artifact | ABIs | Bytes | MB |
| --- | --- | ---: | ---: |
| Previous 2.1.1 debug preview (21003) | arm64 + x86_64 | 36,431,415 | 36.43 |
| 2.1.2 compact preview (21004) | arm64 + x86_64 | 22,528,522 | 22.53 |
| 2.1.2 compact phone preview (21004) | arm64 | 14,307,098 | 14.31 |
| 2.1.3 UI preview (21005) | arm64 | 14,552,960 | 14.55 |
| 2.1.4 UI refinement (21006) | arm64 | 14,634,904 | 14.63 |
| 2.1.5 legacy parity (21007) | arm64 | 15,423,775 | 15.42 |

The 2.1.2 phone APK is **60.73% smaller** than the previously delivered universal debug APK. At the same ABI coverage, compact packaging reduces 36.43 MB to 22.53 MB. The remaining difference comes from removing the x86_64 library copy from the phone APK.

## 2.1.2 ARM64 package contents

Measured using each ZIP entry's stored/compressed byte count, with signing/index/alignment overhead computed as the remainder of the actual APK file size.

| Part | Stored bytes | MB | Share |
| --- | ---: | ---: | ---: |
| Rust vault core, including SQLCipher/OpenSSL | 7,389,440 | 7.39 | 51.65% |
| Android application/dependency DEX | 5,860,662 | 5.86 | 40.96% |
| Resources, icons and strings | 680,435 | 0.68 | 4.76% |
| JNA native bridge | 165,992 | 0.17 | 1.16% |
| Other entries, signatures, ZIP index/alignment | 210,569 | 0.21 | 1.47% |

The compiled native library combines encryption, the database engine, legacy-format handling and vault utilities; this measurement does not attribute exact shares to its internal components. User vault data is separate from the APK.

## What changed

- Enable R8 code shrinking and resource shrinking. Compressed DEX content drops from 19,309,171 to 5,860,662 bytes; no product feature was intentionally removed. See the [Android optimization guide](https://developer.android.com/topic/performance/app-optimization/enable-app-optimization).
- Add `-PtargetAbi=arm64-v8a` for phones; leave it out to retain both supported ABIs. The phone APK contains 7,565,528 bytes of native libraries.
- Keep JNA and UniFFI reflection names, fields and callbacks. See [JNA Android guidance](https://github.com/java-native-access/jna/blob/master/www/FrequentlyAskedQuestions.md#jna-on-android). The compact developer build also preserves test-visible app/Kotlin/OkHttp APIs so an independent instrumentation APK can test the exact delivered application. Release has narrower rules and requires separate release acceptance.
- Preserve package ID, signing identity, database format, all feature sources and the existing cryptographic library bytes. Compare the DEX and arm64 library contents of compact universal/arm64 packages: they are identical.

## Acceptance and limits

The compact universal APK passes all 7 emulator tests, including encrypted persistence, draft recovery, idle timing, system Autofill, CRUD/Trash, WebDAV TLS/redirect handling and encrypted LAN sharing. The ARM64 APK is installed on Mi 10 / Android 13 and passes 5 non-UI tests (encrypted persistence, draft/idle, LAN sync and WebDAV). APK signature and 16 KB ZIP alignment checks pass. Generated APKs, checksums and logs remain under ignored `native-test-output/mobile/`.

The ordinary debug build remains available for development. The compact variant is still a debug-signed developer preview with isolated `nativepreview` identity; this size work is not production-signing or security-audit acceptance. MIUI blocks automated foreground input on the connected phone, so hardware UI/biometric/camera acceptance remains open.

The local legacy Flutter release APK is a three-ABI package, while the phone's old installation is another debug artifact. Neither is an equivalent release/ABI baseline for claiming a percentage reduction. The percentage above deliberately compares our previous and current delivered preview packages.

Build commands: [native Android README](../apps/android/README.md).

## 2.1.3 UI update

The clean, signed ARM64 APK is 14,552,960 bytes (14.55 MB), up 245,862 bytes from 2.1.2. Native libraries are unchanged; stored DEX grows to 6,105,267 bytes for the UI and recovery changes. Delivery builds run `:app:clean` before assembly: repeated incremental packaging can leave unused ZIP gaps that inflate the file without adding active code.

The 2.1.4 clean ARM64 UI refinement is 14,634,904 bytes (14.63 MB), an increase of 81,944 bytes from 2.1.3. It retains the same native encryption binaries and preview signing identity.

## 2.1.5 migration update

The clean ARM64 APK is 15,423,775 bytes (15.42 MB), up 788,871 bytes from 2.1.4. The addition includes CameraX live preview/analysis, restored editable legacy workflows and their supporting resources. It remains a compact debug-signed preview with the same package identity. Signature, ZIP page alignment and every native library's ELF LOAD alignment pass the 16 KB checks.

## 2.1.6 scoped update

The clean ARM64 compact artifact measures 15,423,783 bytes (15.42 MB). This increment changes Notes button styling and documentation fixtures; the detailed 2.1.5 component breakdown above remains historical. Signature and 16 KB ZIP alignment checks pass, with the scoped emulator evidence in [Android parity](ANDROID-LEGACY-PARITY.md#216-notes-action-alignment).

## 2.1.7 Notes/account refinement

The clean ARM64 compact APK is **15,440,179 bytes (15.44 MB)**, 16,396 bytes above 2.1.6. Signature, 16 KB ZIP alignment and all five native libraries' load-segment alignments passed. This presentation update adds adaptive account form styling; the older component breakdown remains historical. See the [scoped validation record](design/android-native/ACCOUNT-NOTES-REVIEW.md).

## 2.1.8 whole-page Notes scrolling

The clean ARM64 compact APK remains **15,440,179 bytes (15.44 MB)**. This update changes collection layout and navigation presentation only. See the [scrolling regression record](design/android-native/NOTES-SCROLL.md).
