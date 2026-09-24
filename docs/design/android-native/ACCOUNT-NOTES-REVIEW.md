# Android Notes and account editor — 2.1.7 / 21009

This increment is limited to the Notes collection and the password-account editor. It preserves the existing credential fields, encrypted drafts, password history, shared-vault permissions, backup formats and encryption code. Code, wallet and settings screens retain their existing styling.

## Changes

- The account editor uses the same system-bar background and icon contrast as Notes. The gray dialog status-bar strip is removed without cropping the screenshot or hiding system information.
- Account fields use persistent labels and filled backgrounds inside borderless groups. Save is the primary action; category and secondary actions have quieter styling. Dark fields remain visibly distinct from their groups.
- At less than 380 dp width or above 1.25 font scale, reveal/copy/generate actions move below the field so the main and additional-account inputs retain their width. Touch targets and accessibility names remain available.
- Notes places folders, count, view switch, sorting and collection tools in one row. Select is available in Collection tools; selection mode restores its full batch-action area. Shared-vault filters remain available.
- Shorter note previews and combined category/date footers show more cards without changing the reading and editing flows. Large text keeps the existing single-column adaptation.

Current synthetic screenshots: [English Notes](notes-en.png), [English account](account-editor-en.png), [Chinese Notes](notes.png), [Chinese account](account-editor.png). These contain no real vault data.

## Validation

All runtime checks used a UUID-named synthetic vault on the Pixel 9 Android emulator (API 37). The ordinary layout used a 1080 × 2424 display at 420 dpi. The large-text check used 360 dp width and font scale 1.8.

| Evidence | Result |
| --- | --- |
| Existing DesignFlow, four LegacyEditing cases, VaultFlow and EntryHistory | Seven cases passed: editing, draft recreation, field preservation, save/cancel, note delete/restore, selection and history |
| Localized screenshot/interaction fixture | Passed in English light, Chinese light and English dark |
| Large-text fixture with an additional account | Passed: wide password input, reveal/conceal, folder filtering, selection entry/exit, new-note cancel and existing-note editing |
| Final dark-field color adjustment | Clean compact build and another complete dark fixture run passed; unchanged functional cases were not repeated |
| APK validation | ARM64 compact preview; signature, 16 KB ZIP alignment and every native library's load-segment alignment passed |
| Physical-device installation metadata | After matching the package signature to the prior APK, the package was installed with `adb install -r` on Mi 10 and read back `2.1.7-preview / 21009`. This confirms package upgrade installation, not real-vault behavior |

The first new empty-folder assertion failed because the fixture attempted to set the core-owned category list through generic settings. The fixture now uses the real `category-add` operation, and the unchanged empty-folder/return-to-all assertion passes. This was a fixture correction, not a data-layer change.

The screenshot fixture restores its original language preference. Display density, resolution and font scale were restored after testing. The physical-device upgrade was not followed by launching or unlocking the app. No real vault was opened, read or copied; all functional and screenshot checks remained on the emulator.

## Scoped review

| Dimension | Score |
| --- | ---: |
| Visual hierarchy and system-bar consistency | 9.3 |
| Preserved task flows and controls | 9.3 |
| Content density and reading | 9.2 |
| Large text and control reachability | 9.0 |
| Evidence and reproducibility | 9.2 |

**Scoped result: 9.2/10.** No blocking issue remains in the reviewed Notes/account workflows. This is not an overall product-security or production-readiness rating. Physical camera/fingerprint, full TalkBack, older Android versions and production-signing upgrades remain separate acceptance gates.

To reproduce the screenshot flow, build the compact app and its instrumentation APK using the [Android guide](../../../apps/android/README.md), then run `com.securepass.vault.ReadmeScreenshotsTest` with `designTheme=light|dark`, `designLanguage=en|zh` and optional `designExtraAccount=true`. The test selects its own isolated fixture and must only run on a test emulator.
