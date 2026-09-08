# README images

These assets illustrate the product and show the current Flutter source. They do not represent a published release, a physical-device test, or a native desktop build.

## Asset inventory

| File | Kind | Contents |
| --- | --- | --- |
| [`vault-hero.png`](vault-hero.png) | AI-generated concept illustration | A blue vault, account cards, and authenticator motifs; not application UI |
| [`vault-desktop.png`](vault-desktop.png) | Flutter widget render | Wide account workspace with navigation, search, filters, and synthetic entries |
| [`vault-mobile.png`](vault-mobile.png) | Flutter widget render | Compact account workspace with bottom navigation |
| [`vault-dark.png`](vault-dark.png) | Flutter widget render | Compact account workspace in dark appearance |
| [`lock.png`](lock.png) | Flutter widget render | Master-password form and language selection |
| [`generator.png`](generator.png) | Flutter widget render | Password result, copy/regenerate actions, length, and character options |

The hero was generated specifically for PasswordVault; its [production prompt](PROMPTS.md) is included. It is explanatory artwork, not a capture of the product. UI images are rendered from the application's own widgets using synthetic fixtures; no real accounts, vault exports, tokens, private keys, or device data are used. The generated password visible in a screenshot is an example and must never be reused as a credential.

## Reproduce the UI renders

Use the pinned Flutter toolchain and run from the repository root:

```bash
flutter pub get --enforce-lockfile
flutter gen-l10n
flutter test --update-goldens tool/capture_screenshots_test.dart
```

Capture sizes are 1280 × 900 for the wide workspace, 390 × 844 for the two compact workspace views, 390 × 900 for the lock form, and 720 × 1040 for the generator.

The [capture harness](../../tool/capture_screenshots_test.dart) controls fixtures, viewport size, theme, and locale. Update that harness alongside intentional presentation changes, then regenerate the affected images. Inspect the resulting PNGs for clipped text, overflow, missing icons, and empty or misleading content before adding them to a README.

Widget rendering provides repeatable presentation evidence. It does not exercise a full installed app, an operating system's biometric dialog, autofill, extension communication, network services, or native clipboard behavior. Do not change the captions to “device screenshots” without replacing the assets with documented device captures.

## Maintaining the gallery

- Keep English and Chinese README galleries in the same order, with descriptive alt text in each language.
- Use stable, relative asset links. Do not link to local machine paths, temporary render locations, or expiring remote URLs.
- Keep source UI and conceptual artwork clearly distinguished. Never draw a fictional control into an image labeled as current UI.
- Use only fictional service/account details and reserved example domains in new fixtures. Avoid network-dependent favicons in captures.
- When release packages catch up with the images, update the release link and version wording only after checking the published artifacts.

## Illustration prompt and fonts

The final built-in image generation prompt is preserved in [PROMPTS.md](PROMPTS.md). Screenshot typography loads Roboto and Material Icons from the pinned Flutter SDK and [Roboto Mono](https://github.com/google/fonts/tree/main/ofl/robotomono) from `fonts/RobotoMono.ttf` under the accompanying [SIL Open Font License](fonts/OFL.txt). These font assets are for the capture harness; the application retains its platform font setup.
