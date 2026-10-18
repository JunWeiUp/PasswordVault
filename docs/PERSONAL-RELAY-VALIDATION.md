# Personal relay validation

This is a local implementation and test-build delivery, not a public release or installation over a real vault.

## Automatic admission and compact invitation update

- Mac universal Release build and iOS ARM64 simulator build pass; Android compact Kotlin compilation and repository checks pass.
- Five Swift application tests pass against the latest disposable loopback relay, including default automatic short-link admission without vault authorization, optional manual manager approval, durable failure/restart drafts, revocation and managed WebSocket transfer.
- Five Java tests pass with no skips: automatic short-link resolution/join across restart, wrong-application rejection, manual lifecycle, shared membership rejection vectors (including delegated manager escalation/tampering), authenticated invitation encryption vectors and offline preparation.
- Both SDK snapshots preserve `prepareJoin` and `group.changed` integration. Source and protocol fixture hashes are recorded in `SOURCE.json`.
- This update is source-only: no installed app, real vault or production configuration was changed. Real camera scanning and hardware acceptance remain unverified. Upgrade every existing group member before using automatic invitations.

## Device-group redesign validation

- `bash tool/check_native.sh core`: formatting, native Rust suites and clippy pass. New detach tests cover stale-scope rejection, pending-edit preservation across restart/rebind, encrypted archive retention and transaction rollback when archive writes fail.
- Mac: 77 selected XCTest cases completed with 2 explicit public-WSS fixtures skipped and no failures. The unchanged BackgroundSyncTests suite was excluded after its separate full-suite attempt stalled; this increment does not claim a complete background-browser regression run.
- Four new Swift group tests also pass against a disposable loopback service with self-service enabled only for the fictional `passwordvault` identities. They cover create/join, stable retry drafts, matching codes, independent vault authorization, actual managed WebSocket delivery, welcome-revision handling, ordinary-member denial, last-manager protection, rename, removal, invalidation, mobile-created groups, disband and local data retention.
- Three Java SDK tests pass, including shared signed membership vectors and a real loopback create/approve/rename/remove/disband flow. This verifies the Java SDK, not Android camera/Keystore integration on hardware.
- Mac universal Release, Android compact ARM64 and iOS ARM64 simulator builds pass. UI validation uses an isolated Mac QA bundle and a newly seeded fictional vault outside Documents. Shared input controls follow app language; setup shows create/join guidance instead of a misleading paused state.
- No real vault, installed application, production service whitelist or existing relay device is modified. The production endpoint was enabled in the subsequent device-install follow-up below. Real camera pairing, Android/iPhone device installation and physical background behavior remain unverified in this increment.

## Executed

- Rust native checks: original security/storage/sharing/rich-note/background-browser suites plus seven personal-relay integration tests and one transactional journal-failure unit test. Coverage includes first activation backup, bidirectional commit, immutable operation retries, pending-edit overlay, conflicts and keep-both, incremental cursors, multiple replicas, restart, deletion tombstones, missing/tampered attachment rollback, revoked senders, and browser background-save capture. Clippy and formatting checks pass.
- Browser regression: 38 Node tests, TypeScript/WASM checks and build pass. The extension transport and authorization code are unchanged; no extension package is delivered.
- Repository checks: repository validator, 34 Python tests and two legacy extension tests pass.
- Mac: universal Release build passes. Existing full XCTest run passed 79 tests with two intentionally skipped opt-in WSS tests. Pairing tests explicitly cover matching verification codes, authorization before trust, single-use challenge replay rejection, revocation and wrong-key credential rejection.
- Explicit real-WSS Swift application-adapter test passed against a newly registered isolated PasswordVault test group: mobile-to-Mac item commit, Mac-to-mobile encrypted large-file delivery, and offline/reconnect catch-up. The separate test was enabled through `TEST_RUNNER_PV_RELAY_QA_CONFIG`, not counted as the default skipped test.
- Android: compact arm64 APK and instrumentation build pass. Android 8 / API 26 emulator passed the replication/Keystore and core lifecycle tests after fixing the older AtomicFile implementation’s first-write semantics. An Android emulator with 16 KiB pages passed core replication/deduplication and real Keystore configuration storage, plus existing core lifecycle tests. Testing identified and fixed R8 removal of the libsodium JNA proxy interface.
- Real Mac Swift ↔ Android Java application-adapter interoperability passed over production WSS using a second isolated group: a 315,000-character note crossed the encrypted file path, an Android-created item committed on Mac, and Android received a Mac acknowledgment record.
- Android UI: created an isolated fictional vault, navigated Settings → Relay sync, and inspected the status, registration and pairing controls in a captured screenshot.
- iOS: arm64 simulator app/AutoFill build passes; device and simulator Rust libraries compile. An isolated iOS 26.5 simulator passed 14 tests (three explicit-network fixtures skipped by default), covering lifecycle, draft, interaction, WebDAV and shared pairing using simulator ad-hoc signing (Keychain requires app entitlements). A separate real Mac ↔ iOS simulator WSS test passed the 315,000-character encrypted-file transfer, iOS item submission and Mac confirmation record. This does not establish iPhone signing or hardware acceptance.
- Six temporary relay test devices were revoked after the WSS checks; local test credentials and the emulator credential file were removed. Existing application devices and real vaults were not changed. The newly created iOS QA simulator was shut down and deleted after testing.

