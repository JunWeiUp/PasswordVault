# Mac interaction review

**Latest increment:** Mac 2.0.9 Milkdown/editor-toolbar review: **9.1/10** in the bounded editing and toolbar scope, with no open P0/P1 findings. The broader journey score below describes the earlier increment.

**Final scoped result: 9.2/10 — passes the owner's strictly-greater-than-9 threshold.** The unrounded weighted score is 9.225. This result covers the Mac journeys exercised below, using a new synthetic vault and a local mock backup service. It is not an overall production-readiness, security, or full-platform score.

## Scope and evidence

This review preserves the selected **Native notes** direction, native SwiftUI controls, macOS 13 support, and all existing record types. The goal is to make the everyday journey predictable: unlock, find or create information, organize it, delete and recover it, then back it up.

The initial assessment uses three screenshots supplied by the owner in this review and the current native source. The screenshots show the category sidebar, a WebDAV backup list, and a generic unlock error. They contain private information and are intentionally **not copied or quoted** here. Source inspection identifies implementation risks; it is not evidence that a flow has been exercised. A final score requires a fresh, synthetic vault and captured runtime evidence. Existing user vaults and active windows must remain untouched.

This is an interaction assessment, not a security certification, a claim of complete accessibility compliance, or acceptance of the full platform migration.

## Scoring contract

The owner requested a score strictly greater than **9/10**. The same rubric applies before and after changes; passing is not obtained by rounding 9.0 upward.

| Dimension | Weight | What earns the score |
| --- | ---: | --- |
| Task completion | 30% | Core journeys complete with clear next actions; no dead controls, empty records, or ineffective search |
| Recovery and data confidence | 25% | Edits survive navigation and locking; deletion is recoverable; backup and merge behavior is explicit and verified |
| Navigation and organization | 15% | Selected location is visible; categories can be managed; record creation and movement match the current context |
| Feedback and error recovery | 15% | Saving, success, empty states, validation, and failures explain the state and the next action |
| Keyboard access and readability | 15% | Essential tasks work by keyboard; controls have meaningful names; text and actions remain legible at supported window sizes |

Acceptance additionally requires zero unresolved P0 or P1 findings in the reviewed journeys, runtime evidence for each numbered step below, and no visible private data on the locked screen. Untested capabilities are listed separately; they do not receive assumed credit.

**Initial provisional score: 6.4/10.** Task completion 6.5, recovery/data confidence 6.0, navigation 8.0, feedback 5.5, and keyboard/readability 6.0 yield 6.375. This is a bounded heuristic baseline, not a completed runtime audit. Keyboard and accessibility evidence is incomplete, so that dimension remains conservative.

## Journey and initial findings

| Step | Journey | Initial health | Evidence and acceptance condition |
| --- | --- | --- | --- |
| 1 | Unlock or create a vault | Needs clearer recovery | Owner screenshot shows an error combining password, file, and permissions. Wrong-password feedback must be specific enough to act on, without revealing internal paths or sensitive details. First-run and password-change forms must explain length and mismatch validation. |
| 2 | Find information | Partly working | Sidebar selection and hierarchy are clear. Source shows Trash bypassing the search predicate. Search must actually filter every destination that displays it; a no-result state must offer a clear reset. |
| 3 | Create and edit | Needs flow repair | Native note editing has autosave and a dedicated edit/preview switch. Source shows new password/code/wallet records being saved before an editor is opened. Creation should open a type-appropriate draft, with no persisted record on Cancel; note creation should focus its editable title or body. |
| 4 | Manage categories | Recently implemented; needs runtime evidence | Source has add/delete controls, confirmation, empty-category persistence, and preservation of notes. Selecting existing categories while editing should be straightforward; category deletion must leave active and trashed notes intact after relaunch. |
| 5 | Delete and recover | Recovery affordances exist | Trash and permanent-delete confirmation exist. Verify search, restore destination, cancellation, and that a successful deletion/restore has visible feedback. A failed save must not move the selection as if it succeeded. |
| 6 | Back up and restore | Incomplete decision information | Owner screenshot lists filenames with no time or size. Source directly merges a remote backup when Restore is clicked and does not first flush pending note edits. Show metadata, explain merge behavior before mutation, preserve current drafts, and report the result. |
| 7 | Configure and return | Mostly coherent structure | Security, appearance, browser, and backup groups are recognizable. Verify keyboard focus, settings persistence, busy states, and that failure reverts controls or clearly indicates unsaved settings. |

