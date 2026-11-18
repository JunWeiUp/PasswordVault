# 实验：移动端界面改用 Native Shell（NSH）

**状态：已结束，未采用（2026-11-18）。** iOS 与 Android 继续使用原生 SwiftUI / Jetpack Compose 界面。本目录不参与 CI 构建，不链接进任何应用，也不随版本发布。

## 实验问题

能否把桌面端使用的 NSH（TSX + Rust）界面嵌入现有 iOS / Android 应用，让 Mac、Windows、iOS、Android 共用一套 TSX 界面代码？

## 做了什么

只试点一个页面——验证码列表，同时嵌入两个移动端应用：

| 路径 | 内容 |
| --- | --- |
| `ui/` | 两端共用的 NSH TSX 工程及测试（宿主应用用桩数据） |
| `ios/NshScreen.swift` | `NshAppView` 封装与宿主函数，替换验证码标签页 |
| `ios/integration.diff` | `project.yml`（链接 `NativeShell.xcframework`、拷贝 `nsh` 页面包）、标签接线与 UI 测试改动 |
| `android/NshScreen.kt` | Compose 中的 `NshView` 与宿主函数，替换验证码页 |
| `android/NshCodesTest.kt` | 模拟器上的界面测试 |
| `android/integration.diff` | Gradle（`nsh.aar`、`assets/nsh`）与工作区接线 |
| `tool/fetch-embed.sh` | 下载并校验固定版本 NSH 0.5.1 嵌入 SDK 到被忽略的 `vendor/nsh-embed/` |
| `tool/build-bundle.sh` | 把 `ui/` 构建为 `ui/build/nsh`（`bundle.nshc` 约 40 KB） |
| `tool/build_mobile_core.diff` | 把上面两个脚本接入 `tool/build_mobile_core.sh` |

**安全边界**：TSX 页面只能通过 `ui/nsh.json` 授权的 `nsh/host` 调用（`vault.*`、`clipboard.copy`）访问应用，没有联网、文件、剪贴板权限；密钥不进入 JS——验证码由原生计算，复制由原生执行，保留 iOS 仅本机/过期与 Android 敏感剪贴内容保护。

## 结果

功能上两端都跑通：iOS 27 模拟器与 Pixel 9（ARM64）模拟器都显示了密码库中的实时验证码，复制与进入详情经由宿主完成，读屏标签可用；TSX 测试、iOS UI 流程测试与 Android 界面测试均通过。

**否决原因是体积。** NSH 以单个预编译运行时提供（JS 引擎、布局与文字引擎、完整组件库、GPU/着色器、SVG、公式排版、TLS、Rust 展开表），页面在运行时动态调用组件，链接器无法裁掉未用部分：

| | 原生（main） | 嵌入 NSH | 增量 |
| --- | --- | --- | --- |
| iOS Release arm64 可执行文件（去符号） | 12.5 MB | 64.1 MB | +51.6 MB |
| iOS 可执行文件 gzip（下载估算） | 5.2 MB | 26.0 MB | +20.8 MB |
| Android ARM64 APK（.so 不压缩） | 13.3 MB | 68.1 MB | +54.8 MB |
| Android ARM64 APK（.so 压缩，估算） | 13.3 MB | 约 33 MB | 约 +20 MB（安装仍 +49 MB） |

iOS 代码段从 6.6 MB 增至 40.9 MB，主要是 `nsh_base`（5.9 MB）、NSH 核心/引擎（约 4.7 MB）、`nsh_platform_ios` 及 Swift 层（约 4.4 MB）、JS 引擎（约 3.4 MB）、`wgpu`/`naga`（约 1.7 MB），另有约 8 MB 展开与异常表。作为对照，桌面端本就带着同一运行时：v2.5.4 macOS ZIP 32.5 MB（安装后 92 MB），Windows ZIP 26.8 MB（解压 68.9 MB）。

未测：启动耗时、内存、中文输入（验证码页无输入框）、真机。

## 结论

负责人因体积代价决定移动端保留原生界面。尚未验证的备选方案：从源码编译去掉 GPU、SVG、公式、TLS 等功能并使用 `panic=abort` 的精简版 NSH，可能节省 30%–50%，但每次升级 NSH 都要维护自定义构建。

## 复现

复现步骤见英文版 [README.md](README.md#reproducing)。差异基于 `main` 的 218fddb，NSH 与 SDK 固定为 0.5.1；Android 测试只在模拟器上运行，应用开启防截屏，系统截图为黑屏，需查看界面层级。
