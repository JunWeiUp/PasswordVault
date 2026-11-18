import SwiftUI

/// Shown on lists when a personal device group is set up but the relay is unreachable. Uses the
/// relay's existing connection state; it never probes the network itself.
struct RelayOfflineBanner: View {
  @ObservedObject var relay: VaultRelay
  let t: (String, String) -> String
  var body: some View {
    if relay.offline {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(t("离线 · 修改先加密保存在本机", "Offline · changes are encrypted on this device first"))
            .font(.subheadline.weight(.medium))
          Text(t("恢复连接后自动同步。", "They sync automatically when the connection returns."))
            .font(.caption).foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: "icloud.slash").foregroundStyle(.orange)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("relay.offline")
    }
  }
}

/// Context menu for one entry: edit, pin, favorite, move (notes), history and Trash.
struct EntryMenuItems: View {
  @EnvironmentObject private var store: MobileVaultStore
  let item: VaultItem
  let edit: () -> Void
  let history: () -> Void
  let move: () -> Void
  let trash: () -> Void
  var body: some View {
    let editable = store.canEdit(item)
    if item.isDeleted {
      if editable {
        Button { Task { await store.trash(item) } } label: {
          Label(store.t("恢复", "Restore"), systemImage: "arrow.uturn.backward")
        }
        Button(role: .destructive, action: trash) {
          Label(store.t("永久删除…", "Delete permanently…"), systemImage: "trash")
        }.disabled(!item.string("sharedVaultId").isEmpty)
      }
    } else {
      if editable {
        Button(action: edit) { Label(store.t("编辑", "Edit"), systemImage: "pencil") }
        Button { Task { await store.toggle(item.id, field: "isPinned") } } label: {
          Label(item.isPinned ? store.t("取消置顶", "Unpin") : store.t("置顶", "Pin"),
            systemImage: item.isPinned ? "pin.slash" : "pin")
        }
        Button { Task { await store.toggle(item.id, field: "isFavorite") } } label: {
          Label(item.isFavorite ? store.t("取消收藏", "Unfavorite") : store.t("收藏", "Favorite"),
            systemImage: item.isFavorite ? "star.slash" : "star")
        }
        if item.type == "secureNote" {
          Button(action: move) { Label(store.t("移动到分类…", "Move to category…"), systemImage: "folder") }
        }
      }
      Button(action: history) {
        Label(store.t("版本历史", "Version history"), systemImage: "clock.arrow.circlepath")
      }
      if editable {
        Button(role: .destructive, action: trash) {
          Label(store.t("移到回收站…", "Move to Trash…"), systemImage: "trash")
        }
      }
    }
  }
}

/// Version history opened from a context menu.
struct EntryHistorySheet: View {
  @EnvironmentObject private var store: MobileVaultStore
  @Environment(\.dismiss) private var dismiss
  let id: String
  var body: some View {
    NavigationStack {
      MobileHistoryView(id: id)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button(store.t("完成", "Done")) { dismiss() } }
        }
    }
  }
}

/// Picks a note category for one or more notes; existing categories or a new name.
struct MoveToCategorySheet: View {
  @EnvironmentObject private var store: MobileVaultStore
  @Environment(\.dismiss) private var dismiss
  let ids: Set<String>
  var done: () -> Void = {}
  @State private var name = ""
  var body: some View {
    NavigationStack {
      Form {
        if !store.categories.isEmpty {
          Section(store.t("已有分类", "Categories")) {
            ForEach(store.categories, id: \.self) { category in
              Button { apply(category) } label: { Label(category, systemImage: "folder") }
            }
          }
        }
        Section {
          TextField(store.t("新分类名称", "New category name"), text: $name)
            .accessibilityIdentifier("category.name")
          Button(store.t("移动到新分类", "Move to new category")) { apply(name) }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Section {
          Button(store.t("移出分类", "Remove from category")) { apply("") }
        } footer: {
          Text(store.t("只移动笔记；共享库中的只读笔记会保持不变。", "Only notes move; read-only shared notes stay unchanged."))
        }
      }
      .navigationTitle(store.t("移动到分类", "Move to category")).navigationBarTitleDisplayMode(.inline)
      .disabled(store.busy)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(store.t("取消", "Cancel")) { dismiss() } }
      }
    }
    .presentationDetents([.medium, .large])
  }
  private func apply(_ category: String) {
    Task {
      await store.move(ids, to: category)
      done()
      dismiss()
    }
  }
}

