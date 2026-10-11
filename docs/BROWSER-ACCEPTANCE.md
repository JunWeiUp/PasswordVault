# Browser acceptance baseline

## Edit a saved account in Mac (browser 2.0.9 / Mac 2.0.8 build 12)

Native popup rows open the selected Mac record; a separate Fill button keeps website filling explicit. Requests contain only origin, record ID and optional additional-account ID. Trusted-extension-page, native-mode, current-tab, pairing and core website/account guards run before navigation. Mac checks pending additional-account deletions after refresh, clears filters, selects the record and uses a new navigation token to support repeated scrolling to the same additional account. Independent mode keeps its original fill behavior.

Validation: **47 Swift tests**, **29 Node tests**, native Mac/browser checks and signed build pass. The popup runner now covers **13 grouped DOM scenarios**: the previous eight confirmation scenarios plus primary/extra edit routing, old-Mac update errors without stale success, separate Fill and independent-mode Fill.

An isolated synthetic vault was exercised through the real code-signed debug helper: pairing, primary-account opening, closed-window reopening, minimized-window restoration, additional-account positioning, scrolling away and repeating the same request, invalid origin/token and locked denial. UI observations confirmed the requested record and scroll target. Tests did not navigate or edit real user credentials. The designer scored this increment **9.2/10** within that scope.

Mac 2.0.8 build 12 retains the installed signing identity and Touch ID entry. Ego lite was toggled off/on and reloaded to 2.0.9 from the existing unpacked directory; its popup detects the locked Mac correctly. If the vault locks between listing and clicking, unlock and select the account again.


## Save-confirmation layout (2.0.8)

The built popup passed eight grouped scenarios in ego lite at 380×600 with a fictional, in-memory runtime bridge. The reproducible runner is `apps/browser/tests/popup-scenarios.mjs`, with `tests/fixtures/popup-confirmation.html` served from the browser app root after building. It does not write to a real vault.

- 30 saved accounts remain folded below the confirmation; input fields and both actions fit without horizontal scrolling.
- Revealing, editing both credentials and saving sends the edited values; background polling retains them.
- Keyboard activation of the eye does not submit; Tab then Enter cancels, and polling does not revive it.
- Window blur and visibility changes conceal plaintext; switching pending records conceals the replacement.
- Expiry and locking remove captured credentials from the DOM.
- A source-tab Return button, two-line long origin and save error together still leave fields/actions visible; failure retains values and conceals the password.
- Independent mode and manual capture share the same confirmation layout.

The interaction-design review scored this increment **9.2/10** within the tested scope. The existing unpacked installation was updated, toggled off/on and reloaded in ego lite; its extension page reports **2.0.8**, the brand asset loads, and the native connection finds the locked Mac without an error.

All 28 existing worker/core tests and the native browser build check also pass. The background capture, origin/TTL guards, encryption and fill scripts are unchanged in this increment; this focused UI run does not repeat every site's authentication flow.


## Version 2.0.7 save-reminder matrix

Save capture now runs in the main document and same-origin HTTP(S) frames. Only the main document displays the reminder, so closing a login iframe cannot remove it. A standard form uses its validated submit event; a form-less panel requires an explicit login control or Enter within a bounded, unambiguous account/password group. The reminder asks the user to confirm login success and never saves automatically. If no stored account matches, there is no fill button, but a new login can still produce a save reminder and the toolbar pending badge.

Production content-script bytes were exercised in ego lite isolated worlds with a synthetic runtime bridge and fictional credentials. All **41 browser scenarios** passed:

| Group | Cases | Result |
| --- | ---: | --- |
| Capture + fill icon + main-page notice | 12 | Standard form; div login; email; telephone; autocomplete section tokens; initially revealed password; reveal toggle; dynamically mounted inputs; two account groups; OTP preceding password; iframe removed after login; two-second SPA/root replacement |
| Keyboard login | 2 | Native form Enter and form-less Enter |
| Invalid or inappropriate targets | 16 | New password; OTP; unmarked plain text; readonly; disabled; hidden; transparent ancestor; inert; disabled fieldset; empty account; invalid email; invalid form with nested button text; nested link; nested tab; ambiguous passwords; disabled login action |
| Non-login events | 1 | Clicking fields/tabs and dispatching an untrusted click do not capture |
| Reminder state/actions | 5 | No stored match still offers saving; site opt-out; locked-vault explanation without retained credentials; duplicate suppression; review action and dismissal |
| Explicit icon filling | 5 | Form, email, telephone, revealed password and iframe: correct username/password targets, no automatic submit |

All **28 Node worker/core tests** passed. New coverage includes metadata-only top-frame notices from a same-origin child, no vault write until the trusted popup confirms, badge aggregation across frames, and cancellation while capture waits in the queue, its first tab lookup, or a later asynchronous check. Dismissal, lock, site disabling and cross-origin navigation cannot revive pending credentials after completion. Same-origin redirects remain supported, with existing TTL, permission and duplicate checks retained.

