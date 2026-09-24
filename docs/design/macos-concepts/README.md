# Mac desktop design concepts

Three independent concepts for the planned native PasswordVault desktop app. These are generated design proposals, not screenshots of an implemented app.

**Selected: option 1, Native notes / 原生备忘录.** The owner chose this direction. Follow the [selected Mac design guide and companion screens](../macos-native/README.md) for the native implementation; options 2 and 3 remain exploration history.

## Display order

The numbers below match the order of generated images shown in the conversation.

| Option | Direction | Image |
| --- | --- | --- |
| 1 | Native notes / 原生备忘录 | [native-notes.png](native-notes.png) |
| 2 | Quiet study / 安静书房 | [quiet-study.png](quiet-study.png) |
| 3 | Professional library / 专业资料库 | [professional-library.png](professional-library.png) |

All three show the same fictional “家庭重要资料” note in a three-column Mac window. Notes, passwords, TOTP codes, wallets, settings, search, creation, edit/preview, favorite, and lock remain visible. Backup and sharing belong to secondary navigation.

## Dimensions and review

- Requested design frame: **1440 × 1024**.
- Actual generated PNG dimensions: **1487 × 1058** for every option. The built-in generator did not return the exact requested pixel dimensions; these originals have not been stretched or cropped.
- Reviewed the visible Chinese text, document hierarchy, primary controls, spacing, and content bounds. The warm concept favors reading space; the dark concept uses denser lists.
- “已加密保存” is intended UI copy within a concept, not evidence that the planned encryption changes have been implemented.
- All note content is synthetic. No real vault data was read or supplied to image generation.
- Option 1 is selected. No native UI implementation or interactive prototype was created in this design step.

## Generation

Generated with the built-in Image Gen tool, one call per direction. Exact prompts are preserved in [PROMPTS.md](PROMPTS.md).

References supplied to all three calls:
- [Existing desktop widget capture](../../images/vault-desktop.png): product vocabulary and brand context, not a layout to copy.
- [PasswordVault icon](../../../assets/branding/passwordvault-icon-512.png): visual brand reference.

The selected direction now has companion password-detail, Touch ID unlock, and security-settings concepts in the [selected design guide](../macos-native/README.md).
