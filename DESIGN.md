# Design

PasswordVault should make a repeated task easy to recognize: find an account, use a credential, and return to what you were doing. The redesigned source organizes that path around readable lists, persistent search, clear actions, and a quiet visual theme.

This document describes the current presentation redesign and the criteria for future UI changes. It does not establish production readiness. The storage, cryptographic, backup, and sharing limitations in [SECURITY_MODEL.md](docs/SECURITY_MODEL.md) remain open.

## Selected native Mac target

The owner selected **Native notes / 原生备忘录**, the first Mac concept. The SwiftUI workspace follows the [selected notes workspace](docs/design/macos-concepts/native-notes.png) and [native Mac design guide](docs/design/macos-native/README.md). The guide also includes password-detail, Touch ID unlock, and security-settings concepts; a concept image is not runtime acceptance evidence.

The Mac target uses a light native three-column workspace with Notes as its default destination, a cool gray sidebar, white reading surfaces, fine separators, and restrained blue actions. Preserve passwords, codes, wallets, and tools. Locked screens hide all record content. This target takes precedence over the existing Material presentation when implementing the new Mac client.

The native-specific sections describe the current client direction; the shared principles and retained Flutter presentation remain useful references. Implementation, local test results and device/release acceptance are tracked separately in [native migration](docs/NATIVE-MIGRATION.md).

## Native Android target

The owner requested alignment with the existing Flutter Android UI, except for a separately designed Notes experience inspired by Xiaomi Notes. Use `lib/core/theme/app_theme.dart` and `docs/images/vault-mobile.png` as the account/workspace reference: warm `#FAF9F6` background, `#315CE7` primary actions, white 18dp cards, category/tag filters and the original Accounts → Codes → Wallets → Notes → Settings order. Keep every visible menu/action functional.

Notes use a compact heading, folder selector, grid/list switch, text-first adaptive cards with real modification times, and the same primary-colored, 18dp rounded Add action used by Accounts, Codes and Wallets. Large fonts reduce the grid to one column. Reading and editing have wide text margins; formatting/preview remain secondary. Folder, tags and vault membership are in Note information. This is an inspiration-based design, not a complete clone of Xiaomi's attachment/audio features. See [Android UI acceptance](docs/ANDROID-UI-REFRESH.md).

Notes uses a single lazy scrolling surface in both grid and list modes. Its title, search, folders and collection actions are ordinary scrollable content; the grid header spans all columns. Empty results remain in that same surface. Bottom navigation and New remain available, and opening a note or switching tabs preserves the corresponding collection scroll state. The note reader retains its own navigation bar.

The scoped Notes/account refinement consolidates note tools into the folder row when space and selection state permit; batch selection remains available from the tools menu. Account editing uses neutral section headings, soft filled fields, restrained secondary actions and a clear Save button. Its full-screen window follows the page's system-bar colors and contrast in both themes. Keep all existing fields, reveal/copy/generate actions and cancellation behavior. This refinement does not restyle authenticator, wallet or settings pages.

## Product direction

The documentation takes inspiration from Clipy's product presentation: lead with the job a person needs to do, show the actual interface, and provide a short route to a first successful session. PasswordVault keeps its own vault-specific information architecture and brand; illustrations explain the product without posing as implementation evidence.

| Principle | Application |
| --- | --- |
| Find before configure | Start in Accounts; show search without opening a separate mode |
| Reveal the next action | Keep add, generate, copy, and lock controls discoverable; empty states offer a useful action |
| Adapt without relearning | Preserve destination order and labels across the sidebar and bottom navigation |
| Let content carry the screen | Use restrained surfaces, readable metadata, and blue emphasis for primary actions |
| Tell the truth about state | Show loading, errors, and completion; distinguish a clean password-health report from application security |
| Preserve compatibility | Change presentation without renaming app IDs, database identifiers, or legacy formats |

## Related implementation guides

See [PAGE-STRUCTURE.md](docs/PAGE-STRUCTURE.md) for navigation, responsive layouts, and interaction behavior, and [COMPONENT-GUIDELINES.md](docs/COMPONENT-GUIDELINES.md) for reusable widgets, dependencies, and accessibility requirements.

## Visual system

The app uses Material 3 with a warm light canvas, ink-colored text, blue actions, and a corresponding dark palette. It relies on platform typography without adding a network font dependency. Reusable theme and surface helpers provide consistent forms and panels.

