import SwiftUI

struct FullEntryHistoryView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let item: VaultItem
  @State private var enabled = false
  @State private var revisions: [JSONValue] = []
  @State private var selection: String?
  @State private var reveal = false
  @State private var busy = false
  @State private var message: String?
  @State private var confirmRestore = false
  @State private var confirmPrune = false
  @State private var total = 0
  private var selected: JSONValue? { revisions.first { $0.object["id"]?.string == selection } }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(store.t("条目版本历史", "Item version history")).font(.title2.bold())
      Text(item.title).foregroundStyle(.secondary)
      if let message { Text(message).foregroundStyle(.red) }
      if !enabled {
        Text(
          store.t(
            "启用后保留完整条目版本及其附件，并升级本机数据格式。旧客户端无法打开升级后的资料库；请先升级全部客户端。历史目前在本机记录，完整备份会包含历史。",
            "Enabling retains complete entry versions and attachments and upgrades the local data format. Older clients cannot open it; update all clients first. History is currently recorded locally and included in complete backups."
          ))
        Button(store.t("启用完整历史", "Enable full history")) {
          run {
            _ = try await store.perform(["op": .string("history-enable")])
            await store.refresh()
            try await load()
          }
        }
      } else {
        Text(
          store.t(
            "恢复会创建一个新版本。永久删除条目时也会删除本机历史；已有备份不会随之删除。",
            "Restoring creates a new version. Permanent deletion also erases local history; existing backups remain unchanged."
          )
        ).font(.caption).foregroundStyle(.secondary)
        Picker(store.t("版本", "Version"), selection: $selection) {
          Text(store.t("选择版本", "Select a version")).tag(Optional<String>.none)
          ForEach(revisions, id: \.self) { revision in
            let fields = revision.object
            Text(
              Date(timeIntervalSince1970: (fields["capturedAt"]?.number ?? 0) / 1000).formatted()
                + " · " + (fields["item"]?.object["title"]?.string ?? store.t("已删除", "Deleted"))
            )
            .tag(Optional(fields["id"]?.string ?? ""))
          }
        }
        if revisions.count < total {
          Button(store.t("加载更多版本", "Load more versions")) { run { try await load(append: true) } }
        }
        Button(store.t("清理旧版本…", "Clear older versions…"), role: .destructive) {
          confirmPrune = true
        }.disabled(!store.canEdit(item))
        if let selected, let snapshot = selected.object["item"] {
          let fields = snapshot.object
          let keys = Set(fields.keys).union(item.fields.keys).filter {
            fields[$0] != item.fields[$0]
          }.sorted()
          Text(
            store.t("与当前版本不同的字段：", "Fields different from the current version: ")
              + (keys.isEmpty ? store.t("无", "None") : keys.joined(separator: ", "))
          ).font(.callout)
          Toggle(
            store.t("显示完整内容（包含敏感信息）", "Reveal complete contents (includes secrets)"), isOn: $reveal)
          if reveal {
            ScrollView {
              Text(render(snapshot)).font(.system(.caption, design: .monospaced)).textSelection(
                .enabled
              ).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 230)
          }
          Button(store.t("恢复此版本…", "Restore this version…")) { confirmRestore = true }.disabled(
            !store.canEdit(item) || fields.isEmpty)
        }
      }
      HStack {
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button(store.t("关闭", "Close")) { dismiss() }
      }
    }.padding(28).frame(width: 600).disabled(busy)
      .task { run { try await load() } }
      .onChange(of: selection) { _ in reveal = false }
      .onChange(of: store.unlocked) {
        if !$0 {
          revisions = []
          reveal = false
          dismiss()
        }
      }
      .onDisappear {
        revisions = []
        reveal = false
      }
      .confirmationDialog(
        store.t("恢复所选版本？", "Restore selected version?"), isPresented: $confirmRestore,
        titleVisibility: .visible
      ) {
        Button(store.t("恢复", "Restore")) {
          guard let selection else { return }
          run {
            _ = try await store.perform([
              "op": .string("history-restore"), "id": .string(item.id),
              "revisionId": .string(selection),
              "time": .string(ISO8601DateFormatter().string(from: Date())),
            ])
            await store.refresh()
            dismiss()
          }
        }
      } message: {
        Text(
          store.t(
            "当前内容会保留在历史中，恢复的内容将成为新版本。",
            "The current contents remain in history. The restored contents become a new version."))
      }
      .confirmationDialog(
        store.t("清理此条目的旧版本？", "Clear older versions of this entry?"), isPresented: $confirmPrune,
        titleVisibility: .visible
      ) {
        Button(store.t("清理旧版本", "Clear older versions"), role: .destructive) {
          run {
            _ = try await store.perform(["op": .string("history-prune"), "id": .string(item.id)])
            selection = nil
            reveal = false
            try await load()
          }
        }
      } message: {
        Text(
          store.t(
            "保留当前内容。个人库清理本机旧版本；对等资料库仅隐藏旧版本，旧内容仍在同步日志中。已有备份不受影响。",
            "Current contents remain. Personal vaults clear local older versions; peer libraries only hide them and retain their contents in the sync log. Existing backups are unchanged."
          ))
      }
  }
  private func render(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? ""
  }
  private func load(append: Bool = false) async throws {
    enabled =
      try await store.perform(["op": .string("history-status")]).object["enabled"]?.bool ?? false
    let response = try await store.perform([
      "op": .string("history-list"), "id": .string(item.id),
      "offset": .number(Double(append ? revisions.count : 0)),
    ])
    let page = response.object["revisions"]?.array ?? []
    total = Int(response.object["total"]?.number ?? 0)
    if append {
      revisions.append(
        contentsOf: page.filter { value in
          !revisions.contains(where: { $0.object["id"] == value.object["id"] })
        })
    } else {
      revisions = page
    }
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    message = nil
    Task { @MainActor in
      defer { busy = false }
      do { try await action() } catch { message = store.errorMessage(error, context: .save) }
    }
  }
}
