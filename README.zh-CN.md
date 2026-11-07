<p align="center">
  <a href="docs/design/index.html#reference">查看统一设计稿</a>
</p>

<div align="center">
  <h1>PasswordVault</h1>
  <p><strong>把重要的事，安放在一起。</strong></p>
  <p>笔记、密码、验证码与钱包资料，一处整理。<br>在 Mac 上安心记录，在手机上随手查阅，在浏览器中轻松填充。</p>
  <p><a href="README.md">English</a> · <strong>简体中文</strong></p>
  <p><a href="#快速开始"><strong>开始使用</strong></a> &nbsp; · &nbsp; <a href="#看看实际体验">看看实际体验</a> &nbsp; · &nbsp; <a href="#选择你的工作空间">选择平台</a></p>
</div>

**本地优先 · 加密存储 · 开源**

原生客户端目前为**开发预览版**。[平台状态](#选择你的工作空间)与[安全模型](docs/SECURITY_MODEL.md)记录当前限制，独立安全审查仍待完成。

**下载原生版 2.4.1：** [GitHub Release](https://github.com/JunWeiUp/PasswordVault/releases/tag/v2.4.1) · [安装方式与签名限制](docs/NATIVE-RELEASE-NOTES.md)。包含 Android、Mac、Windows x64、解压式插件、Web 和 iOS 模拟器包，各一个。

**Mac 客户端说明：** 当前开发与本机日常版本位于 [`apps/desktop`](apps/desktop/README.md)（NSH 0.4.0，macOS 14+ / Apple Silicon）。[`apps/macos-legacy`](apps/macos-legacy/README.md) 是保留的旧版 SwiftUI Mac 客户端；下文涉及 macOS 13+/Intel 与旧协调发布的说明属于该旧版。

共享桌面源码统一命名为 **Desktop**（`apps/desktop`）：Mac 与 Windows 共用 NSH 界面和密码库业务逻辑，系统能力通过平台适配层实现。Windows 的安装、构建、验证和功能限制见 [Windows 构建说明](tool/windows-desktop/README.md)。

## 少一点翻找，多一点从容

- **随时记下想法。** 在 Mac 上像写文档一样写笔记，支持富文本、表格、图片、附件、撤销/重做与自动加密保存。分类、搜索、收藏和置顶，让想法有处可寻。
- **重要资料放在一起。** 密码、附加账号、验证码与钱包资料，常用字段一次整理完整。
- **登录后，继续手头的事。** 在支持的密码框旁选择账号，核对新的登录信息后再保存，需要修改时直接打开 Mac 中的记录。

误删了条目，可以从回收站找回；需要迁移资料，可以导出加密备份，或在自己的 WebDAV 服务器上管理备份。

## 看看实际体验

### 在桌面上，留出思考的空间

熟悉的 Mac 三栏布局，把分类、笔记列表与正文放在眼前。标题、列表与待办随输入自然呈现，个人笔记提供表格、图片工具和加密附件。Markdown 导出会损失部分格式，详见[图文笔记兼容与备份](docs/RICH-NOTES.md)。

*下图为上一版 Markdown 工作区；2.3.0 增加上述图文编辑工具栏。*

[上一版 Mac 笔记工作区：虚构笔记](docs/design/index.html#reference)

<details>
<summary><strong>展开账号详情</strong> — 密码、附加账号与关联验证码</summary>

直接编辑资料，分别查看或复制密码，生成新密码并保留历史。多个网站、附加账号与关联验证码，都能收在同一条记录中。

[PasswordVault Mac 账号详情：虚构资料与分组操作](docs/design/index.html#reference)

</details>

### 小屏幕，也装得下日常所需

原生移动预览版将笔记、账号、验证码与钱包带到手机。笔记采用适合阅读的独立布局，各页面保留一致的常用操作。

<p align="center">
  <a href="docs/design/index.html#android">查看统一设计稿</a>
  &nbsp;&nbsp;
  <a href="docs/design/index.html#android">查看统一设计稿</a>
</p>

<p align="center"><sub>Mac 与 Android 预览版的实际界面，展示内容均为虚构资料。</sub></p>

### 在浏览器里，少输几次密码

在支持的密码框旁选择已保存的账号；检测到登录后，核对资料再保存。需要修改时，从插件直接打开 Mac 中的对应账号。填充后由你决定是否提交表单。

轻量 Chromium 插件可以连接 Mac，也可以创建**数据分开的独立加密资料库**，不包含 Flutter 或 CanvasKit 运行时。[查看浏览器配置 →](docs/NATIVE-MIGRATION.md#build-and-launch) 点击插件中的**添加账号密码**即可为当前网站手动保存账号，无需网页上有登录表单。连接 Mac 模式支持[离线保存登录/注册账号，连接后自动同步](docs/BROWSER-OFFLINE-SAVE.md)。

浏览器 2.2.11 / Mac 2.2.11 支持直接显示、查看和填充当前网站账号，图标角标显示数量，Mac 无需保持打开。在插件中验证 Mac 主密码，勾选**打开 Mac 时自动解锁**即可启用启动解锁。组件仍按需运行；旧的仅保存授权需要重新确认。[配置与使用边界 →](docs/BROWSER-AUTHORIZATION.md) 插件顶部显示版本号和打开 Mac 入口；未检测到本机连接时提供 GitHub 下载链接及登记提示。

## 选择你的工作空间

| 平台 | 当前可用形式 | 使用入口 |
| --- | --- | --- |
| **Mac · 当前 NSH** | macOS 14+ / Apple Silicon，官方原生富文本编辑器 | [当前 Mac](apps/desktop/README.md) |
| **Windows · Desktop** | 共用 NSH 界面与 Rust 密码库，x64 构建 | [Windows 构建说明](tool/windows-desktop/README.md) |
| **Mac · 旧版 SwiftUI** | macOS 13+ / Apple Silicon 与 Intel，兼容与回退保留 | [旧 Mac 说明](apps/macos-legacy/README.md) |
| **Android · 8.0+** | 原生移动预览版；Android 8+ 支持系统自动填充 | [Android 指南](apps/android/README.md) |
| **iPhone / iPad · iOS 16+** | 原生模拟器预览；签名设备分发待完成 | [iOS 指南](apps/ios/README.md) |
| **Chromium 浏览器** | 解压安装插件，连接 Mac 或创建独立资料库 | [插件配置](#快速开始) |

另有功能范围较小的独立 Web；Windows 已提供本次发行的原生 x64 便携包，Linux 暂无原生桌面客户端。以上是开发版本，尚未上架应用商店或扩展商店。独立资料库之间需要明确迁移数据，安装应用不会自动同步。

<details>
<summary>版本、平台验证与待完成的发行工作</summary>

| 客户端 | 当前能力 | 验证与交付状态 |
| --- | --- | --- |
| **旧 Mac · SwiftUI** | SwiftUI 桌面应用，Apple Silicon/Intel 通用构建，本地 Tiptap 图文编辑器 | 开发版本。检查包含完整窗口连续回车与焦点、格式编辑、加密图片和备份失败路径。实体输入法覆盖、macOS 13/Intel 硬件、发行签名和公证仍待完成 |
| **Android 8.0+** | Kotlin/Compose 预览；账号/验证码/钱包对齐旧版操作，笔记采用独立设计 | 已有模拟器 UI 和限定实机非 UI 检查；相机/指纹、旧设备与原生产签名升级仍待验收。系统自动填充需要 Android 8+ |
| **iOS 16+ / iPadOS 16+** | SwiftUI 应用与 Password AutoFill 扩展 | 模拟器流程及设备架构编译通过；合格团队配置、签名设备安装和硬件验收仍未完成 |
| **Chromium 扩展** | 轻量 MV3，Mac 连接和独立资料库，明确选择后填充/保存 | 已有限定 Edge/ego lite、DOM 和签名 helper 检查；更广的 Google Chrome/网站覆盖待完成，采用解压安装 |
| **独立 Web** | 独立加密资料库、增删改查、TOTP、备份/导入和工具 | 共享/WebDAV/QR 界面、完整主题/语言对齐及旧 OPFS 自动迁移尚未完成 |
| **Windows 桌面** | NSH x64 便携包，共用密码库、笔记与平台适配层 | Windows 11 ARM 虚拟机的真实窗口账号及富文本流程通过；浏览器/AI 本机通信、终端运行及更多硬件验收仍待完成 |
| **Linux 桌面** | 无原生桌面客户端 | 尚未实现 |

本次统一版本为 **2.4.1**：NSH Mac build **19**、浏览器 **2.4.1**、Android build **24001**、iOS build **17**。新增个人密码库加密中继同步、设备授权开关、批量冲突处理和手机提醒；Android 需 8.0+。检查通过不代表已上架应用商店或通过生产安全验收，详见[安装说明](docs/NATIVE-RELEASE-NOTES.md)及[中继配置](docs/PERSONAL-RELAY.md)。

</details>

## 快速开始

### 旧版 SwiftUI Mac 与浏览器

先按[原生安装说明](docs/NATIVE-MIGRATION.md#build-and-launch)准备固定版本的 Rust、Node.js、Xcode 和 XcodeGen，再从仓库根目录运行：

```bash
git clone https://github.com/JunWeiUp/PasswordVault.git
cd PasswordVault
bash tool/check_native.sh core
bash tool/check_native.sh macos
bash tool/check_native.sh browser
```

`apps/desktop` 中的 Mac 客户端已使用 NSH 0.4.0 和官方原生 `RichEditor`。项目 Rust 构建脚本要求使用 [huacnlee/cargo](https://huacnlee.github.io/cargo/)，并保留固定的 rustc 工具链。详见 [Mac 构建说明](apps/desktop/README.md)。

Mac 应用生成于 `apps/macos-legacy/build/Build/Products/Release/PasswordVault.app`，解压扩展位于 `apps/browser/dist`。Mac 构建会将编辑器及依赖许可一同本地打包。评估时请使用原生指南中的**隔离虚构资料库**流程。

1. 在 `chrome://extensions` 或 `edge://extensions` 开启开发者模式，加载 `apps/browser/dist`。
2. 使用 Mac 模式时，先在 **Mac 设置 → 浏览器**登记连接，再在插件选择**连接 Mac**，并在 Mac 中确认配对。
3. 也可在插件中创建**独立资料库**，它不会自动复制或共享 Mac 数据。

保持扩展目录和身份稳定。每次交付更新使用 `npm --prefix apps/browser run release:local`，重载后核对实际版本。独立 Web 可通过本机 HTTP 或 HTTPS 托管同一目录，不支持 `file://`。

### Android 与 iOS

当前 Android 源码支持在空闲锁定时间内切换应用后直接返回。Android、Mac 和 iOS 都已去掉共享资料库管理与局域网同步；已有共享记录、备份信息和只读限制仍保留。锁屏、手动锁定、加密草稿和已有备份数据也保留。

分别按 [Android 构建指南](apps/android/README.md)或 [iOS 构建指南](apps/ios/README.md)操作。预览标识与旧生产安装分开，不要卸载已有资料库来绕过签名不匹配。

## 资料由你掌握

原生资料库在磁盘上加密保存笔记、账号、验证码、钱包与设置，应用打开时也一样。由你决定何时备份，以及是否连接自己的 WebDAV 服务器。解锁内容会存在于内存，主动导出的明文文件仍是明文。

<details>
<summary>加密方式、安全边界与剩余工作</summary>

原生 V2 使用 SQLCipher、认证文档加密、带随机盐的 Argon2id 根密钥包装及浏览器认证密文包。本地笔记和服务器凭据沿用同一加密资料库路径。Tiptap 页面不加载远程编辑器资源、不使用持久网站数据存储，CSP 阻止网络内容，仅允许会话绑定的原生图片资源。图文笔记使用版本化 JSON 与包含附件的完整加密备份。解锁时，解密内容仍存在于内存；明确导出的明文文件仍是明文。

已实现功能、自动化检查和人工验收分开记录。剩余工作包括完整进程/GPU 内存对比、独立 Web 对齐、不支持的桌面 SQLite/Web OPFS 与旧共享迁移、更广的硬件/无障碍/服务器检查、生产签名和独立安全审查。插件体积更小，不等于总进程内存已经完成对比。

详见[当前计划](docs/TODO.md)、[安全限制](docs/SECURITY_MODEL.md)及[隐私说明](docs/PRIVACY.md)。漏洞按 [SECURITY.md](docs/SECURITY.md)报告，不要附上真实凭据或资料库导出文件。

</details>

## 一起完善 PasswordVault

普通 PR 只运行受影响平台的任务，详见 [CI 范围、缓存与完整运行说明](docs/CI.md)。

使用[开发检查](docs/DEVELOPMENT.md)、[产物登记](docs/REGISTRY.md)及[发布流程](docs/DEPLOYMENT.md)。原生工作流位于 [.github/workflows/native.yml](.github/workflows/native.yml)，报告 CI 状态时以实际 PR 运行结果为准。贡献使用虚构测试数据，并遵循 [CONTRIBUTING.md](docs/CONTRIBUTING.md)与 [AGENTS.md](AGENTS.md)。

| 主题 | 文档 |
| --- | --- |
| 产品与界面 | [项目规格](docs/PROJECT-SPEC.md) · [设计](docs/DESIGN.md) · [页面结构](docs/PAGE-STRUCTURE.md) |
| 实现 | [架构](docs/ARCHITECTURE.md) · [组件规范](docs/COMPONENT-GUIDELINES.md) |
| 能力补齐 | [应急恢复、完整历史与后续开发进度](docs/CAPABILITY-EXPANSION.md) |
| 结构化资料与安全中心 | [条目、导入与能力目录](docs/STRUCTURED-IMPORT-SECURITY.md) |
| 通行密钥与填充 | [Provider 信任边界与验证](docs/PASSKEYS.md) |
| 对等资料库 | [因果同步与家庭库权限](docs/PEER-LIBRARIES.md) |
| 设备与服务 | [格式 7、兼容性、加密附件与同步门禁](docs/DEVICE-ITEMS.md) |
| 临时分享 | [自托管加密分享服务](services/share/README.md) |
| 平台证据 | [原生迁移](docs/NATIVE-MIGRATION.md) · [Mac 字段对齐](docs/MAC-MOBILE-PARITY.md) · [移动端验收](docs/MOBILE-IMPLEMENTATION.md) · [安卓对齐](docs/ANDROID-LEGACY-PARITY.md) · [浏览器验收](docs/BROWSER-ACCEPTANCE.md) |
| 进度 | [TODO](docs/TODO.md) · [更新记录](docs/CHANGELOG.md) |

<details>
<summary>寻找旧版 Flutter 客户端？</summary>

已按项目所有者要求移除旧 Flutter 客户端及其构建、测试和发布工具；历史源码仍可从 Git 找回。原生客户端保留旧数据导入与兼容性测试。删除源码不代表迁移、实机或安全验收完成；当前开发请使用[原生配置指南](docs/NATIVE-MIGRATION.md)。

</details>

## 许可证

[MIT](LICENSE)。打包依赖保留各自许可证，详见[第三方声明](docs/THIRD_PARTY_NOTICES.md)。

## 个人库中继同步

Mac 作为主库，通过统一中继与 Android 8+、iOS 双向同步；浏览器插件沿用本机桥接。支持创建设备组、默认扫码自动加入、可选配对码审批及成员管理；在 Mac“我的设备”中开启对应设备的“查看并同步修改”即可授权密码库同步。配置、配对、冲突与恢复见[中继同步说明](docs/PERSONAL-RELAY.md)，实际验证范围见[验证记录](docs/PERSONAL-RELAY-VALIDATION.md)。当前验证范围与限制见上述记录。

## 目录说明

客户端源码放在 `apps/`，Rust 核心在 `crates/`，项目说明统一放在 `docs/`。公开签名配置在 `config/signing`，本机密钥与需要保留的备份在已忽略的 `private/`。Cargo、工具链和版本清单保留在根目录；`native-test-output/dist` 保留供已经加载的浏览器扩展使用。

Native Shell Mac 客户端的设备资料支持导入 Python、Shell、JavaScript、配置等 UTF-8 文本，完整显示文件名，打开查看、编辑并复制全文；内容加密保存，导入时不执行脚本；点击运行直接交给首选终端（默认系统 Terminal）；选择会记住，输出、交互及停止由终端处理。回收站中的设备不再阻止重新导入。

[应用目录](apps/README.md) · [NSH Mac 工具](tool/macos-nsh/README.md)

[2.4.1 安装说明](config/release/INSTALL.md) · [发行说明](config/release/NOTES.md)

旧 SwiftUI Mac 仅保留源码与手动构建入口，已关闭独立 CI，本次不发布旧 Mac 包。

CI 成本策略：普通 PR 仅做轻量仓库/密钥检查；原生构建仅手动或发布触发，测试默认关闭。主分支合并后不重复构建，详见 [CI 说明](docs/CI.md)。