| Token | Light | Dark |
| --- | --- | --- |
| Primary action | `#315CE7` | `#AFC2FF` |
| Canvas | `#FAF9F6` | `#171A21` |
| Card | `#FFFFFF` | `#12151B` |
| Main text | `#202634` | `#F0F1F5` |
| Supporting text | `#5D6575` | `#B6BECC` |
| Border | `#DFE1E7` | `#363D4B` |

Buttons use a 48-pixel minimum height and 14-pixel corner radius; inputs use 12-pixel corners, cards 18, and dialogs 20. Body sizes are 14/16, titles 16/22, and headlines 28/32, with system text scaling retained. Secrets and generated codes use monospaced treatment where it aids reading.

Use theme colors for meaning, including errors and selected states. Avoid adding decorative gradients, unrelated illustrations, or status badges to routine credential rows. The product illustration belongs in explanatory material, while the live interface prioritizes content and controls.

## Content and localization

English is the default, with 简体中文 available throughout the app. Write actions as concrete verbs, such as **Copy**, **Regenerate**, **Unlock**, and **Clear search**. Keep UI strings in ARB catalogs and preserve equivalent placeholders; never translate stored identifiers or user-entered data.

Keep error messages adjacent to the action or field that caused them. Do not put build-system details into routine user flows. Maintain concise preview wording where it affects a person's decision to trust the build; link detailed limitations from the README and guides.

## Review and validation

Review affected pages in both themes and languages, narrow and wide layouts, with synthetic data. Include empty, populated, loading, error, long-text, and enlarged-text states when relevant. Verify keyboard focus, clear labels on icon actions, screen-reader announcements for form errors, and useful feedback after copy or save.