## Initial prioritized findings and fixes

The findings in this section describe the baseline. Their final disposition is recorded in the reassessment; they are not an unqualified list of still-open defects.

### P0

No P0 issue is established by the available evidence. This does not establish absence of security or data-loss defects.

### P1 — must close before the interaction score can exceed 9

1. **A visible search can have no effect.** In `AppStore.visibleItems`, Trash returns before text filtering. Apply the query after the destination/deleted-state filter. Test two trashed records, an exact match, no results, clearing, and restoration.
2. **Non-note creation begins by persisting an empty record.** `AppStore.newItem` saves all record types, while only new notes receive an editing state. Start password, authenticator, and wallet creation in a draft sheet. Save only valid drafts; Cancel must leave item count unchanged. Invalid authenticator input must stay in the form with an actionable message rather than opening a broken detail view.
3. **Backup/merge can race pending edits.** Export and import entry points do not await pending note writes. Flush before both operations and stop if any draft remains unsaved. Test an edit followed immediately by export/import and an injected write failure. Never report backup success for a document missing the latest accepted edit.
4. **Remote restore provides too little decision context.** A row action directly merges a selected file. Confirm the selected backup with its known date/size and explain the actual rule: add missing records and update records only when the backup is newer. Name the action “Merge backup” where space permits. Show the imported/updated count; retain the current list and passphrase on failure so retry is possible.
5. **Error text does not identify a useful next step.** The supplied unlock screenshot and the common `report` method combine unrelated causes. Map known failures to safe, contextual messages: incorrect master password; unsupported/corrupt file; server authentication; timeout/offline; or local write failure. Do not expose raw FFI, SQL, paths, or server response bodies. The recovery action should be available next to the relevant input.

### P2 — finish the everyday workflow

- **Backup metadata:** show localized date/time and file size below the filename, newest first. Use server modification time when valid; if filename timestamp fallback is used, make its source explicit. Missing metadata must say “Unknown” rather than imply zero bytes or the current date. A malformed metadata field must not hide an otherwise valid backup.
- **Form structure:** keep persistent labels above server address, username, server password, backup folder, and backup-file passphrase. Placeholder-only fields become ambiguous once filled. Separate connection management from backup operations visually.
- **Categories:** offer existing categories in record metadata, while retaining an explicit path to create one. Category deletion explains that it removes organization only, preserves notes, and does not restore trashed items. Renaming is a useful follow-up; deletion/recreation should not be the normal correction path.
- **Notes:** retain one clear body-editing path. Distinguish the metadata editor from the Edit/Preview control, so two controls labelled Edit do not appear to perform the same action.
- **Save state:** display a failed/unsaved state with Retry if automatic persistence fails; do not leave an indefinite “Saving…” state. A successful state must follow a confirmed write.
- **Empty states:** distinguish a new category, an empty Trash, and no search results. Include an appropriate action, such as New note or Clear search, rather than generic prose alone.
- **Keyboard and accessible names:** name icon-only favorite, reveal, menu, and clear-search controls explicitly; preserve Return/Cancel conventions and visible focus. Test Tab order and keyboard access to category management, tools, record actions, and WebDAV rows.
- **Window resilience:** test the requested design viewport and the app's minimum supported size, light/dark appearance, long category names, long filenames, and larger text. No essential action may be clipped or pushed outside a non-scrollable section.

## Runtime evidence required for reassessment

Use only a newly created synthetic vault, synthetic server credentials, and a local mock WebDAV service. Do not reconnect a user's saved WebDAV service. Save and inspect the actual captured screenshots in flow order; do not substitute a design mockup for a live screen.