/// Multi-select for entry lists: Edit mode on the list, a selection title, Select All and a
/// bottom toolbar with Favorite, Move to category (notes) and Move to Trash. Actions only
/// change entries this device may edit.
struct EntrySelection: ViewModifier {
  @EnvironmentObject private var store: MobileVaultStore
  @Binding var selecting: Bool
  @Binding var selection: Set<String>
  let visible: [VaultItem]
  @State private var moving = false
  @State private var trashing = false
  private var editable: Set<String> {
    Set(visible.filter { selection.contains($0.id) && store.canEdit($0) && !$0.isDeleted }.map(\.id))
  }
  private var hasNotes: Bool {
    visible.contains { editable.contains($0.id) && $0.type == "secureNote" }
  }
  func body(content: Content) -> some View {
    content
      .environment(\.editMode, .constant(selecting ? .active : .inactive))
      .toolbar {
        if selecting {
          ToolbarItem(placement: .navigationBarLeading) {
            Button(store.t("完成", "Done")) { finish() }.accessibilityIdentifier("selection.done")
          }
          ToolbarItem(placement: .principal) {
            Text(store.t("已选择 \(selection.count) 项", "\(selection.count) selected")).font(.headline)
              .accessibilityIdentifier("selection.count")
          }
          ToolbarItem(placement: .navigationBarTrailing) {
            let all = !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) }
            Button(all ? store.t("取消全选", "Deselect All") : store.t("全选", "Select All")) {
              selection = all ? [] : Set(visible.map(\.id))
            }
          }
          ToolbarItemGroup(placement: .bottomBar) {
            Button { Task { if await store.favorite(editable) > 0 { finish() } } } label: {
              Label(store.t("收藏", "Favorite"), systemImage: "star")
            }.disabled(editable.isEmpty || store.busy).accessibilityIdentifier("selection.favorite")
            Spacer()
            if visible.contains(where: { $0.type == "secureNote" }) {
              Button { moving = true } label: {
                Label(store.t("移动到分类", "Move to category"), systemImage: "folder")
              }.disabled(!hasNotes || store.busy).accessibilityIdentifier("selection.move")
              Spacer()
            }
            Button(role: .destructive) { trashing = true } label: {
              Label(store.t("移到回收站", "Move to Trash"), systemImage: "trash")
            }.tint(.red).disabled(editable.isEmpty || store.busy).accessibilityIdentifier("selection.trash")
          }
        }
      }
      .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
      .onChange(of: visible.map(\.id)) { ids in selection.formIntersection(ids) }
      .sheet(isPresented: $moving) { MoveToCategorySheet(ids: editable, done: finish) }
      .confirmationDialog(
        store.t("将 \(editable.count) 项移到回收站？", "Move \(editable.count) items to Trash?"),
        isPresented: $trashing, titleVisibility: .visible
      ) {
        Button(store.t("移到回收站", "Move to Trash"), role: .destructive) {
          Task { if await store.trash(editable) > 0 { finish() } }
        }
        Button(store.t("取消", "Cancel"), role: .cancel) {}
      } message: {
        let skipped = selection.count - editable.count
        Text(skipped > 0
          ? store.t("\(skipped) 项为只读，不会移动。可在回收站中恢复。", "\(skipped) read-only items stay. You can restore from Trash.")
          : store.t("可在回收站中恢复。", "You can restore them from Trash."))
      }
  }
  private func finish() {
    selecting = false
    selection = []
  }
}