The final production bytes passed the same full matrix after review. The reviewer scored this increment 9.2/10 within that scope, with no remaining blocking finding. The installed ego lite extension was re-enabled/reloaded and confirmed as 2.0.7.

The fixtures are in `apps/browser/tests/fixtures/login-matrix.html`. These tests do not authenticate a real Boardmix account or establish all-site, cross-origin-frame, closed-shadow-root, full input-method/accessibility or performance acceptance. The real Boardmix structure was inspected in the preceding increment; this increment reproduces its iframe and form-less login behavior locally without sending credentials to that service.


## Version 2.0.6 embedded login and revealed passwords

Boardmix `/app/home` embeds its password login in a same-origin `/user/login/` iframe and omits a form element. This explains why the old top-frame-only content script showed no field button. Password visibility toggles also change the input to text, which previously removed it. The new script supports same-origin embedded documents, remembered password fields and explicit current-password text fields. It avoids nearby div/SVG reveal controls and pairs a formless username only in the nearest unambiguous group with an explicit account label.

TypeScript checking, production packaging and 23 Node tests passed, including exact frame/document/top-page binding and cross-origin frame rejection. The previous eight real-DOM/mock-bridge scenarios passed again. Five additional fixture scenarios covered embedded-document targeting, labelled formless account/password filling without submission, reveal/conceal and eye-button coexistence, rejection of new-password/one-time-code fields, and initial current-password text fields. On the actual Boardmix layout, the built script with a synthetic bridge displayed a correctly positioned button and account menu; no credential was filled or submitted there. These are layout and synthetic-data results, not a real-vault or Native Host end-to-end claim.

The interaction-design reviewer scored this increment 9.2/10 within the tested scope. The Mac 2.0.6 build 10 app was installed with its existing signing identity, and the ego lite extension was re-enabled/reloaded with version 2.0.6 confirmed.

After updating the unpacked extension, reload it and refresh already-open login pages so all embedded frames receive the new content script. Cross-origin login frames remain excluded; existing toolbar and top-frame login-reminder behavior is unchanged.

## Version 2.0.5 password-field menu

TypeScript checking, production packaging and 21 Node tests passed. Backend regression covers metadata-only account lists, browser sender/document validation, offer expiry/replay and account identity, navigation rejection, and locking during a delayed delivery.

The actual built content script was injected into an isolated world in ego lite with a synthetic runtime bridge and fictional credentials. Eight real-DOM scenarios passed: target the second of two forms without submitting; reject a replaced input; reject an input moved into another form; cancel after same-origin SPA navigation; cancel delayed delivery after locking; fill only a formless password without modifying unrelated usernames; Escape dismissal; and no-match icon removal. The rendered account menu was visually reviewed. The real extension was disabled during this fixture test, then updated/re-enabled/reloaded; its installed version was confirmed as 2.0.5.

The picker uses short-lived, single-use offers bound to the tab, document, exact URL and account. Passwords are delivered only after explicit selection to that document; page navigation and field/form identity are checked again immediately before writing. Service-worker invalidation covers offers already awaiting delivery. No automatic form submission is performed.

The interaction-design review scored the three changed flows 9.1/10 within this tested scope, with no new delivery blocker. This score is not a substitute for broader platform or website acceptance.

This increment did not repeat a full native-host or independent-vault end-to-end fill through the newly installed picker. Broad third-party site layouts, custom reveal controls, iframe forms, closed shadow roots, VoiceOver and dynamic-site performance remain separate acceptance work. The older toolbar/native-host results below do not establish those new checks.

## Native fill

The installed 2.0.4 extension in Edge Beta and ego lite connected to the signed Mac 2.0.4 build 8. On the local synthetic login fixture, an explicitly selected `work@example.test` record filled the username and a nonempty password; no automatic form submission occurred. Password values were not written to the report. Earlier tests covered simultaneous connections, same-host port matching, navigation capture, save confirmation and independent-vault fill.

## Empty-vault UI memory baseline

This is a narrow renderer measurement, not total extension/process/GPU memory or a release performance gate.

- Browser: the same ego lite installation (0.5.1.11), unchanged during the run.
- Legacy artifact: local Flutter extension UI build 1.1.0+6, served from an isolated loopback origin.
- Modern artifact: 2.0.4 standalone UI, served from a second isolated loopback origin.
- Both interfaces reached their initial create-vault screen. No vault was created and no credentials were entered.
- Flutter semantics were enabled to confirm the screen was ready. After explicit garbage collection, Chrome DevTools Protocol `Runtime.getHeapUsage` provided this single baseline snapshot.

| Metric (bytes) | Legacy Flutter UI | Modern UI |
| --- | ---: | ---: |
| JavaScript heap used | 21,884,232 | 1,094,272 |
| JavaScript heap allocated | 23,543,808 | 1,835,008 |
| Embedder heap used | 792,888 | 685,760 |
| Backing storage | 6,980,855 | 48,455 |

