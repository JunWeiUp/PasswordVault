# PasswordVault 2.2.11 — native clients

A coordinated release of the native Mac workspace, Android app, lightweight browser extension, standalone Web app, and iOS Simulator app. Notes, accounts, authenticator codes and wallets share the Rust vault core. Mac has a live Markdown editor; Android Notes scroll as one page with a refreshed account editor.

**Developer preview:** this is a regular GitHub Release, not a claim of production security acceptance. Independent security review, signed iPhone distribution and some hardware/migration gates remain open. Read [SECURITY_MODEL.md](https://github.com/JunWeiUp/PasswordVault/blob/v2.2.11/docs/SECURITY_MODEL.md) before storing important data.

## Changes in 2.2.11

- Save confirmed login/signup credentials while the Mac app is quit. Encrypted offline staging retries only while items remain pending, with atomic delivery receipts to avoid duplicates.
- Authorize current-site account lookup, masked password reveal and fill using the Mac master password in the extension. The toolbar shows the available account count.
- Opt into Mac startup unlock during authorization. Legacy save-only grants retain their scope; manual/system locks remain effective during the running session.
- Show the extension version and a Mac launch icon in the popup header. Missing native connections offer GitHub downloads and registration guidance.
- Keep native helpers short-lived. Android and iOS receive coordinated version updates with their existing session and data behavior preserved.

## Downloads and installation

| Download | Requirements and installation |
| --- | --- |
| `android-arm64-v8a.apk` | Most current Android phones; Android 7.0+ (system Autofill: Android 8+). Install the APK. |
| `android-x86_64.apk` | Android x86_64 devices/emulators, Android 7.0+. No 32-bit ARM build. |
| `macos-universal-development.zip` | macOS 13+, Apple Silicon or Intel. Extract and move PasswordVault.app to Applications. Ad-hoc signed, **not notarized**. |
| `chromium-extension.zip` | Extract to a permanent folder; Chrome/Edge Extensions → Developer mode → Load unpacked → select the folder containing manifest.json. |
| `web.zip` | Extract and serve over HTTPS or localhost. Open index.html through the server. This is a separate vault from the extension and desktop. |
| `ios-simulator.zip` | A Mac with a compatible Xcode iOS Simulator. **Not an IPA; cannot install on an iPhone.** Extract; run `xcrun simctl install booted PasswordVault.app`. The bundled executable architecture/runtime determine simulator compatibility. |
| `source.zip` | Source for all clients, including the iOS app and AutoFill extension. Follow the platform READMEs to build; device installation requires eligible provisioning. |

All client versions are **2.2.11**. `BUILD.json` identifies the exact source commit, build numbers and distribution limitations. Verify downloads with `shasum -a 256 -c SHA256SUMS` after downloading the complete asset set.

### Android installation identity

Public APKs are non-debuggable and signed with the reviewed release certificate in `SIGNING-CERTIFICATE-SHA256.txt`. The native app uses `com.securepass.vault.nativepreview`, so it coexists with the legacy Flutter application; legacy data is not automatically migrated. Use an encrypted backup and an explicit import.

Previous locally installed native debug/compact builds use a different signing key and **cannot be updated with these public APKs**. Preserve and verify an encrypted backup before switching installations. Do not uninstall the only copy of a vault to resolve a signature error. This release does not replace the legacy Android App Bundle in an app store.

### Mac installation and Touch ID

The downloadable development app is ad-hoc signed, not Developer ID signed/notarized. macOS may block the first launch. If you trust the downloaded build, first attempt to open it, then use **System Settings → Privacy & Security → Open Anyway** where available; this grants an exception for this app. Managed Macs may prevent exceptions. See [Apple's guidance](https://support.apple.com/102445).

**Touch ID/keychain enrollment is not promised in this public ad-hoc build.** Use the master password, or build locally with an eligible Apple Development signing configuration as described in the Mac guide. Users of a locally signed Touch ID build should retain it until they have confirmed master-password access; changing signing identity can affect keychain access. Existing vault data is not removed by installing the application.

For first browser connection, register the extension/browser in Mac settings. After entering the Mac master password in the extension, authorized saving and current-site account access work while the main app is quit. Startup unlock is optional. Reauthorize after a helper signing change; old grants remain save-only. See [browser authorization](https://github.com/JunWeiUp/PasswordVault/blob/v2.2.11/docs/BROWSER-AUTHORIZATION.md). The browser extension supports a separate independent vault as well; it does not automatically merge data.

### iPhone installation options

The simulator archive needs no device provisioning. For a personal iPhone, Xcode can provision supported capabilities with a Personal Team, generally requiring renewal after seven days. This project's app plus AutoFill/App Group capabilities still require successful provisioning; a free account alone does not establish that the entire project can be installed. TestFlight, App Store or registered-device Ad Hoc distribution require an eligible paid developer team and corresponding profiles. This release includes none of those signed-device artifacts.

## 中文安装说明

本次更新：插件支持 Mac 退出时保存、授权读取和填充当前网站账号，显示数量角标；可选择 Mac 启动自动解锁。顶部新增版本号与打开 Mac 入口，未检测到连接时提供 GitHub 下载与登记提示。原有 Android/iOS 功能保留。

此版本统一为 **2.2.11**，包含原生 Android、Mac 开发版、浏览器插件、独立 Web、iOS 模拟器包及源码。软件仍处于开发预览阶段，安全审计与部分真机验证尚未完成。

- **Android**：普通手机下载 `android-arm64-v8a.apk`；x86_64 设备下载对应 APK。使用正式发布密钥和独立原生版包名，与旧 Flutter 版共存。之前的本地调试版签名不同，无法直接覆盖；先验证加密备份，切勿为安装而直接卸载唯一的资料库。
- **Mac**：解压后放入「应用程序」，支持 Apple Silicon/Intel、macOS 13+。本包未公证，首次打开可能需要在「隐私与安全」中选择「仍要打开」。本包不保证 Touch ID 钥匙串注册可用，可用主密码或保留本地签名版。
- **插件**：先解压，在 Chrome/Edge 扩展管理页启用开发者模式，加载含 `manifest.json` 的目录；不能直接加载 ZIP。更新后重新加载扩展，确认显示 2.2.11。首次需完成浏览器登记；在插件输入 Mac 主密码授权后，Mac 退出时也可保存和读取本站账号，可选择启动自动解锁。更新 helper 签名后需重新授权。
- **Web**：解压后用 HTTPS 或 localhost 服务打开，是独立资料库。
- **iOS**：本次是模拟器包及源码，不能直接安装到 iPhone。真机自用可尝试 Xcode 签名；完整 AutoFill/App Group 能力仍需合适的团队授权。TestFlight、App Store、Ad Hoc 需要付费开发者团队及相应配置。

各端不会自动同步或合并已有资料库，请使用明确的加密备份导出、导入流程。
