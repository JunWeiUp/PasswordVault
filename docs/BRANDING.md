# PasswordVault identity

The icon combines a geometric **P**, a vault-door ring, and a keyhole. Deep navy, warm white, and blue connect the identity to the application interface. It contains no wordmark, so the same mark works in every language.

## Source and exports

- Approved artwork: `assets/branding/passwordvault-icon-source.png`.
- README/display asset: `assets/branding/passwordvault-icon-512.png`.
- Platform exports: Chromium 16–512 px, Web/PWA/favicon, Android launcher and adaptive layers, and all sizes in the iOS app-icon catalog.
- Generation brief: [design-prompt.txt](../assets/branding/design-prompt.txt).

The source artwork was generated with the built-in imagegen tool and refined for a flat, compact icon. Platform exports preserve that artwork; iOS exports are opaque RGB, and Android adaptive foregrounds include mask-safe padding. The adaptive background color is derived from the artwork.

To export a future approved square PNG, replace the source file and run:

```bash
flutter pub get
dart run tool/generate_icons.dart
```

Keep the English and Chinese README image references synchronized. Check 16/32 px readability and platform masking before committing changed exports. Do not use screenshots containing real credentials in project marketing.

## README campaign

The native-client README uses localized [English](design/readme/hero-en.png) and [Chinese](design/readme/hero-zh-CN.png) campaign covers: a navy vault, notebook and credential cards against a warm ivory architectural backdrop. This illustration establishes the product story; the separate Mac and Android galleries show actual interfaces with fictional data. The existing app icon remains the brand reference.

The covers were created with the built-in image generation tool. Exact prompts and localization constraints are retained in [campaign prompts](design/readme/PROMPTS.md). They make no security-certification, public-release or automatic-sync claim. Preserve the original language-specific PNGs in the repository and keep meaningful copy, preview status and links in accessible README text.
