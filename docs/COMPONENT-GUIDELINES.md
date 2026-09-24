# Component guidelines

## Ownership and reuse

Shared presentation components live in [`lib/core/widgets/app_components.dart`](../lib/core/widgets/app_components.dart); shared theme definitions live in [`lib/core/theme/app_theme.dart`](../lib/core/theme/app_theme.dart). Feature-specific cards and forms stay with their feature under `lib/features/`.

| Component | Responsibility |
| --- | --- |
| `VaultMark` | Decorative app mark; excluded from accessibility semantics |
| `AppSectionCard` | Shared surface with optional title, subtitle, and trailing action; content owns interaction semantics |
| `AppEmptyState` | Scrollable empty state with an explanation and an optional recovery action |
| Account, TOTP, note, and wallet cards | Feature-specific identity, metadata, and actions; keep entry type behavior in the feature |

Prefer an existing component before introducing another wrapper. Keep generic surfaces independent of vault repositories and encryption. Riverpod providers own application state; repositories and services own persistence and platform work. Widgets may invoke those boundaries but should not duplicate cryptographic or migration logic.

## Styling and layout

Follow the colors, typography, dimensions, and content rules in [DESIGN.md](../DESIGN.md). Obtain semantic colors and text styles from the theme. Preserve system text scaling, flexible card height, and wrapping actions/metadata. Use available layout constraints instead of inferring layout from a platform name.

The workspace, card, and generator breakpoints are documented in [PAGE-STRUCTURE.md](PAGE-STRUCTURE.md#responsive-behavior). Review both themes, compact and wide widths, long translated text, and an open keyboard when relevant. Keep preview explanations concise and do not insert build-system details into routine user actions.

## State and feedback

- Distinguish loading, empty, filtered-empty, error, and populated states; errors must offer a useful retry.
- Disable duplicate submissions during asynchronous work and report success only after the operation completes.
- Keep errors near their triggering field/action, including retryable clipboard and save failures.
- Retain confirmation and recovery behavior for destructive actions; do not bypass authentication guards.
- Keep secrets and real vault records out of diagnostics, screenshots, and fixtures.

## Accessibility and localization

Every interactive icon needs a localized label or tooltip, and controls must remain reachable by keyboard. Preserve visible focus, logical traversal, live-region form errors, and the documented search/escape shortcuts. Do not rely on color alone to explain a state. Decorative imagery must not duplicate spoken labels.

Use ARB catalogs and generated localization accessors for visible text. Preserve equivalent placeholders and never translate storage identifiers or user-entered data. See [INTERNATIONALIZATION.md](INTERNATIONALIZATION.md) for the translation workflow.

## Dependencies and verification

Declare Dart dependencies in `pubspec.yaml`, commit `pubspec.lock`, and use the pinned Flutter SDK. Consider platform support, licensing, runtime permissions, and migration cost before adding a package. Isolate platform-specific implementations behind existing conditional-import or service boundaries.

Run the applicable [development checks](DEVELOPMENT.md). For changed interactions, use meaningful widget tests with synthetic data, such as the existing tests in `test/design_interaction_test.dart`, `test/password_item_card_test.dart`, and `test/workspace_navigation_regression_test.dart`. Use the [image harness](images/README.md) for presentation review; record native clipboard, camera, biometric, autofill, and browser checks separately. A widget render cannot verify those integrations.

## Native V2 components

Use macOS 13-compatible SwiftUI controls and ObservableObject state. Keep blocking cryptography/database work inside CoreClient's actor. Hide sensitive editors immediately on lock, drain their final snapshot, then discard editor DOM/undo state. Guard async results against a changed lock generation. Preserve unknown record fields. Use system fonts, accessible labels, native keyboard actions, and the selected Native Notes spacing/colors. The Chromium client uses Preact DOM controls, safe text rendering, and separate popup/workspace bundles without a Flutter runtime. The Mac Markdown surface is a deliberately scoped local WKWebView component, not the application's storage or navigation shell.

### Markdown editor component

- Keep the pinned Milkdown/ProseMirror document model and history in `apps/macos/NoteEditor`; use CommonMark/GFM editing behavior for lists, task items, tables and code. Do not emulate hidden Markdown by zero-width editable characters or a second offset mapper.
- Use the nonpersistent WebKit configuration and generated CSP. No CDN, remote font/image, analytics, arbitrary navigation or JavaScript persistent-storage path belongs in this editor. Pass text as a structured JavaScript argument, never as executable HTML/string interpolation. Native cryptography and vault credentials remain outside the page.
- Bind messages to the live note session and revision. Enforce read-only/Trash restrictions in both the editor and AppStore. Reject stale, wrong-session or post-lock writes; do not rely on a disabled web control as authorization.
- Preserve caret, active composition and history during autosave/configuration echoes. Ordinary preview clicks enter editing without opening links. Route native Undo/Redo to ProseMirror history, and validate actual keyboard and menu behavior.
- Source mode is a handover, not an immediate view toggle: await the closing snapshot before creating a writable source editor. Preserve a completed close result until all store consumers finish; retirement and locking may overlap.
- Loading, snapshot or web-process failure retains the acknowledged source and shows a recoverable failure. Never publish an empty fallback as user input or report a complete export after an unconfirmed snapshot.
- Keep one outer scroll surface and localized editor labels; verify minimum window size, long text, both appearances and Chinese input in real WKWebView. Previous editor scores and pure browser fixtures do not establish this component's acceptance.


Native macOS menu actions must use `.buttonStyle(.automatic)` inside `Menu` and `contextMenu` content. The app-wide `VaultButtonStyle` is a primitive button style intended for visible controls and hover feedback; inheriting it into AppKit menu items can leave every action disabled. Verify menu actions with actual pointer selection, including an unselected row and Trash restoration, instead of relying only on compilation.
