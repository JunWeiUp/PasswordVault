import SwiftUI

struct GeneratorView: View {
  @EnvironmentObject private var store: AppStore
  @State private var password = ""
  @State private var length = 20.0
  @State private var upper = true
  @State private var lower = true
  @State private var digits = true
  @State private var symbols = true
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      DetailToolbar(title: store.t("密码生成器", "Password generator"))
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          Text(store.t("生成一个新密码", "Generate a new password")).font(
            .system(size: 30, weight: .semibold))
          Text(password.isEmpty ? "—" : password).font(
            .system(size: 26, weight: .medium, design: .monospaced)
          ).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            .padding(20).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 12))
          HStack {
            Button(store.t("重新生成", "Regenerate")) { Task { await generate() } }.buttonStyle(
              VaultButtonStyle(.primary)
            ).tint(Palette.blue)
            Button(store.t("复制密码", "Copy password")) { store.copy(password) }.disabled(
              password.isEmpty)
          }.controlSize(.large)
          Divider()
          HStack {
            Text(store.t("密码长度", "Length"))
            Spacer()
            Text("\(Int(length))").monospacedDigit()
          }
          Slider(value: $length, in: 4...64, step: 1)
          Toggle(store.t("大写字母", "Uppercase letters"), isOn: $upper)
          Toggle(store.t("小写字母", "Lowercase letters"), isOn: $lower)
          Toggle(store.t("数字", "Numbers"), isOn: $digits)
          Toggle(store.t("符号", "Symbols"), isOn: $symbols)
          if !upper && !lower && !digits && !symbols {
            Text(store.t("至少选择一种字符。", "Select at least one character type.")).foregroundStyle(
              .secondary)
          }
        }.padding(36).frame(maxWidth: 820, alignment: .leading)
      }
    }.task(id: "\(length)-\(upper)-\(lower)-\(digits)-\(symbols)") { await generate() }
  }
  private func generate() async {
    guard upper || lower || digits || symbols else {
      password = ""
      return
    }
    do {
      let result = try await store.perform([
        "op": .string("generate"), "length": .number(length), "upper": .bool(upper),
        "lower": .bool(lower), "digits": .bool(digits), "symbols": .bool(symbols),
      ])
      password = result.object["password"]?.string ?? ""
    } catch { store.report(error) }
  }
}

struct PasswordAuditView: View {
  @EnvironmentObject private var store: AppStore
  @State private var findings: [JSONValue] = []
  @State private var loaded = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      DetailToolbar(title: store.t("密码健康", "Password health"))
      Text(store.t("检查常用密码", "Review your passwords")).font(.system(size: 30, weight: .semibold))
        .padding(.horizontal, 36).padding(.bottom, 20)
      Text(
        store.t(
          "检查弱密码、重复密码和过期密码，不代表应用通过安全审计。",
          "Checks weak, reused, and expired passwords; this is not an application security audit.")
      ).foregroundStyle(.secondary).padding(.horizontal, 36)
      if !loaded {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if findings.isEmpty {
        EmptyState(
          symbol: "checkmark.circle", title: store.t("未发现此类问题", "No issues found"),
          message: store.t(
            "当前没有弱密码、重复密码或过期密码。", "No weak, reused, or expired passwords were found."))
      } else {
        List(Array(findings.enumerated()), id: \.offset) { _, finding in
          Button {
            store.navigate(.passwords)
            store.selectedID = finding.object["id"]?.string
          } label: {
            HStack {
              Text(finding.object["title"]?.string ?? "")
              Spacer()
              if finding.object["weak"]?.bool == true {
                Text(store.t("长度不足 12 位", "Under 12 characters"))
              }
              if finding.object["reused"]?.bool == true { Text(store.t("重复使用", "Reused")) }
              if finding.object["expired"]?.bool == true { Text(store.t("已过期", "Expired")) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).contentShape(
              Rectangle())
          }.buttonStyle(VaultButtonStyle(.row))
        }.padding(20)
      }
    }.task {
      do {
        findings = try await store.perform(["op": .string("audit")]).array
        loaded = true
      } catch { store.report(error) }
    }
  }
}
