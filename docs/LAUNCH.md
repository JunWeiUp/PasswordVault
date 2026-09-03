# Public launch kit

Do not promote this preview as a production password manager. Publish after the history and credential cleanup is verified. Production claims additionally require closure of the security blockers.

## Repository presentation

Suggested description:

> A local-first Flutter vault for passwords, TOTP codes, notes, and wallet credentials. Android, Web, and Chromium extension. Developer preview.

Suggested topics: `flutter`, `dart`, `password-manager`, `totp`, `local-first`, `webdav`, `chrome-extension`, `android`, `privacy`, `internationalization`.

Keep the About description, README, social preview, and release notes consistent. Enable issues, discussions, and private vulnerability reporting. Add a social preview made from actual screenshots containing synthetic data. Do not use fabricated download counts, testimonials, security certifications, or store badges.

## English announcement draft

> I'm preparing PasswordVault, a local-first Flutter vault for passwords, TOTP codes, notes, and wallet credentials. It includes an Android app, experimental Web/Chromium extension, WebDAV backup, and local sharing. The project now has English/Chinese UI and contributor documentation.
>
> This is a developer preview, not an audited production password manager. I'm looking for feedback on the security model, backup migrations, extension behavior, accessibility, and translations. Please test with disposable credentials.
>
> Source and limitations: https://github.com/JunWeiUp/PasswordVault

## 中文介绍草稿

> PasswordVault 是一个 Flutter 本地优先保管库，管理密码、TOTP 验证码、笔记和钱包凭据，包含 Android 应用、实验性 Web/浏览器扩展、WebDAV 备份及局域网共享，支持英文和中文。
>
> 当前是开发预览版，尚未完成独立安全审计。欢迎使用测试凭据参与安全模型、备份迁移、扩展体验、可访问性和翻译改进。
>
> 源码与已知限制：https://github.com/JunWeiUp/PasswordVault

## Distribution sequence

1. Verify all public refs, signing cleanup, bilingual onboarding, and a green CI run from a clean checkout.
2. Publish a reviewed prerelease with checksums and accurate release notes.
3. Record a short synthetic-data demo: setup → add account → fill → export → restore.
4. Share an original write-up in relevant Flutter/open-source communities, following each community's current posting rules. Ask for concrete feedback, not mass stars.
5. Submit to relevant curated lists only after checking their criteria. Respond to feedback and turn confirmed findings into scoped issues.
6. Measure useful outcomes: completed onboarding, reproducible bug reports, translation contributions, and successful restore tests. Do not promise reach or star counts.

Announcements are drafts. A maintainer must choose the account/channel and authorize each external post; do not automatically message people or mass-submit links.
