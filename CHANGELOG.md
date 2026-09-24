# Changelog

## 2.2.0 — coordinated native release

- Deliver native Android, universal Mac development app, Chromium extension, standalone Web, iOS Simulator and source archives from one verified tag.
- Sign Android public APKs with the reviewed release certificate; keep the native vault isolated from legacy installations.
- Validate coordinated client versions, release identity, Apple archive permissions, APK metadata and complete asset checksums before publishing.
- Include refreshed Android Notes/account detail interfaces and whole-page Notes scrolling from the merged native updates.
- Document unsigned distribution boundaries: Mac is ad-hoc signed and not notarized; iOS device distribution is not included. Security and hardware acceptance gates remain open.


## Native Android 2.1.8 preview

- Scroll the Notes title, search, folders and collection tools with the note grid or list, including empty results. Keep bottom navigation and the New action available.
- Preserve grid/list positions and filters when opening a note or switching tabs.

## CI efficiency

- Run affected native/legacy platform jobs instead of rebuilding every client for any edit; retain repository, secret-scan and complete release gates.
- Remove duplicate feature-branch push runs and isolate PR metadata edits from code checks.
- Split browser builds onto Linux; cache Rust, npm, Gradle and the pinned WASM CLI. Compile only the packaged Android ABI and host iOS simulator ABI in CI, preserving full local defaults and iOS device-library compilation.

## Native Android 2.1.7 preview and README presentation

- Refine the Android Notes list and account editor while preserving the existing code, wallet and settings presentation. Consolidate note tools, improve card spacing, simplify account fields and make Save easier to find.
- Give full-screen account editing the same theme-aware system bars as note editing, removing the gray bands above and below the form.
- Restore a product-focused README with localized illustrated campaign covers, concise feature introductions and real native-client galleries. Keep preview status visible and move detailed validation matrices into expandable sections.

## Native Android 2.1.6 preview and documentation

- Align the Notes Add button with Accounts, Codes and Wallets using shared theme colors and an 18dp rounded shape; retain the separate notes layout.
- Use purely English interface and fictional-content captures in the English README. Keep the Chinese README screenshots localized, including the refreshed Notes button. Add reproducible English synthetic screenshot fixtures.
- Synchronize the iOS delete/restore UI test with completed persistence and navigation before switching tabs, and preserve failed CI test result bundles.

## Native Mac 2.0.9 preview

- Replace the rendered Markdown editor with locally bundled Milkdown 7.22.2. Continue lists on Return, retain a local caret, and use ProseMirror undo/redo while keeping direct preview editing and encrypted native autosave. Keep advanced Markdown source editing.
- Capture final editor input before source-mode changes, note switching, exports, locking and quitting; preserve source bytes on open and reject stale or read-only writes. Add real WKWebView and delayed-handover regression tests.
- Restrict the editor to local assets in a nonpersistent WebView with no network resources. Bundle third-party notices and retain literal unsupported HTML rather than executing it.
- Align detail-toolbar controls and hit areas, separate action groups, and adapt note tools to narrow Chinese/English layouts. Update both READMEs with current native screenshots and desktop setup.
- Audit migration plans and distinguish shipped preview functionality from remaining Web/legacy migration, hardware, distribution signing and independent security-review gates.

## Native browser 2.0.9 / Mac 2.0.8 preview

- Click a saved-account row in native mode to open that exact record in Mac for editing; retain a separate Fill action and independent-vault behavior. Locate additional accounts within their parent record, including repeated navigation.
- Authenticate the native request and revalidate website/account membership without transferring passwords. Reject stale navigation, deleted additional accounts pending autosave, invalid pairing and locked vaults. Restore closed or minimized Mac windows while preserving the existing signing identity.

## Native browser 2.0.8 preview

- Move login-save confirmation before saved accounts and reminder settings; collapse existing matches while reviewing a capture so account/password fields and Cancel save / Save stay visible.
- Add a keyboard-accessible eye button to reveal/conceal and edit the captured password. Conceal on window blur, visibility changes, save/cancel and record changes; keep edits through polling.
- Keep save errors beside the confirmation and preserve edited fields for retry. Validate the built popup in a synthetic 380×600 browser fixture, including long origins, return navigation and 30 matching accounts.

