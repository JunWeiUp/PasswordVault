import SwiftUI

struct MobileEntryList: View {
  @EnvironmentObject private var store: MobileVaultStore
  let destination: Destination
  @State private var search = ""
  @State private var category = ""
  @State private var editor: VaultItem?
  @State private var deleting: VaultItem?
  private var entries: [VaultItem] {
    store.items.filter {
      (destination == .trash ? $0.isDeleted : !$0.isDeleted && $0.type == destination.itemType)
        && (category.isEmpty || $0.category == category)
        && (search.isEmpty
          || [$0.title, $0.username, $0.note, $0.category].joined(separator: " ")
            .localizedCaseInsensitiveContains(search))
    }.sorted { a, b in
      if a.isPinned != b.isPinned { return a.isPinned }
      if a.isFavorite != b.isFavorite { return a.isFavorite }
      return a.string("updatedAt") > b.string("updatedAt")
    }
  }
  var body: some View {
    List {
      if destination == .notes && !store.categories.isEmpty {
        Picker(store.t("分类", "Category"), selection: $category) {
          Text(store.t("全部", "All")).tag("")
          ForEach(store.categories, id: \.self) { Text($0).tag($0) }
        }
      }
      if entries.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text(
            search.isEmpty
              ? store.t("这里还没有资料", "No entries yet") : store.t("没有匹配的资料", "No matching entries")
          ).font(.headline)
          Text(store.t("点击右上角加号开始，或调整搜索条件。", "Use Add to get started, or adjust your search."))
            .foregroundStyle(.secondary)
        }.padding(.vertical, 24)
      }
      ForEach(entries) { item in
        NavigationLink {
          MobileEntryDetail(id: item.id)
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(item.title.isEmpty ? store.t("未命名", "Untitled") : item.title).font(.headline)
                .lineLimit(1)
              if item.isPinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
              }
              if item.isFavorite {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
              }
            }
            Text(
              item.type == "secureNote"
                ? item.note.components(separatedBy: "\n").first ?? "" : item.username
            ).lineLimit(2).foregroundStyle(.secondary)
          }.padding(.vertical, 6)
        }
        .swipeActions {
          Button(role: .destructive) {
            deleting = item
          } label: {
            Label(store.t("删除", "Delete"), systemImage: "trash")
          }.disabled(
            !store.canEdit(item) || (item.isDeleted && !item.string("sharedVaultId").isEmpty))
          if item.isDeleted && store.canEdit(item) {
            Button(store.t("恢复", "Restore")) { Task { await store.trash(item) } }.tint(.blue)
          }
        }
        .contextMenu {
          if !item.isDeleted && store.canEdit(item) {
            Button(item.isFavorite ? store.t("取消收藏", "Unfavorite") : store.t("收藏", "Favorite")) {
              Task { await store.toggle(item.id, field: "isFavorite") }
            }
            Button(item.isPinned ? store.t("取消置顶", "Unpin") : store.t("置顶", "Pin")) {
              Task { await store.toggle(item.id, field: "isPinned") }
            }
          } else if item.isDeleted && store.canEdit(item) {
            Button(store.t("恢复", "Restore")) { Task { await store.trash(item) } }
          }
          Button(store.t("删除…", "Delete…"), role: .destructive) { deleting = item }.disabled(
            !store.canEdit(item))
        }
      }
    }
    .navigationTitle(destination.title(chinese: store.chinese))
    .searchable(text: $search, prompt: store.t("搜索", "Search"))
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button(action: store.lock) { Image(systemName: "lock") }.accessibilityLabel(
          store.t("锁定", "Lock"))
      }
      if let kind = destination.itemType {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            editor = .blank(type: kind, title: "")
          } label: {
            Image(systemName: "plus")
          }.accessibilityLabel(store.t("新建", "Add"))
        }
      }
    }
    .sheet(item: $editor) { MobileEntryEditor(item: $0) }
    .confirmationDialog(
      deleting?.isDeleted == true
        ? store.t("永久删除？", "Delete permanently?") : store.t("移到回收站？", "Move to Trash?"),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      if let target = deleting {
        Button(
          target.isDeleted
            ? store.t("永久删除", "Delete permanently") : store.t("移到回收站", "Move to Trash"),
          role: .destructive
        ) {
          Task {
            if target.isDeleted { await store.remove(target) } else { await store.trash(target) }
          }
        }
      }
      Button(store.t("取消", "Cancel"), role: .cancel) {}
    } message: {
      Text(deleting?.title ?? "")
    }
  }
}