1. Locked screen; wrong password; successful unlock. Capture the safe error and prove the same window can recover.
2. Notes workspace; empty category; add category; duplicate-name validation; new note; editing and saved state; search match and no result.
3. Password, authenticator, and wallet New flows: show the draft editor; prove Cancel leaves counts unchanged and valid Save opens the new record.
4. Category deletion confirmation and resulting All notes state; lock/unlock or relaunch proves preservation and persistence.
5. Move a fixture record to Trash; search in Trash; restore it; confirm permanent-delete cancellation and confirmed deletion on a disposable record.
6. WebDAV connection form, loading, populated list with different dates/sizes, missing metadata, empty list, safe connection error, merge confirmation, successful result, and wrong-passphrase recovery. Capture at least one long filename.
7. Settings validation, keyboard focus, and return to the prior workflow. Capture minimum-window layout and dark appearance where their behavior differs.

Automated core and model tests can substantiate persistence, merge rules, failure atomicity, and metadata parsing. They supplement rather than replace runtime evidence of visible controls and navigation. Touch ID hardware, screen-reader behavior, real server compatibility, and browser extension integration require their own explicitly reported evidence.

## Reassessment

The independent design reviewer inspected the captured files, revisited the changed source, and checked the implementation agent's recorded runtime steps. The reviewer did not operate the owner's active window or inspect the owner's vault. All accepted new evidence was captured during this review in a separate app instance with fictional records and a localhost-only mock service.

The same rubric yields:

| Dimension | Weight | Final score | Evidence supporting the score |
| --- | ---: | ---: | --- |
| Task completion | 30% | 9.3 | Notes can be created, edited, found, categorized and recovered. Password/wallet creation starts in a cancellable draft; authenticator validation keeps the user in the form. WebDAV upload and merge complete with observable results. |
| Recovery and data confidence | 25% | 9.4 | Real fixture-directory write failure produces an unsaved state and a working Retry. Tests cover pending edits before export/import, cross-record saves, category preservation, settings rollback, and permanent removal across lock/reopen. |
| Navigation and organization | 15% | 9.1 | Category add/delete, expanded Tools, restored-record selection, matching search selection, and compact connected-server presentation form coherent paths. Existing categories can be selected in metadata forms. |
| Feedback and error recovery | 15% | 9.2 | Wrong-password and invalid-key messages are inline. Backup time/size, empty lists, server-login failures, merge rules, zero-change results, and direct retry of the same backup are explicit. WebDAV results remain visible above the scroll area. |
| Keyboard access and readability | 15% | 8.9 | Observed shortcuts, basic Tab order, Escape/Return, and named accessibility controls work. Narrow-window toolbar actions remain visible; dark interaction text has been corrected. Full screen-reader navigation and larger system text remain untested. |

Weighted total: `9.3 × .30 + 9.4 × .25 + 9.1 × .15 + 9.2 × .15 + 8.9 × .15 = 9.225` → **9.2/10**. The passing result is not a rounding of 9.0. No unresolved P0 or P1 finding remains in the reviewed journeys after the final toolbar screenshot and the regression checks.

### Closure of the five initial P1 findings

| Finding | Final disposition |
| --- | --- |
| Ineffective Trash search | Closed: destination filtering now precedes the shared text predicate; runtime search/clear/restore and model tests support the behavior. Final search also clears a detail that no longer matches. |
| Empty non-note records created before editing | Closed: unsaved drafts open a type-specific editor; Cancel preserves counts. Invalid authenticator input remains in the form. Saving disables form changes and cancellation until completion. |
| Backup/merge racing pending edits | Closed: export/import await draft persistence and fail if it cannot complete. Cross-record save tests cover the additional case where saving a password must not strand a pending note. |
| Unclear remote restore decision | Closed: the confirmation identifies the file and available metadata, explains newer-record merge and Trash-state behavior, and reports changed-record counts. It does not promise that merging can never move an item to Trash. |
| Generic errors without recovery | Closed for reviewed failures: master-password, authenticator, local-write, server-login, and backup-passphrase failures now have relevant feedback. Correcting the backup passphrase and Retry targets the same file. |

Additional refinements were verified: the category chooser is legible, note metadata uses a distinct “Note information” action, empty-state actions sit beside the explanation, server configuration collapses after connection, save failure can be retried, and the narrow-window toolbar keeps essential actions visible.

### Captured journey, in order

The evidence directory is a local, Git-ignored test artifact: `native-test-output/ux-review/`. The links below resolve in the reviewed working copy. Original capture bytes are retained; the capture API supplied JPEG data for some files with a `.png` suffix. The [runtime observation log](../../../native-test-output/ux-review/QA-STEPS.md) separates observed behavior from automated checks and untested capabilities.