## Native Mac 2.0.7 preview

- Create notes, accounts, authenticators and wallets immediately, then edit their selected detail in place with encrypted autosave. Remove the creation/edit form sheet.
- Align detail fields with native mobile: primary/additional logins and history, linked TOTP and setup imports, email, multiple websites, expiry, complete recovery phrases, categories, tags, sharing, color, pin and favorite.
- Render Markdown while typing, hiding heading/emphasis/link/code syntax. Keep Edit and Preview states, direct click-to-edit, native selection, source-based undo/redo and composition-safe Chinese input. Keep Markdown source as an advanced action.
- Reject stale generation/derivation results after navigation or newer work. Preserve stable additional-account identities and synchronized credential histories.

## Native browser 2.0.7 preview

- Capture login attempts from same-origin embedded pages and unambiguous form-less login panels, including explicit login clicks and Enter. Keep save reminders in the main document after an embedded login closes or the page redraws.
- Preserve revealed-password identity and account matching across text, email and telephone fields; exclude OTP/new-password, hidden, transparent, inert and disabled controls. Respect native form validation even when clicking nested button text.
- Stamp capture cancellation before queueing; prevent delayed work from reviving dismissed, disabled, locked or cross-origin-abandoned credentials. Pending notices contain metadata only and still require explicit save confirmation.
- Pass 28 worker/core tests and 41 synthetic browser interaction scenarios; see `docs/BROWSER-ACCEPTANCE.md` for the matrix and scope.

## Native Mac / browser 2.0.6 preview

- Replace per-paragraph preview editors with one continuous native note text surface. Click to type, select across paragraphs, and use Command-Z / Shift-Command-Z or the Edit menu for undo/redo without interrupting encrypted autosave.
- Keep Markdown source and Unicode offsets intact while applying reading styles; preserve active input-method composition and isolate undo history per note.
- Recognize same-origin embedded login panels, including Boardmix, and explicitly labelled account/password groups without a form element. Preserve the field button when showing a password and avoid adjacent reveal controls.
- Keep cross-origin frames excluded; bind fill offers to both frame and top-page navigation. Mac build 10 and browser package 2.0.6 retain existing vault and signing identities.

## Native Mac / browser 2.0.5 preview

- Add a Mac-only Never idle-lock option while preserving manual, sleep and system-lock behavior and the existing encrypted storage format.
- Edit note titles and individual Markdown paragraphs directly in preview. Preserve multiline input, immediate-lock draft saving and shared-note read-only permissions.
- Add an account picker at the right side of matching website password fields. Require explicit selection, fill only the chosen form, and cancel stale requests after navigation, field replacement or vault locking.
- Mac build 9 retains the existing signing identity. Browser package metadata and unpacked manifest are both 2.0.5. Acceptance scope is recorded in `docs/BROWSER-ACCEPTANCE.md` and `docs/NATIVE-MIGRATION.md`.

## Native Android 2.1.5 preview

- Open accounts and wallets directly in editable grouped forms. Restore additional logins, independent histories, metadata selectors, complete recovery words and legacy TOTP login fields.
- Preserve long-list selection; clear hidden selections when searching/filtering; restore batch tags, colors, pin/unpin, four persistent sorts and shared-vault defaults.
- Restore generator character options and real-time QR scanning with cancellation-safe validation. Keep note-specific design and biometric state controls.
- Read legacy CSV aliases and optional trailing fields; add provider imports and native-encrypted CSV export. Existing weak legacy encryption stays read-only; complete native backups remain preferred.
- Migration regression and platform limitations are tracked in `docs/ANDROID-LEGACY-PARITY.md`.

## Native Android 2.1.4 preview

- Scroll account, code and wallet headings, search and filters together with their entries; preserve the list position and filter values when returning from details.
- Replace ambiguous biometric buttons with an observable On/Off switch, a separate renewal action and inline pending/failure feedback. Observe external disabling after password changes, including older Android preference notifications.
- Align account, code and wallet details with the legacy grouped-card design. Keep independent secret visibility, account-linked two-factor keys, additional accounts/history and complete wallet address copying; show numbered recovery words only on demand.

## Native Android 2.1.3 preview