## Limits

- Initial iOS discovery encountered a CoreSimulator/Xcode version mismatch. The pending system discovery subsequently refreshed the stale service; runtime verification then completed in a newly created isolated simulator. Real-device provisioning remains separate.
- Android full Lint also reports existing generated UniFFI Cleaner API checks and existing Compose context/StateFlow usage findings. The new credential reader's API-33-only call was replaced with a bounded API-26-compatible read loop. No broad Lint suppression was added.
- Android 8 hardware acceptance, real camera pairing, iPhone AutoFill and signed-device delivery are separate acceptance gates. Background operation under OS suspension is not guaranteed.
- Business queues, deduplication metadata and attachment retention are conservative and currently unpruned. Long-duration large-history/large-attachment memory and storage stress testing remains outside these functional checks.
- Tests use fictional data and private temporary configuration. Full logs and test builds remain in ignored local output/build directories; credentials are never part of the repository.

## Device-install follow-up

Production now enables `passwordvault` self-service alongside all three existing applications. Configuration and online SQLite backups were retained; the service binary and existing devices were preserved. An isolated production test passed creation, encrypted compact invitation resolution, automatic admission, rename and encrypted WebSocket delivery, then disbanded its test group. A failed creation draft can use **Retry creation** without resetting identity.

Mac 2.3.1 build 26 and Mi10 2.3.1-preview build 23002 were installed and launched. The previous applications and encrypted data were backed up; four Mi10 persistent data files matched byte-for-byte after installation. Mac retains its existing ad-hoc signing mode. Actual camera pairing and Touch ID remain separate hardware acceptance checks.

The 250 phone was updated in place to officially signed 2.3.1 build 23002 and launched. [Device signing workflow](https://github.com/JunWeiUp/PasswordVault/actions/runs/39119191412) succeeded for commit `482e2f1`; source revision, checksums, package, 16 KB ZIP alignment and matching installed certificate were verified before `adb install -r`. No public Release was created. Its non-debuggable private vault was not read or reset.

## Presence fix and isolated test host

The prior clients gated their WebSocket connection on vault pairing and unpaused synchronization; new group members therefore stayed offline, and the roster was only a snapshot. Mac/iOS and Android now connect unlocked, valid group members independently of vault authorization and refresh presence every five seconds. Unpaired/paused clients do not invoke vault export, receive or file-inbox operations. Disconnects clear online indicators; legacy credential behavior is retained.

Five Swift group tests passed from a copied `/tmp` source/build tree under the separate `PasswordVault QA` identity. The presence regression covers automatic join, both members online without initialized replication, pause, lock/offline and unlock/reconnect. An isolated Android emulator test also exercises the application adapter and real production WSS using disposable group members, then disbands the group. Mac Release, iOS simulator and Android compact builds pass. Repository checks pass.

The initial in-repository XCTest host caused a Documents access prompt. It was stopped, and `tool/test_macos_isolated.sh` now copies the required sources/resources/archive into `/tmp`, changes the test bundle identity/display name and keeps test vaults temporary. No TCC reset or broad Documents authorization is needed. Intentional user-selected imports/exports remain governed by macOS file-access permissions.

## Master-password-protected relay credentials

Two Rust integration tests cover encrypted-at-rest canaries, locked access denial, restart, password rotation, export exclusion, wrong-vault/tamper rejection and invalid-update preservation. Four Swift migration tests cover unlock-only migration, repeat launches without Keychain reads, denied/cancelled legacy access, failed write/retry identity preservation and corrupt-file refusal. Five group tests and the default pairing tests exercise the new storage lifecycle; opt-in external-fixture tests remain explicitly skipped without their credentials.

Android emulator checks cover migration from a synthetic Keystore file, restart after removing the old key, encrypted identity storage, and real-WSS presence without vault authorization using a disposable test group. Legacy storage is removed only after encrypted write/readback verification, with noninteractive failure allowed to retain an unused legacy copy. Actual user Keychain migration can still require one explicit authorization of the old item; no new Keychain credential item is created by the relay client.

## Device-list access switch (Mac 30 / Android 23005 / iOS 12)

- Disposable local relay: the Swift group suite passes six tests, including encrypted grant/ack, phone-to-Mac edits, revoke, stale grants, restart and re-grant. The revoke case also passes with an unverified management list, proving local denial does not require a roster refresh.
- The combined Swift relay suite passes 14 tests with two opt-in external fixtures skipped. Android instrumentation passes five reported tests (the external large-payload fixture remains opt-in), including wrong authority/recipient/group, revoke, conflicting or stale revision, durable state and lock rejection. Synthetic production presence groups are disbanded after testing.
- Mac and arm64 iOS Simulator builds and repository checks pass. These checks do not authorize any real vault replica and do not establish real iPhone, Touch ID or production-security acceptance.
