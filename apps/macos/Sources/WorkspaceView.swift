import SwiftUI

struct WorkspaceView: View {
  @EnvironmentObject private var store: AppStore
  var body: some View {
    HSplitView {
      SidebarView().frame(minWidth: 210, idealWidth: 268, maxWidth: 268)
      RecordListView().frame(minWidth: 280, idealWidth: 410, maxWidth: 410)
      DetailContainer().frame(minWidth: 500, maxWidth: .infinity)
    }.background(Palette.surface)
  }
}

private struct SidebarView: View {
  @EnvironmentObject private var store: AppStore
  @State private var toolsExpanded = false
  @State private var categoryAction: NoteCategoryAction?
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Brand().padding(.horizontal, 22).padding(.top, 48).padding(.bottom, 26)
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(store.t("笔记", "NOTES")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
              categoryAction = .create
            } label: {
              Image(systemName: "plus")
            }
            .help(store.t("添加分类", "Add category"))
            .accessibilityLabel(store.t("添加分类", "Add category"))
            .accessibilityIdentifier("sidebar.category.add")
            Button {
              if let category = store.category { categoryAction = .remove(category) }
            } label: {
              Image(systemName: "minus")
            }
            .disabled(store.destination != .notes || store.category == nil)
            .help(store.t("删除当前分类，保留笔记", "Delete selected category, keep notes"))
            .accessibilityLabel(store.t("删除当前分类", "Delete selected category"))
            .accessibilityIdentifier("sidebar.category.remove")
          }.buttonStyle(VaultButtonStyle(.plain)).padding(.horizontal, 16).padding(.bottom, 6)
          SidebarRow(
            title: Destination.notes.title(chinese: store.chinese), symbol: "doc.text",
            count: count("secureNote"),
            selected: store.destination == .notes && store.category == nil
          ) { store.navigate(.notes) }
          ForEach(store.categories, id: \.self) { category in
            SidebarRow(
              title: category, symbol: "folder",
              count: store.items.filter {
                !$0.isDeleted && $0.type == "secureNote" && $0.category == category
              }.count,
              selected: store.destination == .notes && store.category == category
            ) { store.navigate(.notes, category: category) }
            .contextMenu {
              Button(store.t("删除分类…", "Delete category…"), role: .destructive) {
                categoryAction = .remove(category)
              }.buttonStyle(.automatic)
            }
          }
          Divider().padding(.vertical, 16).padding(.horizontal, 12)
          ForEach([Destination.passwords, .codes, .wallets]) { destination in
            SidebarRow(
              title: destination.title(chinese: store.chinese), symbol: destination.symbol,
              count: count(destination.itemType!), selected: store.destination == destination
            ) { store.navigate(destination) }
          }
        }.padding(.horizontal, 12)
      }
      Divider().padding(.horizontal, 20).padding(.top, 10)
      VStack(spacing: 10) {
        VStack(spacing: 0) {
          Button {
            withAnimation(.easeInOut(duration: 0.15)) { toolsExpanded.toggle() }
          } label: {
            HStack {
              Label(store.t("工具", "Tools"), systemImage: "wrench.and.screwdriver")
              Spacer()
              Image(systemName: toolsExpanded ? "chevron.down" : "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
            }
            .font(.system(size: 15)).padding(.horizontal, 13).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }.buttonStyle(VaultButtonStyle(.row))
            .accessibilityIdentifier("sidebar.tools.toggle")
            .accessibilityLabel(store.t("工具", "Tools"))
            .accessibilityValue(
              toolsExpanded ? store.t("已展开", "Expanded") : store.t("已收起", "Collapsed"))
          if toolsExpanded {
            Divider().padding(.horizontal, 12)
            VStack(spacing: 2) {
              ForEach([Destination.generator, .audit, .backups, .sharing, .trash]) { destination in
                SidebarRow(
                  title: destination.title(chinese: store.chinese), symbol: destination.symbol,
                  selected: store.destination == destination, compact: true
                ) { store.navigate(destination) }
              }
            }.padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 8)
          }
        }
        .background(
          toolsExpanded ? Palette.surface.opacity(0.55) : .clear,
          in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 12).strokeBorder(
            toolsExpanded ? Palette.divider : .clear, lineWidth: 1
          )
          .allowsHitTesting(false).accessibilityHidden(true)
        }
        SidebarRow(
          title: store.t("设置", "Settings"), symbol: "gearshape",
          selected: store.destination == .settings
        ) { store.navigate(.settings) }
      }.padding(12).padding(.bottom, 14)
    }.background(Palette.sidebar)
      .sheet(item: $categoryAction) { NoteCategorySheet(action: $0) }
  }
  private func count(_ type: String) -> Int {
    store.items.filter { !$0.isDeleted && $0.type == type }.count
  }
}