Run the [documented checks](README.md#run-from-source) and relevant interaction tests. The [legacy image suite](docs/images/README.md) renders real Flutter widgets, but cannot validate platform clipboard permissions, biometrics, Android autofill, browser-extension boundaries, or device storage. Record those separately when tested on a real browser/device.

Further platform validation and security work remain in the [roadmap](TODO.md). Do not remove a release blocker based on presentation changes or screenshots.

## Source map

| Source | Responsibility |
| --- | --- |
| [`app_theme.dart`](lib/core/theme/app_theme.dart) | Theme, typography, component colors and shapes |
| [`app_components.dart`](lib/core/widgets/app_components.dart) | Reusable presentation components |
| [`vault_workspace_page.dart`](lib/features/vault/presentation/pages/vault_workspace_page.dart) | Responsive navigation, list state, search, tool entry points, settings |
| [`lock_page.dart`](lib/features/vault/presentation/pages/lock_page.dart) | Setup/unlock form and authentication feedback |
| [`password_generator_page.dart`](lib/features/vault/presentation/pages/password_generator_page.dart) | Responsive generator and copy/fill feedback |
| [`app_en.arb`](lib/l10n/app_en.arb), [`app_zh.arb`](lib/l10n/app_zh.arb) | User-facing language catalogs |

## Brand assets

See [BRANDING.md](docs/BRANDING.md) for the icon source, platform exports, and reproduction commands. Keep the English and Chinese README galleries synchronized and use synthetic vault data in all captures.

README presentation leads with a warm ivory, navy and cobalt campaign illustration, followed by a concise product introduction, real native interfaces and platform setup. The cover is promotional art, not a simulated screenshot. Keep localized cover copy and live interface captures separate: the English README uses English UI and fictional English content; the Chinese edition uses Chinese assets. Preserve readable text and navigation outside the image for accessibility. Keep preview status visible; collapse detailed validation matrices and historical-client material instead of burying product discovery in them. Artwork briefs live in [README campaign prompts](docs/design/readme/PROMPTS.md).

## Native Mac interaction feedback

Notes use one continuous editable surface inside the SwiftUI workspace, with no paragraph button, editing card or Done action. The selected Markdown replacement is locally bundled **Milkdown 7.22.2** in WKWebView; it is currently in integration/acceptance. CommonMark/GFM and ProseMirror own document structure, list editing, selection and history. Do not reintroduce a separate hand-written hidden-character/source-offset editor. Plain-text notes retain their AppKit text surface.

Keep headings, emphasis, lists, task items, tables and code readable while hiding Markdown syntax. Edit and Preview are explicit modes; clicking an editable preview enters Edit at that location. Ordinary text/link clicks keep editing; opening an external link is an explicit native context-menu action. Maintain one outer scroll surface, system typography, light/dark appearance and keyboard-reachable controls. Read-only shared notes and Trash stay read-only, including paste, task-item changes and undo commands.

Opening a note must preserve its original Markdown without writing a normalized copy. Actual document edits use the CommonMark/GFM serializer and may normalize supported formatting; arbitrary Markdown dialect fidelity is not implied. Keep raw Markdown under the secondary source action. Entering source mode waits for the rendered editor's final input snapshot before displaying a writable source editor. If handover fails, retain the last acknowledged content, report the failure and rebuild the rendered editor rather than opening a stale writable snapshot.

Autosave must not replace the active document, move the caret or reset ProseMirror history. Chinese composition and cross-paragraph copy/paste/undo/redo need native WebKit checks, not only DOM fixtures. Note switching and locking invalidate old messages and drain the final snapshot before completing encrypted persistence; closing hides the web surface immediately. A completed close snapshot remains available until the native save queue consumes it. Leaving the note or locking discards editor DOM/history after handover. Loading or process failure must never be interpreted as an empty note to save. The previous NSTextView review scores do not certify this replacement.

Never disables only the Mac idle timer. Its description must distinguish this from screen lock, sleep and explicit Lock, which still lock the vault. Do not silently change an existing user's preference.

Website password fields with saved matches expose a small PasswordVault button on their right. Its account menu shows service and username without a password. Selection fills only the selected form and never submits it; Escape dismisses the menu. Navigation, changed fields and observed lock state cancel in-flight fills. Button/menu placement must remain inside the viewport and accommodate nearby reveal controls where detectable.

Settings and sidebar row labels fill their available width and define their hit region after padding. Buttons keep native keyboard, focus, role, and pressed behavior, with a shared hover tint/outline that does not change size or layout. Disabled controls do not highlight. Menu triggers and website links receive the same hover treatment while their native content remains unchanged. Reduce Motion removes the hover transition.

Expanded Tools are contained in one rounded, lightly filled and outlined group with an internal header separator and indented child actions. Settings remains outside this group. The upper record-type/category region remains independently scrollable at the minimum window size.

### Native Android detail and security controls

Account/code/wallet collection controls scroll with their records. Preserve the search/filter/scroll context when returning from a detail. Credential details use the legacy blue section titles and rounded cards, with independently concealed sensitive fields. Biometric controls must show persisted enabled state, separate renewal from enabling, and retain a usable disable action when hardware is temporarily unavailable; update the displayed state when another flow changes that preference.

Android account and wallet navigation opens editable grouped forms immediately. Keep extra login controls beside their own fields; each password has independent reveal, copy, generation and history. TOTP collections copy on tap and expose editing through their menu. Batch selection survives scrolling but clears when a filter changes, so invisible records are never carried into a new query's destructive action. Generation and scanning show recoverable errors locally; cancelling either flow must prevent a late result from changing the draft.

### Browser login-save reminders

Capture attempts from same-origin embedded login UI, but show a single notice in the main page so dismissing the login panel does not hide it. Distinguish detecting an attempt from successful authentication: ask the user to confirm success before saving. Native form validation takes precedence over click heuristics, including nested labels; tabs, links, reveal buttons and disabled or hidden controls are not login actions. Dismissal and locking invalidate queued and in-flight capture before any asynchronous work can recreate the notice.


### Mac direct-entry details

New immediately creates and selects a named blank entry for all four record types. Fill its title and grouped detail fields in place; every change follows encrypted autosave and the existing failure/retry path. There is no creation form sheet or separate Save step. An abandoned blank entry can be moved to Trash. Match native mobile field coverage, including independent additional-login reveal/copy/generation/history, linked TOTP setup, wallet recovery words and shared metadata. Password history records the original value once per editing session, restores it on reversion, and adopts external credential updates as a new baseline. Leaving a detail invalidates in-flight generation results.


### Browser save confirmation

Place pending-login review before saved-account matches and secondary reminder settings. Fold the match list while a capture is under review. Keep the account, editable password and Cancel save / Save controls visible together at 380×600; do not grow the popup beyond browser limits merely to fit account lists. Use a dedicated eye button with a changing accessible name and pressed state. Default to concealed; conceal on record changes, focus/visibility loss and save/cancel. Save errors belong inside the review card and must retain edits for retry.
