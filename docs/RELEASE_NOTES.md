PasswordVault developer preview. Not independently audited; use synthetic credentials and review the security model before evaluation.

English is the default UI language; Simplified Chinese is available on the lock screen and in Settings → Appearance.

| Asset | Purpose |
| --- | --- |
| `*-android-arm64-v8a.apk` | Signed release APK for most recent Android devices |
| `*-android-armeabi-v7a.apk` | Signed release APK for supported 32-bit ARM devices |
| `*-android-x86_64.apk` | Signed release APK for x86_64 devices/emulators |
| `*-android.aab` | Signed Android App Bundle for maintainer distribution |
| `*-web.zip` | Self-hosted experimental Web build |
| `*-chrome-extension.zip` | Unpack and load in Chrome/Edge developer mode |
| `SHA256SUMS` | SHA-256 checksums for all packages |

Verify downloaded files with `shasum -a 256 -c SHA256SUMS` (macOS) or `sha256sum -c SHA256SUMS` (Linux). Checksums detect corruption; verify the release's source and signing identity separately.

Do not install this over a valuable existing vault without a tested backup. Signing keys used in private development must not be reused for public releases. No app store availability is implied.

中文：这是开发预览版，未经独立安全审计，请使用测试凭据。默认英文，可切换简体中文。升级前请验证备份；各平台限制与已知问题见仓库的安全模型文档。
