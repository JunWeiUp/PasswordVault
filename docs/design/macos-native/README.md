# Selected Mac visual direction

The owner selected **Native notes / 原生备忘录**, the first image in the [original concept set](../macos-concepts/README.md). The selected [notes workspace](../macos-concepts/native-notes.png) is the visual baseline for the native Mac app. The other two directions remain exploration history.

These are design targets for the native rewrite, not screenshots of implemented functionality. The existing Flutter app remains unchanged by this design step.

## Screen set

| Screen | Reference | Key behavior |
| --- | --- | --- |
| Notes workspace | [Selected main screen](../macos-concepts/native-notes.png) | Categories, note list, Markdown document; Notes is the default Mac destination |
| Password detail | [password-detail.png](password-detail.png) | Masked password, explicit copy/reveal actions, additional accounts and history |
| Unlock | [touch-id-unlock.png](touch-id-unlock.png) | Touch ID entry and master-password fallback; no vault content before unlock |
| Security settings | [security-settings.png](security-settings.png) | Master-password change, optional Touch ID, idle lock, and mandatory system-lock/sleep behavior |

The three companion screens were displayed in password-detail, unlock, security-settings order. They extend the selected direction; they are not alternative styles requiring another selection.

## Visual rules

- Preserve the light native Mac window, cool gray sidebar, white list/content surfaces, fine separators, and restrained blue accents.
- Keep the existing PasswordVault mark and name. Use native system typography and coherent outline icons; do not carry Material-specific controls into the new SwiftUI UI.
- Use three resizable columns for unlocked content: navigation, record/category list, and detail. Prioritize readable content when the window narrows.
- Use flat list rows and lightweight form separators instead of card grids. Selected rows have a pale blue tint; blue-filled buttons are reserved for primary actions.
- Keep search/new actions with the list, and record actions with the detail. Tools remain secondary; passwords, codes, wallets, and settings stay discoverable.
- The screenshots use Simplified Chinese to review layout. The implementation retains English and Chinese localization.
- The chosen concept establishes composition and hierarchy. Exact layout geometry must be validated in the native implementation at the requested 1440 × 1024 viewport.

## Interaction and privacy rules

- Start Mac in Notes; retain all existing vault record types and tools.
- Passwords are masked by default. Copy feedback follows a successful clipboard operation; reveal/copy actions need accessible labels.
- Additional accounts and password history remain explicit collapsible destinations.
- Locking replaces the entire content workspace. Never show readable or merely blurred titles, account names, counts, snippets, or previous editor content before authentication.
- Touch ID is optional. If unavailable, cancelled, or invalidated, keep the master-password path available. The mock is the app's entry screen, not a simulated OS authentication approval.
- Idle lock defaults to 10 minutes. System lock and sleep lock the vault immediately; that behavior is not an off switch in settings.
- “已加密保存” is intended completion feedback for the future implementation. Display it only after an encrypted write succeeds; these images are not evidence of implemented encryption.
- All example data is fictional. Do not introduce real vault exports, account data, credentials, or keys into design assets.

## Output and review

All four current images are **1487 × 1058** PNGs. The requested design frame was 1440 × 1024, but the built-in generator returned a larger size. Original PNGs are preserved without stretching or cropping.

Reviewed the visible Chinese labels, text containment, consistency with the selected light design, masked password state, and privacy of the locked screen. Real interaction, accessibility, native controls, Touch ID, and encryption require implementation and runtime validation.

Companion images were created with the built-in Image Gen tool using the selected notes image as the direct visual reference. Exact prompts are in [PROMPTS.md](PROMPTS.md).

## Current application screenshots

The [notes workspace](current-notes.png) and [account details](current-password.png) are captured from the Mac 2.0.9 preview with a newly seeded, fictional vault. They show the integrated Milkdown editor and revised adaptive toolbar; the other PNGs in this directory remain design concepts. See [editor acceptance](../../MARKDOWN-EDITOR-EVALUATION.md) for the checked scope and remaining hardware/input-method gates.
