import SwiftUI

struct MobileHistoryView: View {
  @EnvironmentObject private var store: MobileVaultStore
  let id: String
  @State private var enabled = false
  @State private var rows: [JSONValue] = []
  @State private var total = 0
  @State private var selected: JSONValue?
  @State private var reveal = false
  @State private var working = false
  @State private var action: String?
  var body: some View {
    List {
      if !enabled {
        Text(
          store.t(
            "启用将升级资料库格式，旧客户端无法打开。历史包含旧秘密及附件；请先升级其他客户端。",
            "Enabling upgrades the vault format. Old clients cannot open it. History retains old secrets and attachments; update other clients first."
          ))
        Button(store.t("启用完整历史", "Enable complete history")) {
          run {
            _ = try await store.perform(["op": .string("history-enable")])
            try await store.refresh()
            try await load()
          }
        }
      } else {
        ForEach(rows, id: \.self) { revision in
          Button {
            selected = revision
            reveal = false
          } label: {
            VStack(alignment: .leading) {
              Text(revision.object["item"]?.object["title"]?.string ?? store.t("已删除", "Deleted"))
              Text(
                Date(timeIntervalSince1970: (revision.object["capturedAt"]?.number ?? 0) / 1000)
                  .formatted()
              ).font(.caption)
            }
          }
        }
        if rows.count < total {
          Button(store.t("加载更多", "Load more")) { run { try await load(append: true) } }
        }
        if let selected {
          Section(store.t("版本预览", "Version preview")) {
            Toggle(
              store.t("显示完整内容（含敏感信息）", "Reveal complete contents (includes secrets)"), isOn: $reveal
            )
            if reveal {
              Text(render(selected.object["item"] ?? .null)).font(.caption.monospaced())
                .textSelection(.enabled)
            }
            Button(store.t("恢复此版本", "Restore this version")) { action = "restore" }
              .disabled(selected.object["item"]?.object.isEmpty != false)
          }
        }
        Button(store.t("清理旧版本", "Clear older versions"), role: .destructive) { action = "prune" }
      }
      if working { ProgressView() }
    }.navigationTitle(store.t("版本历史", "Version history")).disabled(working)
      .task { do { try await load() } catch { store.report(error) } }
      .confirmationDialog(
        store.t("确认修改历史？", "Confirm history action?"),
        isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }),
        titleVisibility: .visible
      ) {
        Button(store.t("确认", "Confirm"), role: action == "prune" ? .destructive : nil) {
          let operation = action
          action = nil
          run {
            if operation == "prune" {
              _ = try await store.perform(["op": .string("history-prune"), "id": .string(id)])
            } else if let selected {
              _ = try await store.perform([
                "op": .string("history-restore"), "id": .string(id),
                "revisionId": selected.object["id"] ?? .null,
                "time": .string(ISO8601DateFormatter().string(from: Date())),
              ])
            }
            selected = nil
            reveal = false
            try await store.refresh()
            try await load()
          }
        }
      } message: {
        Text(
          action == "prune"
            ? store.t(
              "保留当前内容。个人库清理本机旧版本；对等资料库仅隐藏旧版本，旧内容仍在同步日志中。已有备份不受影响。",
              "Current contents remain. Personal vaults clear local older versions; peer libraries only hide them and retain their contents in the sync log. Existing backups are unchanged."
            )
            : store.t(
              "恢复后创建新版本，当前内容保留在历史中。",
              "Restoring creates a new version and retains current contents in history."))
      }
      .onDisappear {
        rows = []
        selected = nil
        reveal = false
      }
  }
  private func load(append: Bool = false) async throws {
    enabled =
      try await store.perform(["op": .string("history-status")]).object["enabled"]?.bool ?? false
    let value = try await store.perform([
      "op": .string("history-list"), "id": .string(id),
      "offset": .number(Double(append ? rows.count : 0)),
    ])
    total = Int(value.object["total"]?.number ?? 0)
    let page = value.object["revisions"]?.array ?? []
    if append { rows += page } else { rows = page }
  }
  private func render(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? ""
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    guard !working else { return }
    working = true
    Task { @MainActor in
      defer { working = false }
      do { try await action() } catch { store.report(error) }
    }
  }
}
