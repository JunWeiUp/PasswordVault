import SwiftUI

/// Note ordering for the Notes tab. Raw values are stored per device in UserDefaults.
enum NoteSort: String, CaseIterable, Identifiable {
  case modified, title, created
  var id: String { rawValue }
  static let defaultsKey = "notesSort"
  func label(_ t: (String, String) -> String) -> String {
    switch self {
    case .modified: return t("最近修改", "Last modified")
    case .title: return t("名称", "Name")
    case .created: return t("创建时间", "Date created")
    }
  }
  /// Pinned notes come first, then the chosen order. Notes without a creation date fall back
  /// to their modification date.
  func sorted(_ notes: [VaultItem]) -> [VaultItem] {
    notes.sorted { a, b in
      if a.isPinned != b.isPinned { return a.isPinned }
      switch self {
      case .modified:
        return Self.date(a, "updatedAt") > Self.date(b, "updatedAt")
      case .created:
        let left = Self.date(a, "createdAt", fallback: "updatedAt")
        let right = Self.date(b, "createdAt", fallback: "updatedAt")
        return left > right
      case .title:
        let order = a.title.localizedStandardCompare(b.title)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
      }
    }
  }
  static func date(_ item: VaultItem, _ key: String, fallback: String? = nil) -> Date {
    if let value = parse(item.string(key)) { return value }
    if let fallback, let value = parse(item.string(fallback)) { return value }
    return .distantPast
  }
  static func parse(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: value) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value)
  }
}

/// Notes tab: search, category chips, grid or list layout and sort options. Opening a note
/// shows a read-only page; editing uses the existing rich editor.
struct MobileNotesView: View {
  @EnvironmentObject private var store: MobileVaultStore
  @Environment(\.dynamicTypeSize) private var typeSize
  @AppStorage("notesLayout") private var layout = "grid"
  @AppStorage(NoteSort.defaultsKey) private var sortValue = NoteSort.modified.rawValue
  @State private var search = ""
  @State private var category = ""
  @State private var editor: VaultItem?
  @State private var deleting: VaultItem?
  @State private var selecting = false
  @State private var selection = Set<String>()
  @State private var history: VaultItem?
  @State private var moving: VaultItem?

  private var sort: NoteSort { NoteSort(rawValue: sortValue) ?? .modified }
  private var grid: Bool { layout != "list" }
  private var notes: [VaultItem] {
    sort.sorted(store.items.filter {
      !$0.isDeleted && $0.type == "secureNote"
        && (category.isEmpty || $0.category == category)
        && (search.isEmpty
          || [$0.title, $0.note, $0.category].joined(separator: " ").localizedCaseInsensitiveContains(search))
    })
  }

  var body: some View {
    Group {
      // Selecting always uses the list layout so rows can show selection marks.
      if grid && !selecting {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            RelayOfflineBanner(relay: store.relay, t: store.t).padding(.horizontal)
            header.padding(.horizontal)
            if notes.isEmpty { empty.padding(.horizontal) }
            LazyVGrid(
              columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                count: typeSize.isAccessibilitySize ? 1 : 2),
              spacing: 12
            ) {
              ForEach(notes) { note in
                NavigationLink { MobileNoteReader(id: note.id) } label: { card(note) }
                  .buttonStyle(.plain)
                  .contextMenu { menu(note) }
              }
            }.padding(.horizontal)
          }.padding(.vertical, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
      } else {
        List(selection: $selection) {
          RelayOfflineBanner(relay: store.relay, t: store.t)
          header
          if notes.isEmpty { empty }
          ForEach(notes) { note in
            NavigationLink { MobileNoteReader(id: note.id) } label: { row(note) }
              .contextMenu { menu(note) }
              .swipeActions {
                Button(role: .destructive) { deleting = note } label: {
                  Label(store.t("删除", "Delete"), systemImage: "trash")
                }.disabled(!store.canEdit(note))
              }
          }
        }
      }
    }
    .navigationTitle(Destination.notes.title(chinese: store.chinese))
    .searchable(text: $search, prompt: store.t("搜索", "Search"))
    .modifier(EntrySelection(selecting: $selecting, selection: $selection, visible: notes))
    .toolbar {
      if !selecting {
      ToolbarItem(placement: .navigationBarLeading) {
        Button(action: store.lock) { Image(systemName: "lock") }.accessibilityLabel(store.t("锁定", "Lock"))
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(store.t("选择", "Select")) { selecting = true }
          .disabled(notes.isEmpty || !store.canWriteLibrary)
          .accessibilityIdentifier("selection.start")
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Menu {
          Picker(store.t("布局", "Layout"), selection: $layout) {
            Label(store.t("网格", "Grid"), systemImage: "square.grid.2x2").tag("grid")
            Label(store.t("列表", "List"), systemImage: "list.bullet").tag("list")
          }
          Picker(store.t("排序方式", "Sort by"), selection: $sortValue) {
            ForEach(NoteSort.allCases) { Text($0.label(store.t)).tag($0.rawValue) }
          }
        } label: {
          Image(systemName: grid ? "square.grid.2x2" : "list.bullet")
        }.accessibilityLabel(store.t("显示选项", "View options"))
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Menu {
          Button(store.t("新建条目", "New entry")) { editor = .blank(type: "secureNote", title: "") }
        } label: { Image(systemName: "plus") }
          .accessibilityLabel(store.t("新建", "Add")).disabled(!store.canWriteLibrary)
      }
      }
    }
    .sheet(item: $editor) { MobileRichNoteEditor(item: $0) }
    .sheet(item: $history) { EntryHistorySheet(id: $0.id) }
    .sheet(item: $moving) { MoveToCategorySheet(ids: [$0.id]) }
    .confirmationDialog(
      store.t("移到回收站？", "Move to Trash?"),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      if let target = deleting {
        Button(store.t("移到回收站", "Move to Trash"), role: .destructive) { Task { await store.trash(target) } }
      }
      Button(store.t("取消", "Cancel"), role: .cancel) {}
    } message: { Text(deleting?.title ?? "") }
  }

  @ViewBuilder private var header: some View {
    let family = !(store.settings["activePeerLibrary"]?.string ?? "").isEmpty
    Label(family ? store.t("家庭库：", "Family: ") + (store.settings["_peerLibraryName"]?.string ?? store.t("家庭资料库", "Family library")) : store.t("个人资料库", "Personal library"), systemImage: family ? "person.2" : "person.crop.circle")
      .font(.caption.weight(.medium)).foregroundStyle(.secondary).accessibilityIdentifier("current-library")
    if !store.categories.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          chip(store.t("全部", "All"), value: "")
          ForEach(store.categories, id: \.self) { chip($0, value: $0) }
        }
      }
    }
  }

  private func chip(_ title: String, value: String) -> some View {
    Button { category = value } label: {
      Text(title).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
        .background(category == value ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemFill), in: Capsule())
        .foregroundStyle(category == value ? Color.accentColor : Color.primary)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(category == value ? .isSelected : [])
  }

  private var empty: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(search.isEmpty ? store.t("这里还没有笔记", "No notes yet") : store.t("没有匹配的笔记", "No matching notes"))
        .font(.headline)
      Text(store.t("点击右上角加号开始，或调整搜索条件。", "Use Add to get started, or adjust your search."))
        .foregroundStyle(.secondary)
    }.padding(.vertical, 24)
  }

  private func preview(_ note: VaultItem) -> String {
    note.note.split(whereSeparator: \.isNewline).prefix(6).joined(separator: "\n")
  }

  private func title(_ note: VaultItem) -> String {
    note.title.isEmpty ? store.t("未命名", "Untitled") : note.title
  }

  private func card(_ note: VaultItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Text(title(note)).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
        Spacer(minLength: 4)
        if note.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
      }
      if !note.note.isEmpty {
        Text(preview(note)).font(.subheadline).foregroundStyle(.secondary).lineLimit(5)
          .multilineTextAlignment(.leading)
      }
      Text(MobileNoteReader.dateText(note, store: store)).font(.caption2).foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private func row(_ note: VaultItem) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title(note)).font(.headline).lineLimit(1)
        if note.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
        if note.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
      }
      Text(note.note.components(separatedBy: "\n").first ?? "").lineLimit(2).foregroundStyle(.secondary)
    }.padding(.vertical, 6)
  }

  private func menu(_ note: VaultItem) -> some View {
    EntryMenuItems(item: note, edit: { editor = note }, history: { history = note },
      move: { moving = note }, trash: { deleting = note })
  }
}