- Restore the legacy Android palette, account cards, category/tag filters, favorite/sort controls and navigation order in the Compose client.
- Add an adaptive Notes grid/list with long-press actions, real timestamps, a yellow Add button, spacious reading/editing and secondary note metadata.
- Keep recovered edits visibly unsaved after Activity reconstruction; compare password-history changes against persisted records so primary/additional account history survives draft restoration and retries.
- Retain compact ARM64 packaging and the existing encrypted data format. Record actual acceptance in `docs/ANDROID-UI-REFRESH.md`.

## Native Android 2.1.2 preview

- Add R8 code/resource shrinking and single-ABI phone delivery, reducing the delivered preview APK from 36.43 MB to 14.31 MB; the equivalent dual-ABI compact package is 22.53 MB.
- Preserve native reflection boundaries, preview signing/data identity and instrumentable test APIs; retain a universal build option and unchanged cryptographic binaries.
- Update local/CI preview packaging commands. See `docs/ANDROID-APK-SIZE.md` for measured scope and acceptance.

## Native mobile 2.1.1 preview

- Remove the ten-character minimum for nonempty local master passwords in Android/iOS creation, password changes and creation from backups. Do not require character classes or a strength score; preserve password confirmation, authenticated encryption and existing backup-file passphrase policy.
- Add short-password creation/change/reopen/backup-restore regression coverage and exercise mobile create/edit/Trash flows with a one-character password.

## Native mobile 2.1.0 preview

- Add SwiftUI iOS and Compose Android clients using the Rust encrypted vault, with isolated debug identities and stable release IDs.
- Add mobile CRUD/Trash, draft recovery, biometric key wrapping, backup/WebDAV, TOTP QR import, wallet tools and V2 local sharing.
- Add platform Autofill with explicit credential selection, request expiry/generation checks, and no automatic form submission.
- Add authenticated, read-only legacy SQLite migration and atomic creation from encrypted backups; preserve source files on every failure.
- Keep active mobile editing from triggering idle lock; invalidate cancelled iOS AutoFill requests before asynchronous cleanup so an old request cannot fill or cancel a new one.
- Add mobile lifecycle, network and UI acceptance tests. Device signing, hardware biometrics, older OS/accessibility and legacy sharing remain release gates.

## Unreleased — native migration

- Mac 2.0.4 build 8 restores actionable native context/overflow menus by resetting their inherited primitive button style. Verified favorites, pinning, targeted row deletion and Trash restoration against a disposable fixture.
- Mac 2.0.4 build 7 adds row context-menu deletion for all entry types; Trash rows expose Restore and a separately confirmed permanent delete. Confirmations name the right-clicked item.
- Mac/browser 2.0.4 restores login reminders after SPA root replacement and delayed navigation, adds a one-hour idle option/default and authenticated browser activity refresh, exposes Delete on all entry detail types, and verifies encrypted storage of every record kind while unlocked.
- Mac 2.0.3 build 5 keeps the app and browser bridge running after closing the main window, restores the window on reopening, and preserves explicit Quit behavior. Personal Team signing and fingerprint unlock were validated locally; private signing files remain ignored.
- Local build 2.0.3 preserves multiple browser connections per extension identity, tests login reminders through redirects, adds patch-version release automation, and reports Touch ID Keychain signing failures accurately with a provisioned-build configuration. Touch ID hardware acceptance remains pending signing setup.
- In local native/browser build 2.0.1, match accounts on the exact hostname across ports, while preserving subdomain isolation and HTTPS downgrade protection. Disable extension-page modulepreload links that generated Chromium cross-world preload warnings; show the browser build version in the popup.

- Add default-on HTTP/HTTPS login submission reminders with persistent per-site disable exceptions, page banners, saved-account count badges and pending-login priority. Include explicit save confirmation, an extension-tab fallback for Chromium shells, duplicate suppression, and a short-lived in-memory queue with sender/origin/lock checks.

- Distinguish browser host registration, availability, vault locking, and pairing states; add shared connection guidance and retry to the extension popup and manager. Clear revoked pairing capabilities, avoid overlapping status requests, and register the native host for Edge Beta. Preserve custom website ports when capturing credentials on Mac. Add synthetic message-boundary and real-DOM fill/capture checks.

