PasswordVault developer preview. Not independently audited; use synthetic credentials and review the security model before evaluation.

This release adds **Codes → Add → Scan QR code** on Android and iOS. Scan a single-account authenticator setup QR code, review the service and account, then save it. Camera permission denial, invalid codes, repeated detections, and save failures are handled without losing entered details. Android version: **1.2.0 (build 7)**.

Supported QR codes use `otpauth://totp`, SHA-1, and 6 digits. Refresh intervals are retained and used for code generation and export. HOTP, other algorithms/digit lengths, and Google Authenticator batch migration QR codes are not supported. Manual entry remains available.

This release also fixes code-card wrapping on narrow screens and strengthens repository rules for excluding private vault data, exports, credentials, and signing material.

All CI checks, Android signature verification, and package checksum checks complete before this release is published automatically.

English is the default UI language; Simplified Chinese is available on the lock screen and in Settings → Appearance.

| Asset | Purpose |
| --- | --- |
| `*-android-arm64-v8a.apk` | Signed release APK for most recent Android devices |
| `*-android-armeabi-v7a.apk` | Signed release APK for supported 32-bit ARM devices |
| `*-android-x86_64.apk` | Signed release APK for x86_64 devices/emulators |
| `*-android.aab` | Signed Android App Bundle for maintainer distribution |
| `*-web.zip` | Self-hosted experimental Web build |
| `*-chrome-extension.zip` | Unpack and load in Chrome/Edge developer mode |
| `SIGNING-CERTIFICATE-SHA256.txt` | Expected public Android signing certificate fingerprint |
| `BUILD.json` | Source commit, tag, toolchain, and workflow URL |
| `LICENSE`, `THIRD_PARTY_NOTICES.md`, `INSTALL.md` | Licensing and installation guidance |
| `SHA256SUMS` | SHA-256 checksums for the complete asset inventory |

Verify downloaded files with `shasum -a 256 -c SHA256SUMS` (macOS) or `sha256sum -c SHA256SUMS` (Linux). Checksums detect corruption; verify the release's source and signing identity separately.

Do not install this over a valuable existing vault without a tested backup. Signing keys used in private development must not be reused for public releases. No app store availability is implied.

中文：本次新增手机端「验证码 → 添加 → 扫描二维码」，支持 SHA-1、6 位单账号 TOTP，保留刷新间隔并支持保存失败重试；暂不支持 HOTP 和批量迁移二维码。这是开发预览版，未经独立安全审计，请使用测试凭据。默认英文，可切换简体中文。升级前请验证备份；各平台限制与已知问题见仓库的安全模型文档。