/// Read-only note page. Rich notes show their text; images and attachments open in the editor.
struct MobileNoteReader: View {
  @EnvironmentObject private var store: MobileVaultStore
  @Environment(\.dismiss) private var dismiss
  let id: String
  @State private var editor: VaultItem?
  @State private var deleting = false
  private var item: VaultItem? { store.items.first { $0.id == id } }

  static func dateText(_ item: VaultItem, store: MobileVaultStore) -> String {
    let date = NoteSort.date(item, "updatedAt")
    guard date != .distantPast else { return "" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: store.chinese ? "zh_CN" : "en_US")
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  var body: some View {
    Group {
      if let item {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            Text(item.title.isEmpty ? store.t("未命名", "Untitled") : item.title)
              .font(.title.bold()).accessibilityIdentifier("note.reader.title")
            Text([Self.dateText(item, store: store), item.category].filter { !$0.isEmpty }.joined(separator: " · "))
              .font(.footnote).foregroundStyle(.secondary)
            Divider()
            if item.note.isEmpty {
              Text(store.t("这篇笔记还没有内容。", "This note is empty.")).foregroundStyle(.secondary)
            } else if item.isRichNote {
              Text(item.note).textSelection(.enabled)
            } else {
              MobileMarkdown(source: item.note).textSelection(.enabled)
            }
            if item.isRichNote {
              Text(store.t("图片和附件请在编辑器中查看。", "Open the editor to see images and attachments."))
                .font(.caption).foregroundStyle(.secondary)
            }
            if !store.canEdit(item) {
              Text(store.t("此共享条目为只读。", "This shared entry is read-only.")).font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink(store.t("版本历史", "Version history")) { MobileHistoryView(id: id) }
              .font(.subheadline).padding(.top, 8)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
        }
        .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if store.canEdit(item) {
            ToolbarItem(placement: .navigationBarTrailing) {
              Menu {
                Button(item.isPinned ? store.t("取消置顶", "Unpin") : store.t("置顶", "Pin")) {
                  Task { await store.toggle(id, field: "isPinned") }
                }
                Button(item.isFavorite ? store.t("取消收藏", "Unfavorite") : store.t("收藏", "Favorite")) {
                  Task { await store.toggle(id, field: "isFavorite") }
                }
                Button(store.t("移到回收站…", "Move to Trash…"), role: .destructive) { deleting = true }
              } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(store.t("更多", "More"))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
              Button(store.t("编辑", "Edit")) { editor = item }
            }
          }
        }
        .confirmationDialog(store.t("移到回收站？", "Move to Trash?"), isPresented: $deleting, titleVisibility: .visible) {
          Button(store.t("移到回收站", "Move to Trash"), role: .destructive) {
            Task { if await store.trash(item) { dismiss() } }
          }
        } message: { Text(item.title) }
      } else {
        Text(store.t("此条目已移除", "Entry removed"))
      }
    }
    .sheet(item: $editor) { MobileRichNoteEditor(item: $0) }
  }
}
