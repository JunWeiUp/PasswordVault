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

原生客户端目前为**开发预览版**。[平台状态](#选择你的工作空间)与[安全模型](docs/security/SECURITY_MODEL.md)记录当前限制，独立安全审查仍待完成。

**下载原生版 2.5.4：** [GitHub Release](https://github.com/JunWeiUp/PasswordVault/releases/tag/v2.5.4) · [安装方式与签名限制](docs/releases/NATIVE-RELEASE-NOTES.md)。包含 Android、Mac、Windows x64、解压式插件、Web 和 iOS 模拟器包，各一个。后续版本改为发布五个包：独立 Web 包已停用，由浏览器插件替代。

**Mac 客户端说明：** [`apps/desktop`](apps/desktop/README.md) 是唯一的 Mac 客户端（NSH 0.5.1，macOS 14+ / Apple Silicon），与 Windows 共用源码。旧版 SwiftUI Mac 客户端已从源码中移除，可在 Git 历史中找到。
Mac 开发版本使用独立 Rust 后台服务。关闭窗口会先保存草稿并退出界面；已授权的浏览器查询和锁定管理继续运行。重新打开应用可编辑，选择“退出”则停止两个进程。验证方式和限制见[桌面指南](apps/desktop/README.md)。


共享桌面源码统一命名为 **Desktop**（`apps/desktop`）：Mac 与 Windows 共用 NSH 界面和密码库业务逻辑，系统能力通过平台适配层实现。Windows 的安装、构建、验证和功能限制见 [Windows 构建说明](tool/windows-desktop/README.md)。

## 少一点翻找，多一点从容

- **随时记下想法。** 在 Mac 上像写文档一样写笔记，支持富文本、表格、图片、附件、撤销/重做与自动加密保存。分类、搜索、收藏和置顶，让想法有处可寻。
- **重要资料放在一起。** 密码、附加账号、验证码与钱包资料，常用字段一次整理完整。桌面搜索覆盖可见详情与笔记正文，支持多个关键词跨字段匹配。
- **登录后，继续手头的事。** 在支持的密码框旁选择账号，核对新的登录信息后再保存，需要修改时直接打开 Mac 中的记录。

误删了条目，可以从回收站找回；需要迁移资料，可以导出加密备份，或在自己的 WebDAV 服务器上管理备份。

## 看看实际体验

### 在桌面上，留出思考的空间

熟悉的 Mac 三栏布局，把分类、笔记列表与正文放在眼前。标题、列表与待办随输入自然呈现，个人笔记提供表格、图片工具和加密附件。Markdown 导出会损失部分格式，详见[图文笔记兼容与备份](docs/product/RICH-NOTES.md)。

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

轻量 Chromium 插件可以连接 Mac，也可以创建**数据分开的独立加密资料库**，不包含 Flutter 或 CanvasKit 运行时。[查看浏览器配置 →](docs/migrations/NATIVE-MIGRATION.md#build-and-launch) 点击插件中的**添加账号密码**即可为当前网站手动保存账号，无需网页上有登录表单。连接 Mac 模式支持[离线保存登录/注册账号，连接后自动同步](docs/browser/BROWSER-OFFLINE-SAVE.md)。

浏览器 2.2.11 / Mac 2.2.11 支持直接显示、查看和填充当前网站账号，图标角标显示数量，Mac 无需保持打开。在插件中验证 Mac 主密码，勾选**打开 Mac 时自动解锁**即可启用启动解锁。组件仍按需运行；旧的仅保存授权需要重新确认。[配置与使用边界 →](docs/browser/BROWSER-AUTHORIZATION.md) 插件顶部显示版本号和打开 Mac 入口；未检测到本机连接时提供 GitHub 下载链接及登记提示。

## 选择你的工作空间

| 平台 | 当前可用形式 | 使用入口 |
| --- | --- | --- |
| **Mac · 当前 NSH** | macOS 14+ / Apple Silicon，官方原生富文本编辑器 | [当前 Mac](apps/desktop/README.md) |
| **Windows · Desktop** | 共用 NSH 界面与 Rust 密码库，x64 构建 | [Windows 构建说明](tool/windows-desktop/README.md) |
| **Android · 8.0+** | 原生移动预览版；Android 8+ 支持系统自动填充 | [Android 指南](apps/android/README.md) |
| **iPhone / iPad · iOS 16+** | 原生模拟器预览；签名设备分发待完成 | [iOS 指南](apps/ios/README.md) |
| **Chromium 浏览器** | 解压安装插件，连接 Mac 或创建独立资料库 | [插件配置](#快速开始) |

Windows 已提供本次发行的原生 x64 便携包，Linux 暂无原生桌面客户端。以上是开发版本，尚未上架应用商店或扩展商店。独立资料库之间需要明确迁移数据，安装应用不会自动同步。

<details>
<summary>版本、平台验证与待完成的发行工作</summary>

| 客户端 | 当前能力 | 验证与交付状态 |
| --- | --- | --- |
| **Android 8.0+** | Kotlin/Compose 预览；账号/验证码/钱包对齐旧版操作，笔记采用独立设计 | 已有模拟器 UI 和限定实机非 UI 检查；相机/指纹、旧设备与原生产签名升级仍待验收。系统自动填充需要 Android 8+ |
| **iOS 16+ / iPadOS 16+** | SwiftUI 应用与 Password AutoFill 扩展 | 模拟器流程及设备架构编译通过；合格团队配置、签名设备安装和硬件验收仍未完成 |
| **Chromium 扩展** | 轻量 MV3，Mac 连接和独立资料库，明确选择后填充/保存 | 已有限定 Edge/ego lite、DOM 和签名 helper 检查；更广的 Google Chrome/网站覆盖待完成，采用解压安装 |
| **Windows 桌面** | NSH x64 便携包，共用密码库、笔记与平台适配层 | Windows 11 ARM 虚拟机的真实窗口账号及富文本流程通过；浏览器/AI 本机通信、终端运行及更多硬件验收仍待完成 |
| **Linux 桌面** | 无原生桌面客户端 | 尚未实现 |

本次统一版本为 **2.5.4**：NSH Mac build **39**、浏览器 **2.5.4**、Android build **25004**、iOS build **20**。本次更新补齐 NSH Mac 扩展能力（更新密码、在 Mac 打开、验证码与银行卡/身份确认、窗口即时刷新、明文密码框识别及离线待同步数量提示），保持证书签名 Mac 更新后的“启动自动解锁”授权，并为设备与脚本资料增加可选标题（设置后默认优先显示）。Android 需 8.0+。检查通过不代表已上架应用商店或通过生产安全验收，详见[安装说明](docs/releases/NATIVE-RELEASE-NOTES.md)及[中继配置](docs/architecture/PERSONAL-RELAY.md)。

</details>

## 快速开始

### Mac 与浏览器

先按[原生安装说明](docs/migrations/NATIVE-MIGRATION.md#build-and-launch)准备固定版本的 Rust、Node.js、Xcode 和 XcodeGen，再从仓库根目录运行：

```bash
git clone https://github.com/JunWeiUp/PasswordVault.git
cd PasswordVault
bash tool/check_native.sh core
bash tool/check_native.sh macos
bash tool/check_native.sh browser
```

全部 Rust 代码使用同一个固定工具链（1.98.0）。`check_native.sh macos` 检查 `apps/desktop` 中的 Native Shell 桌面客户端，它使用 NSH 0.5.1 和官方原生 `RichEditor`。项目 Rust 构建脚本要求使用 [huacnlee/cargo](https://huacnlee.github.io/cargo/)，并使用固定的 rustc。详见 [Mac 构建说明](apps/desktop/README.md)。

解压扩展位于 `apps/browser/dist`。评估时请使用原生指南中的**隔离虚构资料库**流程。

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

详见[当前计划](docs/product/TODO.md)、[安全限制](docs/security/SECURITY_MODEL.md)及[隐私说明](docs/security/PRIVACY.md)。漏洞按 [SECURITY.md](docs/security/SECURITY.md)报告，不要附上真实凭据或资料库导出文件。

</details>

## 一起完善 PasswordVault

普通 PR 只运行受影响平台的任务，详见 [CI 范围、缓存与完整运行说明](docs/development/CI.md)。

使用[开发检查](docs/development/DEVELOPMENT.md)、[产物登记](docs/releases/REGISTRY.md)及[发布流程](docs/releases/DEPLOYMENT.md)。原生工作流位于 [.github/workflows/native.yml](.github/workflows/native.yml)，报告 CI 状态时以实际 PR 运行结果为准。贡献使用虚构测试数据，并遵循 [CONTRIBUTING.md](docs/development/CONTRIBUTING.md)与 [AGENTS.md](AGENTS.md)。

[按分类浏览全部本地文档](docs/README.md)。

| 主题 | 文档 |
| --- | --- |
| 产品与界面 | [项目规格](docs/product/PROJECT-SPEC.md) · [设计](docs/design/DESIGN.md) · [页面结构](docs/design/PAGE-STRUCTURE.md) |
| 实现 | [架构](docs/architecture/ARCHITECTURE.md) · [组件规范](docs/design/COMPONENT-GUIDELINES.md) |
| 能力补齐 | [应急恢复、完整历史与后续开发进度](docs/product/CAPABILITY-EXPANSION.md) |
| 结构化资料与安全中心 | [条目、导入与能力目录](docs/security/STRUCTURED-IMPORT-SECURITY.md) |
| 通行密钥与填充 | [Provider 信任边界与验证](docs/browser/PASSKEYS.md) |
| 对等资料库 | [因果同步与家庭库权限](docs/architecture/PEER-LIBRARIES.md) |
| 设备与服务 | [格式 7、兼容性、加密附件与同步门禁](docs/architecture/DEVICE-ITEMS.md) |
| 平台证据 | [原生迁移](docs/migrations/NATIVE-MIGRATION.md) · [Mac 字段对齐](docs/platforms/MAC-MOBILE-PARITY.md) · [移动端验收](docs/platforms/MOBILE-IMPLEMENTATION.md) · [安卓对齐](docs/platforms/ANDROID-LEGACY-PARITY.md) · [浏览器验收](docs/browser/BROWSER-ACCEPTANCE.md) |
| 进度 | [TODO](docs/product/TODO.md) · [更新记录](docs/releases/CHANGELOG.md) |

<details>
<summary>寻找旧版 Flutter 客户端？</summary>

已按项目所有者要求移除旧 Flutter 客户端及其构建、测试和发布工具；历史源码仍可从 Git 找回。原生客户端保留旧数据导入与兼容性测试。删除源码不代表迁移、实机或安全验收完成；当前开发请使用[原生配置指南](docs/migrations/NATIVE-MIGRATION.md)。

</details>

## 许可证

[MIT](LICENSE)。打包依赖保留各自许可证，详见[第三方声明](docs/security/THIRD_PARTY_NOTICES.md)。

## 个人库中继同步

Mac、Windows、Android 8+ 与 iOS 作为设备组内的平等成员双向同步，没有主库、逐台授权或冲突列表。扫码加入即可同步；同时修改同一条以较新的为准，旧版本保留在条目历史；现有设备组原地升级并保留加密快照。浏览器插件沿用本机桥接。配置、配对、冲突与恢复见[中继同步说明](docs/architecture/PERSONAL-RELAY.md)，实际验证范围见[验证记录](docs/architecture/PERSONAL-RELAY-VALIDATION.md)。当前验证范围与限制见上述记录。

## 目录说明

客户端源码放在 `apps/`，Rust 核心在 `crates/`，项目说明统一放在 `docs/`。公开签名配置在 `config/signing`，本机密钥与需要保留的备份在已忽略的 `private/`。Cargo、工具链和版本清单保留在根目录；`native-test-output/dist` 保留供已经加载的浏览器扩展使用。

Native Shell Mac 客户端的设备资料支持导入 Python、Shell、JavaScript、配置等 UTF-8 文本，完整显示文件名，打开查看、编辑并复制全文；内容加密保存，导入时不执行脚本；点击运行直接交给首选终端（默认系统 Terminal）；选择会记住，输出、交互及停止由终端处理。回收站中的设备不再阻止重新导入。

[应用目录](apps/README.md) · [NSH Mac 工具](tool/macos-nsh/README.md)

[2.5.4 安装说明](config/release/INSTALL.md) · [发行说明](config/release/NOTES.md)

CI 成本策略：普通 PR 仅做轻量仓库/密钥检查；原生构建仅手动或发布触发，测试默认关闭。主分支合并后不重复构建，详见 [CI 说明](docs/development/CI.md)。
