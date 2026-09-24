# Native iOS client

SwiftUI, iOS 16+, iPhone and iPad. The app and Password AutoFill extension share an App Group; both use the Rust/SQLCipher vault. No Flutter runtime is linked. Debug uses an isolated preview bundle/group; Release retains the legacy `com.example.password` application identifier.

The 2.2.1 public download includes a simulator application and source, not a signed iPhone IPA. See [native release installation](../../docs/NATIVE-RELEASE-NOTES.md) for free personal provisioning, TestFlight/Ad Hoc options and remaining capability gates.

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
bash tool/build_mobile_core.sh ios
xcodegen generate --spec apps/ios/project.yml
xcodebuild -project apps/ios/PasswordVault.xcodeproj -scheme PasswordVault \
  -configuration Debug -destination 'platform=iOS Simulator,name=<available iPhone>' test
```

Open the generated project in Xcode for a physical device. Choose a team locally and provision **both** targets with Password AutoFill and the shared App Group. Do not commit signing identities, profiles or local team settings. Simulator builds do not establish App Store/device signing eligibility.

The main app closes its database session on background lock so the credential-provider process can open it. Pending editor content is sealed separately and presented for review after unlock. Camera/photo import and the system file picker are explicit user actions. A failed backup password does not create an empty replacement vault.

`PasswordVaultTests` covers encrypted lifecycle, unreadable/tampered drafts WebDAV parsing, request cancellation generations and real-interaction idle timing. `VaultFlowTests` covers create/edit/delete/restore/lock and background draft recovery. `AutofillSystemTest` is opt-in (`PV_SYSTEM_QA=1` in the test runner), changes only the simulator's provider setting, and requires the local login fixture to be opened in Safari beforehand. It checks cancellation followed by a new request and uses fictional credentials in the preview App Group. It must never run against a user's production vault.

See [mobile acceptance](../../docs/MOBILE-IMPLEMENTATION.md) for what has actually been tested and remaining hardware/release gates.
