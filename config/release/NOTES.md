# PasswordVault 2.4.0

This regular GitHub release contains developer-preview clients. It does not claim
production security acceptance or an independent security audit.

## Changes

- Introduce the current Native Shell 0.4 Mac client with the official native
  RichEditor, formatting, tables, undo/redo, encrypted attachments and a fixed
  bottom status bar. Preserve unsupported legacy note formats without silently
  rewriting them.
- Add device/service records, encrypted scripts and configuration documents,
  scoped local AI access, recovery/history tools and expanded account workflows.
- Improve encrypted device relay access and mobile synchronization, and browser
  credential saving and offline behavior.
- Retain the SwiftUI Mac client in `apps/macos-legacy`; share the web editor across
  legacy Mac, mobile and browser clients. Remove retired Flutter source/tooling.
- Pin huacnlee/cargo in project build entry points and CI.

## Choose a download

- **Current Mac:** `macos-arm64-development.zip`, macOS 14+ on Apple Silicon.
- **Legacy Mac:** `macos-legacy-universal-development.zip`, macOS 13+ on Apple
  Silicon or Intel. This is the previous SwiftUI implementation.
- **Android:** choose the ARM64 or x86_64 APK for Android 8.0+.
- **Browser / Web:** unpacked Chromium extension or standalone HTTPS/localhost app.
- **iOS:** simulator archive and source only; no signed iPhone installation package.

Read `INSTALL.md` and verify the complete download set against `SHA256SUMS`.
`BUILD.json` records the exact commit and component versions. Mac downloads are
ad-hoc signed and not notarized; Touch ID enrollment is not guaranteed. Keep a
verified encrypted backup before changing clients or enabling new storage formats.
Do not uninstall the only copy of a vault to resolve a signing mismatch.

## 中文

本次新增 NSH 0.4 原生 Mac 客户端及官方富文本编辑器，底部字数/保存提示固定；
同时整理设备资料、AI 访问、恢复历史、中继同步及浏览器保存功能。旧 SwiftUI Mac
保留并明确标为 Legacy，Intel 用户可选择旧版通用包。

这是开发预览软件的常规 GitHub Release，仍有独立安全审计、真实输入法、无障碍及
部分设备场景待验收。新 Mac 包支持 macOS 14+ / Apple Silicon，未公证；升级前保留
并验证加密备份。iOS 附件为模拟器包，不能直接安装到 iPhone。