- Make settings navigation rows clickable across their padded width. Apply shared hover feedback to Mac buttons, menu triggers, and website links while retaining native keyboard/pressed behavior. Visually group expanded Tools with a border, background, separator, and indentation; keep Settings outside the group.

- Clarify legacy WebDAV restore with a per-file password sheet: old encrypted JSON requires the master password used when the backup was created. Add independent Dart-produced compatibility vectors for legacy WebDAV and manual exports, with field-preservation and failure-atomicity tests.

- Show WebDAV backup timestamps and file sizes, with explicit unavailable metadata, newest-first sorting, and filename/date search. Keep progress and contextual errors visible while scrolling; confirm merges and report changed-record counts, including no-op restores and passphrase retries.
- Start credential creation in cancellable draft editors; fix Trash search, save-before-backup ordering, cross-record autosave, and retry feedback. Improve category selection, empty states, keyboard focus, narrow-window controls, and dark-mode text contrast.

- Add persistent empty note categories with sidebar add/delete actions; deleting a category keeps its notes and flushes pending edits. Make the entire Mac Tools row toggle its navigation reliably.
- Add a SwiftUI macOS app following the selected Native Notes direction and a universal Rust/SQLCipher core with encrypted notes, credentials, TOTP, backups, sharing, and recovery drafts.
- Add a lightweight TypeScript/Preact MV3 extension and standalone browser vault with authenticated encrypted storage and on-demand page integration.
- Add native/WASM security tests, Swift state tests, reproducible build scripts, and a capability/validation matrix. Keep the legacy clients during the remaining platform migration.


User-facing changes are recorded in English. Versions follow Semantic Versioning; build numbers are recorded in `pubspec.yaml`.

## Unreleased

- Standardize project documentation with root design/progress guides and dedicated product, architecture, component, page, build-registry, and deployment guides; update bilingual navigation and migrated references.

## 1.2.0

- Scan single-account authenticator QR codes on Android and iOS, review the account details, and save them to Codes.
- Validate SHA-1 / 6-digit TOTP provisioning links, retain custom refresh intervals, and handle camera denial, invalid scans, repeated detections, and save retries.
- Use stored refresh intervals when generating and exporting codes, and wrap code cards on narrow screens.
- Expand sensitive-file ignore rules and document pre-commit privacy requirements in `Agent.md` and `AGENTS.md`.

- Publish regular GitHub Releases marked Latest, with draft and pre-release modes disabled. Existing release records can be reclassified without changing tags or assets.

## 1.1.0-preview.4 — 2026-09-09

- Responsive Accounts-first workspace with persistent search, keyboard shortcuts, compact navigation, and wide-screen tool shortcuts.
- Shared light/dark design system, revised setup and unlock forms, a responsive password generator, and adaptable account cards.
- Correct account-type selection, visible filter resets, keyboard-safe search, and guarded editor/generator routes while locked.
- Reliable default/additional-account copying with completion and failure feedback.
- Product-led English/Chinese documentation, an original concept illustration, and five reproducible Flutter widget captures using fictional data.
- Unified local/CI checks, reviewed-tag release dispatch, non-overwriting signing setup, build metadata, and complete release checksum verification.
- Publish verified preview packages directly on a version tag, without creating a draft; Android build number increases to 6.

Existing security release blockers remain open.

## 1.1.0-preview.3 — 2026-09-03

- English-first README, Chinese README, contributor guidance, and documented platform status.
- English and Simplified Chinese application catalogs with a persistent language selector.
- Internationalized browser extension messages and consistent PasswordVault branding.
- Original P-shaped vault icon across README, Android, iOS, Web, and Chromium, with reproducible platform exports.
- Pinned Flutter toolchain, repository validation, extension checks, and separated CI/release workflows.
- Signed release builds, checksum generation, and draft prerelease publication.
- Explicit security, privacy, licensing, and release-readiness documentation.
- Removal of tracked Android signing material and private development journals from the published history; rotation of the public release signing key.

## Private development history

The existing `v1.0.0`–`v1.0.4` tags were private development snapshots. They included vault management, TOTP, browser autofill, WebDAV backup, local sharing, trash, and password history. They were not independently audited production releases. Do not install old APKs as a supported release.