The used JavaScript heap was approximately 20.9 MiB versus 1.0 MiB. A separate observation of the installed native-mode popup showed approximately 1.3 MiB used JavaScript heap before explicit GC; its state and measurement procedure differ, so it is not part of the paired comparison.

The legacy screenshot capture timed out, but its accessibility tree confirmed the create-password interface and the expected Dart/CanvasKit resources loaded. This measurement uses the old extension's UI assets over HTTP; it excludes its installed background worker, real vault workload, total renderer/GPU allocations, and the new Mac process. Do not use it to claim a percentage reduction in total product memory. A full comparison still requires identical populated fixtures, repeated runs, renderer/process attribution, and import/password-change scenarios. Temporary benchmark pages and servers were closed after sampling.

## Browser 2.2.4: offline and signup saving

- `bash tool/check_native.sh browser` and `bash tool/check.sh repo` passed. Browser suite: 32 tests, including persisted encrypted queue restart/tampering/failure retention, unavailable/locked capture and retry deduplication.
- Ego DOM checks passed: 8 existing popup scenarios, 5 signup scenarios (`signup-scenarios.mjs`) and 3 offline popup scenarios (`runOffline` in `popup-scenarios.mjs`). Signup uses a synthetic form matching the inspected AIACC username/password/confirmPassword structure; no real registration was submitted.
- Updated the existing unpacked extension and reloaded ego; runtime manifest reports 2.2.4 and the `offline-sync` alarm is registered. Native status is reachable/paired/unlocked; no synthetic credentials were written to the real desktop vault. Full offline-to-real-native-host delivery and Edge/Chrome reload remain separate user/platform acceptance.
- Device-key staging is not master-password protection; see [offline-save behavior and limits](BROWSER-OFFLINE-SAVE.md).

## Browser 2.2.5 — manual current-site accounts

- `npm --prefix apps/browser run release:local`, `bash tool/check_native.sh browser`, and `bash tool/check.sh repo` pass (33 browser tests).
- `runManualAdd` in `apps/browser/tests/popup-scenarios.mjs` passes for native/offline and independent mock modes: required empty fields, draft retention through polling/save failure, retry payload bound to the site, cancellation and navigation cleanup. The eight existing confirmation DOM scenarios also pass at 380×600.
- Updated `native-test-output/dist` and reloaded ego lite; extension management reports 2.2.5. These checks use fictional credentials and a simulated bridge; real Mac persistence and Edge/Chrome reload remain separate acceptance steps.

## Browser 2.2.8 / Mac 2.0.11 background account saving

- Rust: 30 tests pass, including new cold-start/locked-state append, strict-input, tampered/revoked grant, password-change, duplicate/conflict, deletion-retry and atomic receipt-failure rollback coverage; Clippy and formatting pass.
- Swift: 66 tests pass. Three helper/Keychain integration tests use disposable vaults, exercise absent and locked desktop owners, reject browser-supplied grants, deny a different executable silent Keychain access, reopen durable records and measure a 1,000-account fixture. The helper explicitly disables legacy Keychain interaction to prevent unexpected system prompts.
- Browser: 35 tests pass; native check, release build and repository checks pass. Real 380×600 mock-bridge DOM scenarios cover confirmation (8), manual addition (2), offline flow (3), existing-account navigation (5), and background setup/revocation (3). Retry status stays compact during confirmation so long origins/errors do not hide save/cancel.
- Local delivery: Mac 2.0.11 build 15 installed with the existing ad-hoc development signing mode; encrypted vault files were unchanged during replacement. The original unpacked directory was updated, and ego lite reloaded/verified 2.2.8. The installed extension discovered background-sync support with the main Mac app quit, and an empty queue had no sync alarms. No real master password was supplied or real account written during acceptance.
- Memory evidence and platform limits: [background saving](BROWSER-OFFLINE-SAVE.md). Installed Chrome/Edge credential delivery, physical login-Keychain locking, macOS 13/Intel and stable production signing/upgrades remain separate gates. Other open browsers need their own extension reload.


## Browser 2.2.9 / Mac 2.0.12 account access and startup unlock

31 Rust, 69 Swift and 37 browser tests pass, with 26 scoped real-DOM fixture scenarios. The real native helper/Keychain tests verify reads while the main app is absent, automatic startup unlock, unchanged UI lock during later reads, save-only/revoked denial, one-use challenge/replay rejection and a manual-lock race. A separate launcher fixture rejects desktop mode from a non-desktop parent. UI fixtures verify masked account rows, explicit reveal, late-response discard and current-site counts. Setup requires fresh explicit authorization; no real master password or account is used in automation. See [setup and remaining platform gates](BROWSER-AUTHORIZATION.md).

Local delivery for this increment: Mac 2.0.12 build 16 was installed with the prior ad-hoc development signing mode, preserving the encrypted vault files and retaining the old application. The original unpacked extension directory was updated; ego lite reloaded and reported 2.2.9, the new explicit authorization form, and no sync alarm for an empty queue. Real-profile grant reauthorization is left to the user; the agent did not enter a real master password or inspect real accounts. Other browsers need their own extension/page reload.
