<div align="center">
  <img src="assets/branding/passwordvault-icon-512.png" alt="PasswordVault — P 字母保险库与钥匙孔" width="112" height="112">
  <h1>PasswordVault</h1>
  <p>本地优先的密码、验证码、笔记和钱包凭据管理工具。</p>
  <p><a href="README.md">English</a> · <strong>简体中文</strong></p>
</div>

**开发预览版。** PasswordVault 是早期阶段的开源项目，尚未经过独立安全审计。在[安全发布阻碍](docs/SECURITY_MODEL.md)解决之前，请使用测试凭据。此前的私有开发标签不代表可用于生产环境。

## 功能

- 一个网站管理多个账号，一个账号匹配多个域名；支持分类、标签、颜色、收藏和置顶。
- 生成 TOTP 验证码和随机密码，管理安全笔记及钱包凭据。
- 通过 Chromium Manifest V3 扩展填充网页；Android 包含自动填充服务。
- 导入 Chrome、Bitwarden、LastPass、1Password 的 CSV；导出 JSON、CSV 或加密文件。
- 备份至自己的 WebDAV 存储；实验性的局域网同步和加密共享库。
- 回收站、密码历史，以及弱密码、重复密码、过期密码检查。
- **默认英文**，在锁屏页或**设置 → 外观**中切换简体中文。

项目对外名称统一为 **PasswordVault**。部分内部标识和旧存储格式保留 `SecurePass`，以兼容已有数据。

## 平台状态

| 平台 | 状态 | 体验方式 |
| --- | --- | --- |
| Android | 已签名的开发预览 APK，Android 7.0+ | 下载对应架构的 APK |
| Chrome / Edge 扩展 | 实验性，使用解压安装 | 下载扩展 ZIP 或运行 `./build_extension.sh` |
| Web | 实验性，存在浏览器存储和 CORS 限制 | 自行托管 Web ZIP 或运行 `flutter run -d chrome` |
| iOS | 有工程骨架，待真机和发布验证 | 需要 macOS、Xcode、签名 |
| Windows / macOS / Linux 桌面 | 尚无对应 runner | 欢迎贡献 |

下载[开发预览版及校验和](https://github.com/JunWeiUp/PasswordVault/releases/tag/v1.1.0-preview.3)。大多数较新的 Android 设备使用 `arm64-v8a`；Chrome/Edge 用户解压扩展 ZIP 后，在开发者模式下加载目录。目前尚未上架 Chrome Web Store、Google Play 或 App Store。

## 从源码运行

使用 [.flutter-version](.flutter-version) 固定的 **Flutter 3.41.7 / Dart 3.11.5**。Android 需要 Java 17、SDK 36、NDK 27.0.12077973。

```bash
git clone https://github.com/JunWeiUp/PasswordVault.git
cd PasswordVault
flutter pub get
flutter gen-l10n
dart run build_runner build --delete-conflicting-outputs
flutter run -d chrome
```

连接 Android 设备后可执行 `flutter run`。架构和环境说明见[开发指南](docs/DEVELOPMENT.md)。

## 检查与构建

```bash
flutter analyze --no-fatal-infos
flutter test
python3 tool/check_repository.py
node --test test/extension/*.test.cjs
flutter build apk --debug
./build_extension.sh
```

在 `chrome://extensions` 或 `edge://extensions` 开启开发者模式，加载 `build/chrome_extension`。移动解压扩展目录可能改变扩展身份和存储位置，重新安装前先备份测试数据。

签名 APK/AAB、GitHub Release 草稿、校验和及 CI 密钥配置见[发布指南](docs/RELEASING.md)。

## 安全与隐私

保管库字段使用 AES-256-GCM，常规保管库密钥使用 Argon2id。但密码学算法本身不能证明整个应用安全。当前仍存在旧备份派生方案、平台间秘密存储差异及实验性共享功能，具体限制见[安全模型](docs/SECURITY_MODEL.md)。

未加密 CSV/JSON 包含明文凭据。WebDAV 会连接配置的服务器，网站图标加载可能访问第三方服务。详见[隐私说明](PRIVACY.md)。报告漏洞请遵循 [SECURITY.md](SECURITY.md)，不要在 issue 中上传真实密码、私钥或备份。

## 参与贡献

欢迎安全修复、迁移测试、可访问性、翻译和平台验证。参见 [CONTRIBUTING.md](CONTRIBUTING.md)、[国际化指南](docs/INTERNATIONALIZATION.md)、[路线图](docs/ROADMAP.md)及[更新记录](CHANGELOG.md)。提交消息及 PR 标题使用英文 Conventional Commits；讨论欢迎中文和英文。

你可以给项目 Star、分享可复现的使用示例、帮助测试发布版本。[推广材料](docs/LAUNCH.md)提供项目介绍和发布文案草稿。

## 许可证

[MIT](LICENSE)。第三方组件遵循各自许可证，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
