# Password Vault (密码保险箱)

这是一个基于 Flutter 开发的安全、跨平台密码和数字资产管理应用。它旨在提供一个安全、私密且易于使用的环境，用于存储和管理您的各种在线账号密码、双重认证（TOTP）以及加密货币钱包凭证。

## ✨ 主要功能

- **🔐 多类型保管库**:
  - **密码管理**: 存储账号、密码、网站链接和备注，支持分类管理。
  - **双重认证 (TOTP)**: 内置 2FA 校验码生成器，支持标准 TOTP 协议。
  - **加密资产**: 安全存储加密货币助记词（Mnemonic）、私钥（Private Key）和钱包地址。
- **🛡️ 顶级安全保障**:
  - **强加密算法**: 使用 AES-GCM 256 位加密算法保护您的数据。
  - **密钥派生**: 采用 Argon2id（目前最先进的密钥派生函数之一）从主密码生成加密密钥，有效防御暴力破解。
  - **零知识架构**: 数据完全存储在本地设备中，不上传至任何中心化服务器，确保隐私。
- **🛠️ 便捷工具**:
  - **密码生成器**: 自定义长度和字符类型，生成高强度随机密码。
  - **助记词生成**: 支持生成符合 BIP39 标准的助记词。
  - **生物识别**: 支持指纹或面部识别快速解锁（在支持的设备上）。
- **☁️ 备份与同步**:
  - **本地导入导出**: 支持 CSV 格式数据的备份与恢复。
  - **WebDAV 同步**: 支持通过 WebDAV 协议进行云端备份，方便在不同设备间迁移数据。请在应用内填写服务器与账号；若仅在浏览器地址栏打开坚果云等 WebDAV 地址，可能出现浏览器自带的系统登录提示，属正常现象。
- **🌍 跨平台支持**:
  - **移动端**: 支持 Android 和 iOS。
  - **桌面端/Web**: 支持 Web 平台。
  - **浏览器扩展**: 支持作为 Chrome/Edge 浏览器扩展运行，方便在网页端自动填充。

## 🛠️ 技术栈

- **框架**: [Flutter](https://flutter.dev/) (SDK ^3.5.4)
- **状态管理**: [Riverpod](https://riverpod.dev/)
- **路由**: [GoRouter](https://pub.dev/packages/go_router)
- **数据库**: [Drift](https://drift.simonbinder.eu/) (基于 SQLite，支持 Web 端 WASM)
- **安全逻辑**:
  - [cryptography](https://pub.dev/packages/cryptography): 核心加密算法 (AES-GCM, Argon2id)
  - [local_auth](https://pub.dev/packages/local_auth): 生物识别支持
- **网络与备份**:
  - [webdav_client](https://pub.dev/packages/webdav_client): WebDAV 协议支持
- **加密货币相关**:
  - [web3dart](https://pub.dev/packages/web3dart), [bip39](https://pub.dev/packages/bip39), [bip32](https://pub.dev/packages/bip32)

## 🚀 快速开始

### 前置要求

- 已安装 [Flutter SDK](https://docs.flutter.dev/get-started/install) (建议版本 ^3.5.4)
- 配置好相应的开发环境（Android Studio, Xcode 或 VS Code）

### 安装步骤

1. **克隆仓库**:
   ```bash
   git clone <repository-url>
   cd password
   ```

2. **获取依赖**:
   ```bash
   flutter pub get
   ```

3. **代码生成**:
   由于本项目使用了 Drift 和 Riverpod，需要运行 build_runner 生成代码：
   ```bash
   flutter pub run build_runner build --delete-conflicting-outputs
   ```

### 运行应用

```bash
# 运行到已连接的设备或模拟器
flutter run

# 运行 Web 版
flutter run -d chrome
```

## 🛠️ 常用开发与打包命令

### 开发环境配置

```bash
# 获取依赖
flutter pub get

# 重新生成数据库和 Riverpod 代码 (Drift/Riverpod)
flutter pub run build_runner build --delete-conflicting-outputs
```

### 移动端打包 (Android)

本项目已优化 Android 打包体积（启用 R8 混淆、资源压缩、ABI 分离）。

```bash
# 生成分架构的 APK (体积更小，推荐)
# 产物位于 build/app/outputs/flutter-apk/
flutter build apk --release --split-per-abi

# 生成 App Bundle (用于 Google Play 发布)
flutter build appbundle

# 分析 APK 体积构成
flutter build apk --release --analyze-size --target-platform android-arm64
```

### 浏览器扩展打包

本项目支持编译为 Chrome 扩展，请运行根目录下的脚本：

```bash
chmod +x build_extension.sh
./build_extension.sh
```

编译完成后，产物位于 `build/chrome_extension` 目录下。在 Chrome 中打开 `chrome://extensions/`，开启“开发者模式”，选择“加载解压的扩展程序”并指向该目录即可。

## 📂 项目结构

```text
lib/
├── core/               # 核心功能（数据库、安全、主题、工具类）
│   ├── database/       # Drift 数据库定义、连接与迁移
│   ├── security/       # AES 加密与 Argon2id 密钥派生
│   ├── theme/          # 应用主题配置
│   └── utils/          # 通用工具（BIP39、文件处理、导入导出）
├── features/           # 业务功能模块
│   ├── vault/          # 保管库主功能（密码、加密资产管理、共享库）
│   ├── totp/           # TOTP 2FA 功能
│   ├── backup/         # WebDAV 备份与恢复
│   └── sync/           # 局域网设备发现与同步
└── main.dart           # 应用入口
chrome/                 # 浏览器扩展相关的配置与脚本
```

## 🔒 安全声明

您的所有敏感数据（如密码、私钥）在存储前均经过高强度加密。加密密钥由您设置的**主密码**通过 Argon2id 算法动态派生。
- **应用不存储主密码**：这意味着如果您忘记主密码，我们将无法为您找回数据。
- **本地优先**：所有加密操作均在本地完成，数据默认存储在本地数据库中。
- **备份建议**：请务必定期通过 WebDAV 或导出 CSV 文件备份您的数据，并妥善保管您的主密码。

## 📄 开源协议

本项目采用 [MIT License](LICENSE) 协议。

---

*Made with ❤️ using Flutter*