1. **Unlock — healthy.** A wrong password produces a specific inline message, keeps all vault content hidden, and allows a successful retry. The fixture was reopened during the run to check persistence.

   ![Step 1: Inline unlock error with no vault data visible](../../../native-test-output/ux-review/02-unlock-error.png)

2. **Find and edit — healthy.** A new note enters editing with title focus, and completed writes have explicit status. A no-result query offers Clear search next to its explanation and clears stale detail content in the final build.

   ![Step 2: Final no-result state with a nearby clear action](../../../native-test-output/ux-review/32-empty-state-final.png)

3. **Create a credential — healthy.** Password and wallet cancellation leave record counts unchanged. An invalid authenticator key remains editable with a precise message; correcting the fixture key saves the record. The final category chooser remains readable.

   ![Step 3: Authenticator validation inside the draft editor](../../../native-test-output/ux-review/10-totp-validation.png)

4. **Manage categories — healthy.** Duplicate-name validation is specific. An empty category can be created; deleting it explains preservation of notes and Trash. Runtime and tests cover the resulting All notes view and persistence after reopening.

   ![Step 4: Category deletion explains that note contents remain](../../../native-test-output/ux-review/08-remove-category.png)

5. **Delete and recover — healthy within the tested scope.** Trash search works, permanent-delete confirmation can be cancelled, and Restore returns to the restored record. Successful permanent removal and absence after lock/reopen are model-tested; the final destructive UI click was not exercised in this review.

   ![Step 5: Restored note selected in All notes](../../../native-test-output/ux-review/25-trash-restored.png)

6. **Back up and merge — healthy with the local mock service.** The list shows timestamps and sizes, preserves long filenames, and distinguishes unknown metadata. Merge confirmation explains the actual rule. A plaintext fixture adds one record; an encrypted upload succeeds; a wrong backup passphrase retains the list and offers direct retry; correcting it reports zero changes instead of an ambiguous success. Server-login and empty-folder states were also exercised.

   ![Step 6a: Backup metadata supports choosing a file](../../../native-test-output/ux-review/14-webdav-metadata.png)

   ![Step 6b: Final backup-passphrase error remains visible with direct retry](../../../native-test-output/ux-review/34-webdav-retry-final.png)

   ![Step 6c: Successful retry explicitly reports that no records changed](../../../native-test-output/ux-review/35-webdav-restored-final.png)

7. **Configure, handle failure, and continue — healthy within the tested scope.** Security and appearance navigation work. A real write-permission failure on the synthetic vault shows unsaved changes and Retry; restoring permissions successfully saves the latest edit. Final narrow-window and dark-mode evidence shows every primary toolbar action without wrapping or a missing lock action.

   ![Step 7a: Actual fixture write failure exposes a retry action](../../../native-test-output/ux-review/29-save-failure.png)

   ![Step 7b: Final narrow dark toolbar with distinct text and button colors](../../../native-test-output/ux-review/36-final-dark-toolbar.jpg)

### Readability and keyboard evidence

Observed keys were Command-N, Command-K, Return for unlock/category submission, Escape for draft and destructive-confirmation cancellation, Tab from authenticator title to category, and Tab through WebDAV address → username → server password → folder. Recorded accessibility names cover category add/remove, Tools expansion state, favorite, reveal password, more actions, clear search, and the file-specific merge buttons. These observations do not establish full VoiceOver compliance.

