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
