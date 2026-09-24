# Native mobile implementation and acceptance

The new clients share the V2 Rust security core and encrypted formats. iOS uses SwiftUI (iOS 16+, phone/tablet); Android uses Kotlin/Compose (API 24+, phone/tablet). Both clients open on Passwords. Android follows the original Accounts → Codes → Wallets → Notes → Settings order; iOS retains its existing Passwords → Notes → Codes → Wallets → Settings tabs. Chinese is the initial UI language; English is selectable. Tools and backup/sharing are secondary navigation. Wide layouts use a sidebar/rail. Existing Flutter clients remain available until migration and release gates pass.

## Implemented source

- SQLCipher storage and authenticated document encryption; no plaintext secret preferences. Device-only biometric key wrapping (Keychain / Android Keystore). Clipboard expiry, background lock and protected app switching.
- Passwords, additional accounts/history, notes, TOTP and wallet credentials; search, categories, favorites/pins, edit drafts, soft deletion, Trash restore and separately confirmed permanent deletion.
- Encrypted draft recovery after background lock. A failed disk write retains the sealed payload in memory for retry; quitting before a successful write can still lose that draft. A damaged draft cannot block access to the main vault.
- Password generation/audit, TOTP setup-link/photo/camera import, wallet derivation and confirmed wallet replacement.
- Encrypted backup creation/import, legacy encrypted JSON/CSV reading, WebDAV metadata and explicit merge recovery; server and backup passwords are separate. Credentials for the configured server are stored inside the encrypted vault.
- Password AutoFill extension on iOS; authenticated Android Autofill service and save flow. A reported Android WebView domain is not treated as a verified app association: the destination and selected credential require explicit confirmation. Neither client submits login forms.
- V2 member roles, invitations, encrypted LAN exchange and discovery. Locking stops the server. Read-only shared entries expose their restriction; core authorization remains authoritative.
- Automatic read-only migration of supported legacy mobile SQLite records. All encrypted fields authenticate before an atomically populated new vault is published. Wrong passwords leave no empty replacement vault. IDs remain stable and original files are retained.
- Creation directly from an existing encrypted backup provides a migration route when SQLite migration is unsupported. Legacy shared-key envelopes still require the old client's authenticated export and V2 membership reauthorization; they are not silently promoted into new sharing authority.

## Evidence