The original dark blue text was too dim on the dark surfaces. The final source separates a brighter dark-mode interaction color from the filled-button blue. Calculated from the source color values, the interaction text is approximately 6.73:1 against the dark sidebar and 6.12:1 against its selected background; white text on the retained primary-button blue is approximately 5.50:1. The final screenshot confirms the intended distinction, including the edit/preview segment. The 4.5:1 ordinary-text benchmark is drawn from [W3C's contrast guidance](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html); these calculations are targeted checks, not a measurement of every native control or a full compliance claim.

### Evidence quality and remaining limits

- The unreadable initial authenticator thumbnail was rejected and replaced with a readable 620 × 620 capture. An unrelated empty-window capture was rejected and removed. Earlier contrast, empty-state and feedback-position screenshots are superseded by final evidence.
- The file named `33-webdav-progress-final.png` actually shows a completed list refresh. It is accepted as completion feedback only, not proof of a transient progress state. Busy/cancel behavior was source-reviewed; a reliable in-progress screenshot was not obtained.
- The implementation run reports 16 passing Swift tests, including four metadata-parser tests. The reviewer inspected the relevant test cases and the recorded run summary; compilation alone was not used as interaction evidence.
- The narrow-window capture is 1000 pixels wide. It supports the observed layout at that size, not every screen configuration or enlarged-text setting.
- Real WebDAV-provider compatibility, Touch ID hardware, full VoiceOver traversal, larger system text, Intel hardware execution, and browser-extension integration remain separate acceptance work. No production-security certification is implied.

### P2 follow-ups

These are refinements rather than blockers to the reviewed everyday journeys:

- Add a category Rename action with the same preservation and permission rules, so correcting organization never requires deletion/recreation.
- Consider an explicit Favorites view and adjustable list sorting once representative users have exercised the current organization flow; avoid adding more default sidebar destinations prematurely.
- Complete an assistive-technology and larger-text pass, and verify long-running network cancellation with an observable progress capture.

The original selected visual direction remains intact. The score improvement comes from repaired task completion, safe recovery, clear outcomes and readable controls, rather than additional decorative UI.

## Follow-up: legacy restore, row hit areas and Tools boundaries

Independent Dart-produced legacy WebDAV/fixed-salt/SHA-256 backup fixtures restore through the native core, preserving all fixture fields. Wrong-password/corruption tests preserve existing records; repeated import adds no duplicates. The native WebDAV UI was exercised with the Dart WebDAV file against localhost: incorrect password → per-file retry → five restored records. The new password sheet explains the original legacy master password, and does not overwrite the new-backup passphrase field.

The implementation run clicked the far-right blank area of a Settings row and observed the destination change. Expanded Tools was inspected in light/dark themes and at a 1000-pixel window width; record types remain reachable by scrolling. The independent interaction designer inspected those captures and found no boundary/reachability blocker. Evidence is in the ignored `native-test-output/legacy-restore-qa/` directory.

A shared hover wrapper now decorates native buttons and menu/link triggers, respects disabled and Reduce Motion states, and leaves event handling to the native controls. Hover received source inspection; the available native automation did not produce reliable pointer-only hover evidence. Do not describe the captures as full runtime hover verification or treat the earlier 9.2 score as a new rating for this follow-up.

Validation: 18 Rust tests, 16 Swift tests, repository checks, strict Swift formatting, and a universal arm64/x86_64 build passed. The real user backup was not decrypted by the agent.

## Mac 2.0.9: Milkdown and detail toolbar

A separate review covers locally bundled Milkdown, list continuation, middle-of-document typing, undo/redo, final-input handover to source/lock, and consistent adaptive toolbar controls. The two initial P1 findings (source-mode handover and reuse of a closing snapshot during lock) are fixed and covered by tests. The latest Mac suite passes 57 tests, including 10 editor tests with real WKWebView cases and simulated Chinese composition.

Isolated native-window evidence covers direct preview editing, Return in a list, Command-Z / Shift-Command-Z, native Edit-menu Undo, source switching, rendered tables/tasks/code, long-document caret scrolling and retained focus after typing at the end. Chinese dark and English light toolbars fit a 500-point detail pane, and the More menu remains actionable. Delayed refocus rechecks that the current native responder still belongs to the editor so it cannot reclaim a user-moved title/search focus.

The interaction review scores this scope **9.1/10**: continuous editing 9.2, save/handover 9.3, toolbar organization 9.2, long-document focus 8.8 and verified keyboard behavior 8.6. This is a scoped design assessment rather than a measured reliability rate. The [current notes](current-notes.png) and [account details](current-password.png) images contain only fictional fixture data.

Physical input methods, complete VoiceOver coverage, macOS 13/Intel hardware, process/GPU memory profiling, WebKit process-termination recovery and production signing remain outside this acceptance. See [the editor evidence](../../MARKDOWN-EDITOR-EVALUATION.md).
