# TODO and progress

This is a prioritized work list, not a release-date promise. Completed source work is recorded in [CHANGELOG.md](CHANGELOG.md); production blockers remain tracked in [SECURITY_MODEL.md](docs/SECURITY_MODEL.md).

## Native migration

- [x] Mac direct creation and in-place account/authenticator/wallet editing; continuous rendered Markdown editing with scoped regression coverage. See [Mac field parity](docs/MAC-MOBILE-PARITY.md).
- [x] Integrate locally bundled Milkdown in WKWebView, with list continuation, caret/history, encrypted save/lock/source handover and scoped native-window acceptance. See [editor evidence](docs/MARKDOWN-EDITOR-EVALUATION.md); physical input methods, accessibility and older/Intel hardware remain separate gates.

- [x] Selected Native Notes direction; native SwiftUI Mac workspace and Rust security core.
- [x] Universal arm64/x86_64 build targeting macOS 13; TypeScript/Preact extension and independent encrypted browser vault.
- [x] Native encrypted storage/backup, legacy backup readers, records/TOTP/wallet utilities, V2 sharing core, and negative-path tests.
- [x] Owner accepted the Mac everyday workflows after legacy-restore, full-row click, hover, and Tools-group refinements. Device/security gates remain separately tracked.
- [x] Distinct extension connection states, revocation/re-pair flow, Edge Beta registration, port-preserving capture, and synthetic page fill/capture checks.
- [x] Implement default-on login reminders, per-site exceptions, account-count badges, explicit confirmation and ephemeral pending data; worker regression tests and the ego lite independent-vault login/save/fill flow pass.
- [x] Same-origin iframe/form-less login reminders, editable save confirmation with password reveal, and saved-account navigation into Mac with separate Fill; scoped DOM, worker and signed-helper evidence is recorded in [browser acceptance](docs/BROWSER-ACCEPTANCE.md).
- [x] Verify simultaneous Edge/ego lite native connections and native account fill without automatic form submission; user confirmed Personal Team signed Touch ID unlock.
- [x] Record a controlled empty-vault UI JavaScript heap baseline for legacy Flutter and the new client.
- [ ] Complete Chrome UI acceptance, full process/GPU memory comparison with matching populated fixtures (including import/password changes), remaining biometric failure paths, physical WebDAV and LAN checks.
- [ ] Finish standalone Web parity (sharing/WebDAV/QR and themes/localization).
- [x] Implement authenticated read-only migration of supported legacy mobile SQLite records and encrypted-backup migration; retain original files. This does not complete all legacy database/sharing formats.
- [ ] Complete automatic legacy desktop SQLite/Web OPFS discovery and migration, plus remaining legacy-sharing identity/permission acceptance.
- [ ] Complete distribution signing/notarization and original-signing-key upgrade acceptance; local development signing is separate evidence.
- [x] Implement Android Compose and iOS SwiftUI preview clients with encrypted lifecycle, editing, draft recovery, backup/WebDAV, system Autofill and V2 sharing.
- [ ] Complete mobile hardware/older-OS/accessibility, signed-upgrade and legacy-sharing migration acceptance; see [mobile matrix](docs/MOBILE-IMPLEMENTATION.md).
- [ ] Remove legacy Flutter only after replacement clients preserve all required features and data paths.

The detailed capability and validation matrix is in [NATIVE-MIGRATION.md](docs/NATIVE-MIGRATION.md). Legacy production issues below remain open until all affected clients are replaced or fixed.

## Developer-preview and legacy progress

- [x] English-first documentation and bilingual UI.
- [x] Contributor onboarding, issue templates, and repeatable checks.
- [x] Responsive workspace, shared visual system, and synthetic-data widget gallery.
- [x] TOTP QR scanning flow and validation in the 1.2.0 source; physical-camera acceptance remains pending.
- [x] Legacy Flutter Android/Web/extension release pipeline with certificate and checksum verification; native distribution gates remain open.
- [x] Author native/mobile build and test workflows; verify the PR's remote CI results separately before treating them as passing evidence.
- [x] Scan the current source/staged changes and every fetched Git ref for secrets before this preview PR; only an explicitly labelled public UI-test fixture needed an allow comment. Historical signing-key rotation and release-continuity acceptance remain open in the security model.
- [x] Publish clear security limitations and synthetic-data testing guidance.

## Before production use: legacy and project-wide gates

The following items remain open for affected legacy clients or project-wide review. Native V2 already has encrypted browser storage without a persisted master password, root-preserving password rotation, randomized backup envelopes and boundary tests; those implementations do not close the legacy findings or an independent audit.

- [ ] Remove persistent plaintext master passwords from browser storage; use a verified unlock flow and controlled key lifetime.
- [ ] Make master-password changes transactional, re-encrypt every relevant record, and preserve sharing identity.
- [ ] Version encrypted backup formats, use random salts and a password KDF for new writes, and retain tested legacy reads.
- [ ] Review local sync authentication, replay protection, CORS, membership enforcement, and metadata exposure.
- [ ] Verify extension message boundaries, pending-save storage, subdomain matching, and lock behavior.
- [ ] Validate SQLite loading, Android autofill, backups, restore, and upgrade paths on physical devices.
- [ ] Complete an independent security review and publish its scope and findings.

## Broader reach

- [ ] More languages and accessibility validation.
- [ ] Validate store packaging and additional platform delivery; maintain the existing [release procedure](docs/DEPLOYMENT.md) and signing continuity.
- [x] Record fictional native Mac/Android UI evidence and scoped reviews; see [Mac](docs/design/macos-native/INTERACTION-AUDIT.md) and [Android](docs/ANDROID-LEGACY-PARITY.md). The [legacy widget gallery](docs/images/README.md) remains separately labelled.
- [ ] Produce a short installed-app demonstration with synthetic data after the current editor is accepted.
- [ ] Complete signed iOS device acceptance; Windows/Linux desktop runners remain unimplemented.

## Documentation maintenance

- [x] Adopt the root documentation and `docs/` guide structure defined in [AGENTS.md](AGENTS.md).
- [ ] Update these priorities and the relevant design, architecture, page, or deployment guide whenever behavior changes.