| Scope | Observed result |
| --- | --- |
| Rust baseline for Android 2.1.5 | 25 security/migration/failure-path tests and strict clippy pass; source migration and sealed-draft tests are included in `crates/vault-core/tests/security.rs`. Newer changes require their own run |
| iOS build | Device/simulator Rust XCFramework and iOS application + credential extension compile |
| iPhone UI | Create vault → create note → Trash → restore → lock passes; background unfinished draft → unlock → resume/save passes |
| iOS unit checks | 9 unit checks pass, including request cancellation generations and interaction/idle timing; encrypted persistence, rejected incorrect backup password, no plaintext canaries on disk, corrupt draft isolation, failed draft-file write recovery, WebDAV metadata/path/status handling pass |
| iOS AutoFill | Provider enabled through simulator Settings; Safari local login → PasswordVault → cancel → new request → authenticate → select → username and nonempty password returned to webpage passes, without submitting login |
| Android build | arm64/x86_64 APKs compile; ELF load alignment is 16 KB; instrumentation runs on the available API 37 16 KB emulator |
| Android 2.1.5 core/UI | All 22 instrumentation tests pass on the final APK; three credential/security tests also pass in dark mode and at 1.3× font scale, plus the targeted wallet-restore rerun. See [exact scope](ANDROID-LEGACY-PARITY.md#final-preview-package-evidence) |
| Android physical device | Xiaomi Mi 10 / Android 13: ADB installed and launched isolated preview 21002; 5 tests pass for encrypted persistence, draft failure recovery/idle timing, local sync and TLS WebDAV. The compact 21007 ARM64 update passes 11 non-UI tests, including migration, recovered password history, generator options and QR decoding; after unlocking, MIUI denies instrumentation foreground starts and ADB input with `INJECT_EVENTS`; foreground UI, camera and biometrics are not yet accepted |
| Wide layouts | iPad landscape sidebar/editor test passes; Android 2560 × 1600 with 1.3× font scale passes the create/delete/restore/lock flow |
| Android AutoFill | A separate native login app requests system Autofill; vault authentication + explicit selection fills the username without submitting |
| Android network | TLS WebDAV metadata/path/redirect checks pass; authorized WebSocket sync transfers encrypted packets, viewer writes are rejected and locking stops the listener |

Generated logs, screenshots, databases and APKs stay in ignored local output. XCTest result bundles and Android instrumentation reports are the test evidence; build success alone is not an acceptance result.

## Remaining gates

- Complete representative hardware/older-OS, VoiceOver/TalkBack, additional rotation/large-text cases, camera cancellation and biometric cancellation/invalidation/device-lock testing. The emulator/tablet evidence above covers only the tested configurations.
- Test old **production-signed** app upgrades on physical devices. The successful preview-to-preview Android update and unchanged encrypted files do not establish production signing continuity or every legacy migration. Production package identifiers are preserved; preview identifiers are deliberately separate. Never replace or delete a user's source vault to force an upgrade.
- Provision iOS App Groups/credential-provider capabilities and sign distribution builds using an eligible developer team. A local automatic-signing attempt was rejected by Apple because the selected team lacks an eligible program membership; both target profiles are unavailable. Unsigned device-architecture compilation passes, but there is no installable signed iPhone build. Android production APK/AAB needs the original signing key. Private signing material is excluded from source.
- Legacy sharing migration must preserve the original identity and permissions or explicitly reauthorize membership. Unsupported/unauthenticated source databases are retained and surfaced to the user.
- Store submission, independent security review, remaining standalone Web/OPFS parity and the broader release gates in `TODO.md` are separate workstreams. Flutter removal remains gated on replacement acceptance; these preview clients do not establish production readiness.

Build and test instructions: [iOS](../apps/ios/README.md), [Android](../apps/android/README.md).

## Local master password policy

Android/iOS accept any nonempty local master password without a minimum character count, character-class rule or strength score. Confirmation must still match. Creation, password changes and creation from a backup use the same local policy. The core retains its bounded-input resource limits; Argon2id, authenticated key wrapping and SQLCipher storage remain unchanged. Independently exported backup files retain their existing passphrase policy.

## Current preview artifacts

Android version **2.1.6**, code **21008**; iOS remains **2.1.1**, build **3**. The compact Android APK is produced at `apps/android/app/build/outputs/apk/compact/app-compact.apk`; the local delivery copy and SHA-256 are in ignored `native-test-output/mobile/`. Preview package IDs use the `nativepreview` suffix and preserve existing installations. This is a test build, not a production release.

The native mobile CI workflow is authored in `.github/workflows/native.yml`. The local results above do not establish a remote CI result; record the relevant PR run separately after it executes.

Interaction review: **9.1/10** (weighted 9.08) for the verified mobile core flows, after fixing cancellation races and false idle locking. This score excludes untested hardware, full accessibility, signed upgrades and release readiness.

Android delivery now uses R8 and a phone-specific ARM64 package: **15.42 MB** (2.1.5), compared with the previous 36.43 MB universal debug package. See the [measured APK breakdown](ANDROID-APK-SIZE.md).

Android 2.1.3 restores the legacy account-card visual language and adds a separate Xiaomi Notes-inspired note workspace. See [UI reference and acceptance](ANDROID-UI-REFRESH.md).

Android 2.1.4 adds unified collection scrolling, grouped credential details and observable biometric UI state. The final compact APK passes 12 emulator tests plus 3 dark-mode and 3 large-text checks; these biometric checks validate presentation/state synchronization, not physical fingerprint authentication.

The 2.1.4 interaction review scores the verified Android collection/detail/security scope **9.2/10** (weighted 9.17), with no blocking issue. This is separate from the earlier mobile-core score above and excludes hardware authentication, full accessibility and old-OS device acceptance.

Android 2.1.5 restores direct editable credential forms and legacy collection/transfer workflows. See [migration parity](ANDROID-LEGACY-PARITY.md) for current evidence and the separate hardware gates.

The 2.1.5 Android migration review is **9.1/10** (9.135 weighted). The final 22-test run, dark/large 3+3 checks and 11 physical-device non-UI checks pass; real vault bytes are preserved. Hardware scanning/fingerprint and the release gates above remain open.

## Preview 2.1.6 interface consistency

The Notes Add button now shares theme colors, contrast and the 18dp rounded shape with Accounts, Codes and Wallets. The note cards and reading layout retain their separate design. The clean ARM64 compact package passes two light-mode screenshot/design tests and one dark-mode screenshot/creation test; signature and 16 KB ZIP alignment checks pass. No physical-device update was performed for this increment. English README captures use an English interface and fictional English content on both Mac and Android; the Chinese note screenshot is refreshed for the shared button style.

The iOS delete/restore UI flow now waits for asynchronous persistence and navigation dismissal before changing tabs, then asserts the selected tab before opening Trash. Both lifecycle flows pass three local iterations each; CI retains failed `.xcresult` bundles for diagnosing older simulator behavior. This does not add retry-on-failure or skip the restore assertion.
