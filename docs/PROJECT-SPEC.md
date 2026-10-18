# Project specification

## Positioning and goals

PasswordVault is a local-first home for passwords, TOTP codes, secure notes, and wallet credentials. Its primary workflow is to find an entry, use a credential, and return to the previous task. The default language is English, with Simplified Chinese available before and after unlock.

The product aims to keep related credentials together, make search and everyday tools easy to reach, adapt to compact and wide screens, and let users rehearse backup and recovery. It remains a developer preview with unresolved [security blockers](SECURITY_MODEL.md); available features are not evidence of production safety.

## Native migration scope

The approved target is SwiftUI on Mac/iOS, Kotlin/Compose on Android, and a lightweight standalone Web/Chromium client with a shared Rust core. Mac and extension come first. macOS 13+ (arm64/x86_64), iOS 16+, and Android 8+ are targets; only the Mac and browser source increment exists today. Mac defaults to Simplified Chinese and supports English. Mac personal notes support rich text, images and encrypted file attachments; mobile/Web protect the new format as read-only summaries. Shared notes retain text compatibility. See [rich notes](RICH-NOTES.md). The selected design is [Native Notes](design/macos-native/README.md).

Current Android source removes shared-vault management, invitations and LAN synchronization. Existing records and encrypted backup metadata remain readable, with historical read-only permissions retained. App switches preserve the main session until idle expiry; screen/manual locking and process-restart authentication remain in place. See [mobile implementation](MOBILE-IMPLEMENTATION.md).

See [implemented paths, evidence, and pending parity](NATIVE-MIGRATION.md). Native biometric, network, browser-fill, and lower-OS/hardware acceptance must be distinguished from compilation and unit tests.

## Browser-to-Mac synchronization without opening Mac

Status: implemented in the local preview (browser 2.2.9 / Mac 2.0.12), with scoped fixture acceptance. After configuring password-based access in the browser extension, users can save credentials into the local Mac vault without launching or unlocking the Mac UI. This includes a fully quit Mac main application, not just a closed window. The Mac application and its local integration must be installed; this requirement does not introduce a hosted sync service.

- Scope: confirmed login/signup captures and manually added accounts flow from the extension to the Mac vault. Explicit password authorization also permits current-site account lookup/reveal/fill, numeric toolbar badges, and optional Mac startup unlock. General two-way synchronization of notes, wallets, deletions and settings is outside this increment.
- Setup and any required password re-entry must be available in the trusted extension UI. For an existing Mac vault, authenticate with its master password; do not silently create an unrelated browser vault. The password verifies access to the existing vault; it is not stored.
- The native messaging helper performs append-only writes without displaying the Mac UI. A helper-owned login-Keychain grant remains valid until disabled, revoked or invalidated by a password change; there is no timed expiry. Save-only authorizations continue while the UI is locked and never enable reads/fills. New setup explicitly requests additional scopes; old grants require password reauthorization. See [browser authorization](BROWSER-AUTHORIZATION.md). See the [security boundary](SECURITY_MODEL.md#background-save-authorization).
- Report pending, syncing, synced and failed states. Mark a record synced only after a durable Mac-vault write is acknowledged. Retain encrypted pending records on failure, retry without duplicates, and preserve conflicting credentials rather than silently overwriting them.
- Lightweight operation is required: use an on-demand helper that exits after its request, no resident daemon/editor/WebView or browser WASM vault for native sync, and no periodic sync alarm when the queue is empty. Measure peak process memory on synthetic small and populated vaults.
- When Mac opens later, the synchronized records must appear in its existing vault. Concurrent desktop edits and background writes must not lose data or corrupt the vault.

Acceptance requires disposable-vault end-to-end tests with the main app fully quit, browser restart, desktop reopening and concurrent writes, plus wrong passwords, changed passwords, revoked authorization, unavailable helper, interrupted writes and lost acknowledgements. Validate supported Chromium browsers separately. See [current behavior](BROWSER-OFFLINE-SAVE.md) and [implementation plan](../TODO.md).

## Legacy functional scope

| Area | Current source scope |
| --- | --- |
| Accounts | Multiple accounts and domains, search, categories, tags, favorites, pins, history, and trash |
| Codes | Manual TOTP entry and Android/iOS QR scanning; single-account SHA-1, 6-digit TOTP with the supplied refresh interval |
| Other entries | Secure notes and wallet records, including address, network, mnemonic, and private-key fields |
| Tools | Password generation and weak, reused, or expired password checks |
| Autofill | Android autofill service and experimental Chromium Manifest V3 extension |
| Data portability | CSV import, JSON/CSV export, and WebDAV backup/restore with existing encryption options |
| Collaboration | Experimental local discovery, LAN synchronization, and shared vaults |
| Presentation | Light/dark/system themes, responsive navigation, English and Simplified Chinese |

HOTP, other TOTP algorithms/digit lengths, and Google Authenticator migration QR codes are outside the current scanner scope. Manual key entry remains available when camera access is denied. The product has no managed cloud account service or automatic hosted synchronization.

## Platform scope

| Target | Current boundary |
| --- | --- |
| Android | Runner, autofill integration, and signed APK/AAB pipeline; physical-device checks remain necessary |
| iOS | Runner and camera integration exist; device, signing, and release validation remain pending |
| Web | Experimental Flutter build; browser storage and WebDAV CORS limitations apply |
| Chromium extension | Experimental unpacked extension; storage, message boundaries, and actual browser behavior need validation |
| Native desktop | New SwiftUI macOS client builds for arm64/x86_64; macOS 13/Intel hardware and Touch ID acceptance remain pending. No Windows or Linux client exists. |

## Acceptance and maintenance

Changes should preserve existing vault data and identifiers, describe failures accurately, and support the relevant empty, loading, error, and recovery states. Use synthetic fixtures for screenshots, imports, backups, and tests. Security-sensitive changes require migration and failure-path evidence.

Use [TODO.md](../TODO.md) for priorities and progress, [CHANGELOG.md](../CHANGELOG.md) for completed changes, [DESIGN.md](../DESIGN.md) for presentation, and [ARCHITECTURE.md](ARCHITECTURE.md) for implementation boundaries. Installation instructions remain in [GETTING_STARTED.md](GETTING_STARTED.md).

## Personal relay synchronization

Mac is the personal-vault authority; Android/iOS retain editable offline replicas and synchronize through common-relay. The browser bridge is unchanged. See [personal relay scope and behavior](PERSONAL-RELAY.md).

Device groups provide self-service creation, trusted QR/text invitations, code comparison, explicit optional manager grants, roster/presence, rename/remove, leave and disband. Mobile and desktop management permissions are equal. Membership does not grant vault access: Mac vault authorization remains separate. Legacy manual provisioning requires explicit local migration and separate administrator revocation. Production service enablement and physical-device pairing remain deployment/acceptance gates.
