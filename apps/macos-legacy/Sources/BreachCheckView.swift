import SwiftUI

struct BreachCheckView: View {
  @EnvironmentObject private var store: AppStore
  @State private var consent = false
  @State private var running = false
  @State private var completed = false
  @State private var failed = false
  @State private var affected = Set<String>()
  @State private var task: Task<Void, Never>?
  @State private var generation = UUID()
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(store.t("允许本次联网检查已泄露密码", "Allow an online breached-password check"), isOn: $consent)
      Text(
        store.t(
          "使用 Have I Been Pwned：仅发送 SHA-1 哈希的前 5 位，不发送密码、完整哈希、网址或用户名。服务可看到请求 IP；默认关闭。",
          "Uses Have I Been Pwned: sends only the first 5 characters of a SHA-1 hash, never passwords, complete hashes, websites or usernames. The service sees your IP address. Disabled by default."
        )
      ).font(.caption).foregroundStyle(.secondary)
      Link("Have I Been Pwned", destination: URL(string: "https://haveibeenpwned.com/Passwords")!)
      HStack {
        Button(store.t("检查已泄露密码", "Check breached passwords"), action: start).disabled(
          !consent || running)
        if running {
          ProgressView().controlSize(.small)
          Button(store.t("取消", "Cancel")) { cancel() }
        }
      }
      if failed {
        Text(
          store.t(
            "检查未完成，请检查网络后重试。不能据此判断密码安全。",
            "Check incomplete. Retry after checking your connection; this is not a clean result.")
        ).foregroundStyle(.orange)
      }
      if completed {
        Text(
          affected.isEmpty
            ? store.t("本次未发现已知泄露密码。", "No known breached passwords found in this check.")
            : store.t(
              "发现 \(affected.count) 个条目使用已泄露密码。",
              "Found breached passwords in \(affected.count) entries."))
        if !affected.isEmpty {
          ScrollView {
            LazyVStack(alignment: .leading) {
              ForEach(store.items.filter { affected.contains($0.id) }) { item in
                Button(item.title) {
                  store.navigate(item.type == "totp" ? .codes : .passwords)
                  store.selectedID = item.id
                }
              }
            }
          }.frame(maxHeight: 160)
        }
      }
    }
    .onChange(of: consent) { if !$0 { cancel() } }
    .onChange(of: store.unlocked) { if !$0 { cancel() } }
    .onChange(of: store.items) { _ in cancel() }
    .onDisappear { cancel() }
  }
  private func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    affected = []
    completed = false
    running = false
    failed = false
  }
  private func start() {
    guard consent, store.unlocked else { return }
    cancel()
    running = true
    let current = generation
    let items = store.items
    task = Task {
      do {
        let result = try await PasswordBreachCheck.check(items)
        guard !Task.isCancelled, current == generation, consent, store.unlocked else { return }
        affected = result
        completed = true
        running = false
      } catch {
        guard !Task.isCancelled, current == generation, store.unlocked else { return }
        failed = true
        running = false
      }
    }
  }
}