private struct SidebarRow: View {
  let title: String
  let symbol: String
  var count: Int? = nil
  let selected: Bool
  var compact = false
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 16) {
        Image(systemName: symbol).font(.system(size: compact ? 17 : 19, weight: .regular)).frame(
          width: 25)
        Text(title).font(.system(size: compact ? 14 : 15, weight: selected ? .semibold : .regular))
          .lineLimit(1)
        Spacer(minLength: 0)
        if let count { Text("\(count)").font(.caption).monospacedDigit() }
      }.foregroundStyle(selected ? Palette.accent : .primary).padding(.horizontal, 13).padding(
        .vertical, compact ? 10 : 13
      )
      .background(selected ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
      .contentShape(Rectangle())
    }.buttonStyle(VaultButtonStyle(.row))
  }
}

private struct RecordListView: View {
  @EnvironmentObject private var store: AppStore
  @FocusState private var searchFocused: Bool
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(store.category ?? store.destination.title(chinese: store.chinese)).font(
          .system(size: 24, weight: .bold))
        Spacer()
        if store.destination.itemType != nil {
          Button {
            Task { await store.newItem() }
          } label: {
            Label(store.t("新建", "New"), systemImage: "plus")
          }
          .buttonStyle(VaultButtonStyle(.primary)).tint(Palette.blue).controlSize(.large)
        }
      }.padding(.horizontal, 20).padding(.top, 48).padding(.bottom, 20)
      if store.destination.itemType != nil || store.destination == .trash {
        HStack {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField(store.t("搜索", "Search"), text: $store.search).textFieldStyle(.plain).focused(
            $searchFocused)
          if !store.search.isEmpty {
            Button {
              store.search = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
            }.buttonStyle(VaultButtonStyle(.plain)).accessibilityLabel(
              store.t("清除搜索", "Clear search"))
          } else {
            Text("⌘K").foregroundStyle(.tertiary)
          }
        }.padding(12).background(
          Palette.sidebar.opacity(0.7), in: RoundedRectangle(cornerRadius: 9)
        ).padding(.horizontal, 20).padding(.bottom, 16)
        if store.visibleItems.isEmpty {
          VStack {
            EmptyState(
              symbol: store.destination == .trash ? "trash" : "doc.text.magnifyingglass",
              title: store.search.isEmpty
                ? (store.destination == .trash
                  ? store.t("回收站为空", "Trash is empty") : store.t("这里还没有资料", "No entries here yet"))
                : store.t("没有匹配的资料", "No matching entries"),
              message: store.search.isEmpty
                ? (store.destination == .trash
                  ? store.t("删除的条目会出现在这里。", "Deleted entries appear here.")
                  : store.t("新建一条记录，开始整理。", "Create an entry to get started."))
                : store.t("换一个关键词，或清除搜索条件。", "Try another keyword or clear the search."),
              fillsSpace: false)
            if !store.search.isEmpty {
              Button(store.t("清除搜索", "Clear search")) { store.search = "" }.padding(.bottom, 32)
            } else if store.destination.itemType != nil {
              Button(store.t("新建条目", "New entry")) { Task { await store.newItem() } }.buttonStyle(
                VaultButtonStyle(.primary)
              ).tint(Palette.blue).padding(.bottom, 32)
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(store.visibleItems) { item in
                RecordRow(item: item, selected: store.selectedID == item.id) {
                  store.selectedID = item.id
                }
              }
            }
          }
        }
      } else if store.destination == .settings {
        SettingsNavigation()
        Spacer()
      } else {
        Text(toolDescription).font(.body).foregroundStyle(.secondary).padding(20)
        Spacer()
      }
    }.background(Palette.surface)
      .onChange(of: store.search) { _ in
        if !store.visibleItems.contains(where: { $0.id == store.selectedID }) {
          store.selectedID = store.visibleItems.first?.id
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .focusVaultSearch)) { _ in
        searchFocused = true
      }
  }
  private var toolDescription: String {
    switch store.destination {
    case .generator:
      return store.t("生成适合不同账号的随机密码。", "Generate random passwords for your accounts.")
    case .backups:
      return store.t("加密备份、导入旧资料库，或连接 WebDAV。", "Encrypted backups, legacy import, and WebDAV.")
    case .audit: return store.t("查看需要改进的弱密码与重复密码。", "Review weak and reused passwords.")
    default: return store.t("管理资料库中的相关信息。", "Manage the information in your vault.")
    }
  }
}

