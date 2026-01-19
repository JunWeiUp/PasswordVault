# Password Vault (密码保险箱)

这是一个基于 Flutter 开发的安全、跨平台密码和数字资产管理应用。它旨在提供一个安全、私密且易于使用的环境，用于存储和管理您的各种在线账号密码、双重认证（TOTP）以及加密货币钱包凭证。

## ✨ 主要功能

- **多类型保管库**:
  - **密码管理**: 存储账号、密码、网站链接和备注。
  - **双重认证 (TOTP)**: 内置 2FA 校验码生成器，支持标准 TOTP 协议。
  - **加密资产**: 安全存储加密货币助记词（Mnemonic）、私钥（Private Key）和钱包地址。
- **顶级安全保障**:
  - **加密算法**: 使用 AES-GCM 256 位加密算法保护您的数据。
  - **密钥派生**: 采用 Argon2id（目前最先进的密钥派生函数之一）从主密码生成加密密钥，有效防御暴力破解。
  - **本地存储**: 数据完全存储在本地设备中，不上传至任何服务器，确保隐私。
- **便捷工具**:
  - **密码生成器**: 自定义长度和字符类型，生成高强度随机密码。
  - **助记词生成**: 支持生成符合 BIP39 标准的助记词。
  - **导入与导出**: 支持数据的备份与恢复，方便在不同设备间迁移。
- **跨平台支持**: 支持 Android、iOS 和 Web 平台。

## 🛠️ 技术栈

- **框架**: [Flutter](https://flutter.dev/)
- **状态管理**: [Riverpod](https://riverpod.dev/)
- **路由**: [GoRouter](https://pub.dev/packages/go_router)
- **数据库**: [Drift](https://drift.simonbinder.eu/) (基于 SQLite)
- **安全库**: [cryptography](https://pub.dev/packages/cryptography), [otp](https://pub.dev/packages/otp)
- **加密货币相关**: [web3dart](https://pub.dev/packages/web3dart), [bip39](https://pub.dev/packages/bip39)

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

3. **生成代码**:
   由于本项目使用了 Drift 进行数据库操作，需要运行 build_runner 生成必要的代码：
   ```bash
   flutter pub run build_runner build --delete-conflicting-outputs
   ```

4. **运行应用**:
   ```bash
   flutter run
   ```

## 📂 项目结构

```text
lib/
├── core/               # 核心功能（数据库、安全、主题、工具类）
│   ├── database/       # Drift 数据库定义与连接
│   ├── security/       # 加密与密钥派生逻辑
│   ├── theme/          # 应用主题配置
│   └── utils/          # 通用工具函数（密码生成、导入导出等）
├── features/           # 业务功能模块
│   ├── totp/           # TOTP 相关逻辑与界面
│   └── vault/          # 保管库（密码、加密资产）相关逻辑与界面
└── main.dart           # 应用入口
```

## 🔒 安全声明

您的所有敏感数据（如密码、私钥）在存储前均经过高强度加密。加密密钥由您设置的**主密码**通过 Argon2id 算法动态派生，应用本身不存储主密码，这意味着如果主密码丢失，数据将无法找回。请务必牢记您的主密码并定期备份数据。

---

*Made with ❤️ using Flutter*