private struct RecordRow: View {
  @EnvironmentObject private var store: AppStore
  let item: VaultItem
  let selected: Bool
  let action: () -> Void
  @State private var confirmTrash = false
  @State private var confirmDelete = false
  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(item.title.isEmpty ? store.t("未命名", "Untitled") : item.title).font(
            .system(size: 16, weight: .semibold)
          ).lineLimit(1)
          Spacer()
          if item.isPinned {
            Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
          }
          if item.isFavorite {
            Image(systemName: "star.fill").font(.caption).foregroundStyle(Palette.accent)
          }
        }
        Text(
          item.type == "secureNote"
            ? (NoteMarkdownProjection(item.note, markdown: item.string("noteFormat") == "markdown").text.components(separatedBy: "\n").first ?? "") : item.username
        )
        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
        if !item.category.isEmpty {
          Label(item.category, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 21).padding(
        .vertical, 18
      )
      .background(selected ? Palette.selection : .clear).contentShape(Rectangle())
    }.buttonStyle(VaultButtonStyle(.row))
      .contextMenu {
        Group {
          if item.isDeleted {
            Button { Task { await store.trash(item) } } label: {
              Label(store.t("恢复", "Restore"), systemImage: "arrow.uturn.backward")
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: {
              Label(store.t("永久删除…", "Delete permanently…"), systemImage: "trash")
            }
          } else {
            Button(item.isFavorite ? store.t("取消收藏", "Unfavorite") : store.t("收藏", "Favorite")) {
              Task { await store.toggleFavorite(item.id) }
            }
            Button(item.isPinned ? store.t("取消置顶", "Unpin") : store.t("置顶", "Pin")) {
              Task { await store.togglePin(item.id) }
            }
            Divider()
            Button(role: .destructive) { confirmTrash = true } label: {
              Label(store.t("删除…", "Delete…"), systemImage: "trash")
            }
          }
        }.buttonStyle(.automatic)
      }
      .confirmationDialog(
        store.t("移到回收站？", "Move to Trash?"), isPresented: $confirmTrash,
        titleVisibility: .visible
      ) {
        Button(store.t("移到回收站", "Move to Trash"), role: .destructive) {
          Task { await store.trash(item) }
        }
        Button(store.t("取消", "Cancel"), role: .cancel) {}
      } message: {
        Text(store.t("「\(item.title)」将移到回收站，之后可以恢复。", "“\(item.title)” will move to Trash and can be restored later."))
      }
      .confirmationDialog(
        store.t("永久删除此条目？", "Permanently delete this entry?"), isPresented: $confirmDelete,
        titleVisibility: .visible
      ) {
        Button(store.t("永久删除", "Delete permanently"), role: .destructive) {
          Task { await store.removePermanently(item) }
        }
        Button(store.t("取消", "Cancel"), role: .cancel) {}
      } message: {
        Text(store.t("「\(item.title)」将被永久删除，此操作无法撤销。", "“\(item.title)” will be permanently deleted. This cannot be undone."))
      }
    Divider().padding(.horizontal, 20)
  }
}

private struct DetailContainer: View {
  @EnvironmentObject private var store: AppStore
  var body: some View {
    Group {
      switch store.destination {
      case .settings: SecuritySettingsView()
      case .generator: GeneratorView()
      case .audit: PasswordAuditView()
      case .backups: BackupView()
      case .sharing: SharingView(service: store.localSync)
      default:
        if let item = store.selected {
          EntryDetailView(item: item).id(item.id)
        } else {
          EmptyState(
            symbol: "doc.text", title: store.t("选择一条记录", "Select an entry"),
            message: store.t(
              "你的笔记和重要信息会显示在这里。", "Your notes and important information appear here."))
        }
      }
    }.background(Palette.surface)
  }
}
