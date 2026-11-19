import SwiftUI

struct MobileEntryList: View {
  @EnvironmentObject private var store: MobileVaultStore
  let destination: Destination
  @State private var search = ""
  @State private var category = ""
  @State private var editor: VaultItem?
  @State private var deleting: VaultItem?
  @State private var walletKind = ""
  @State private var emptyingTrash = false
  @State private var selecting = false
  @State private var selection = Set<String>()
  @State private var history: VaultItem?
  @State private var moving: VaultItem?
  @State private var addingCode = false
  @State private var openedPassword: VaultItem?
  private static func tileColor(_ title: String) -> Color {
    let palette: [Color] = [
      Color(red: 0.196, green: 0.396, blue: 0.859),
      Color(red: 0.129, green: 0.478, blue: 0.322),
      Color(red: 0.647, green: 0.361, blue: 0.047),
      Color(red: 0.478, green: 0.353, blue: 0.961),
      Color(red: 0.141, green: 0.161, blue: 0.184),
      Color(red: 0.769, green: 0.200, blue: 0.200),
    ]
    let sum = title.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
    return palette[abs(sum) % palette.count]
  }
  @ViewBuilder private func rowContent(_ item: VaultItem) -> some View {
    HStack(spacing: 12) {
      if item.type == "password" {
        let letter = String((item.title.trimmingCharacters(in: .whitespaces).first ?? "?")).uppercased()
        Text(letter)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 34, height: 34)
          .background(Self.tileColor(item.title), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 5) {
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
        ).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
    }.padding(.vertical, 4).contentShape(Rectangle())
  }
  private var entries: [VaultItem] {
    store.items.filter {
      (destination == .trash ? $0.isDeleted : !$0.isDeleted && destination.listedTypes.contains($0.type))
        && (walletKind.isEmpty || $0.type == walletKind)
        && (destination != .favorites || $0.isFavorite)
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
    List(selection: $selection) {
      RelayOfflineBanner(relay: store.relay, t: store.t)
      let family = !(store.settings["activePeerLibrary"]?.string ?? "").isEmpty
      Label(family ? store.t("家庭库：", "Family: ") + (store.settings["_peerLibraryName"]?.string ?? store.t("家庭资料库", "Family library")) : store.t("个人资料库", "Personal library"), systemImage: family ? "person.2" : "person.crop.circle")
        .font(.caption.weight(.medium)).foregroundStyle(.secondary).accessibilityIdentifier("current-library")
      if destination == .wallets {
        Picker(store.t("类型", "Type"), selection: $walletKind) {
          Text(store.t("全部", "All")).tag("")
          Text(store.t("银行卡", "Cards")).tag("creditCard")
          Text(store.t("证件", "IDs")).tag("identity")
          Text(store.t("加密货币", "Crypto")).tag("crypto")
        }.pickerStyle(.segmented).accessibilityIdentifier("wallet-kind")
      }
      if destination == .notes && !store.categories.isEmpty {
        Picker(store.t("分类", "Category"), selection: $category) {
          Text(store.t("全部", "All")).tag("")
          ForEach(store.categories, id: \.self) { Text($0).tag($0) }
        }
      }
      if destination == .trash {
        Label {
          Text(store.t(
            "项目会一直保留在回收站，直到你永久删除或清空。恢复后回到原位置并保留全部字段与历史。",
            "Items stay in Trash until you delete them permanently or empty Trash. Restored items return to their original place with all fields and history."))
            .font(.footnote).foregroundStyle(.secondary)
        } icon: { Image(systemName: "info.circle").foregroundStyle(.blue) }
          .accessibilityIdentifier("trash.retention")
        if store.items.contains(where: \.isDeleted) {
          Button(store.t("清空回收站…", "Empty Trash…"), role: .destructive) { emptyingTrash = true }
            .disabled(store.busy)
        }
      }
      if entries.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text(
            !search.isEmpty
              ? store.t("没有匹配的资料", "No matching entries")
              : destination == .trash ? store.t("回收站是空的", "Trash is empty")
              : store.t("这里还没有资料", "No entries yet")
          ).font(.headline)
          Text(destination == .trash && search.isEmpty
            ? store.t("移到回收站的项目会显示在这里。", "Items you move to Trash appear here.")
            : store.t("点击右上角加号开始，或调整搜索条件。", "Use Add to get started, or adjust your search."))
            .foregroundStyle(.secondary)
        }.padding(.vertical, 24)
      }
      ForEach(entries) { item in
        Group {
        if destination == .codes {
          MobileCodeRow(item: item)
        } else if item.type == "password" && !item.isDeleted && !selecting {
          // Avoid a trailing disclosure chevron colliding with the one-tap copy button.
          HStack(spacing: 8) {
            Button { openedPassword = item } label: { rowContent(item) }
              .buttonStyle(.plain)
            Button { store.copy(item.password) } label: {
              Image(systemName: "doc.on.doc")
                .font(.subheadline)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.borderless)
            .disabled(item.password.isEmpty)
            .accessibilityLabel(store.t("复制密码", "Copy password"))
            .accessibilityValue(item.title)
            .accessibilityIdentifier("row.copyPassword")
          }
        } else {
          NavigationLink {
            if item.type == "secureNote" && !item.isDeleted { MobileNoteReader(id: item.id) } else { MobileEntryDetail(id: item.id) }
          } label: {
            rowContent(item)
          }
        }
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
          EntryMenuItems(item: item, edit: { editor = item }, history: { history = item },
            move: { moving = item }, trash: { deleting = item })
        }
      }
    }
    .navigationTitle(destination.title(chinese: store.chinese))
    .navigationDestination(isPresented: Binding(get: { openedPassword != nil }, set: { if !$0 { openedPassword = nil } })) {
      if let target = openedPassword { MobileEntryDetail(id: target.id) }
    }
    .searchable(text: $search, prompt: store.t("搜索", "Search"))
    .modifier(EntrySelection(selecting: $selecting, selection: $selection, visible: entries))
    .toolbar {
      if !selecting {
      ToolbarItem(placement: .navigationBarLeading) {
        Button(action: store.lock) { Image(systemName: "lock") }.accessibilityLabel(
          store.t("锁定", "Lock"))
      }
      if destination != .trash {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(store.t("选择", "Select")) { selecting = true }
            .disabled(entries.isEmpty || !store.canWriteLibrary)
            .accessibilityIdentifier("selection.start")
        }
      }
      if destination == .codes {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button { addingCode = true } label: { Image(systemName: "plus") }
            .accessibilityLabel(store.t("新建", "Add")).disabled(!store.canWriteLibrary)
        }
      } else if let kind = destination.itemType {
        ToolbarItem(placement: .navigationBarTrailing) {
          Menu {
            if destination == .wallets {
              Button(store.t("银行卡", "Payment card")) { editor = .blank(type: "creditCard", title: "") }
              Button(store.t("身份证件", "Identity document")) { editor = .blank(type: "identity", title: "") }
              Button(store.t("加密货币钱包", "Crypto wallet")) { editor = .blank(type: kind, title: "") }
            } else {
              Button(store.t("新建条目", "New entry")) { editor = .blank(type: kind, title: "") }
            }
          } label: { Image(systemName: "plus") }.accessibilityLabel(store.t("新建", "Add")).disabled(!store.canWriteLibrary)
        }
      }
      }
    }
    .sheet(item: $editor) { item in
      if item.type == "secureNote" { MobileRichNoteEditor(item: item) } else { MobileEntryEditor(item: item) }
    }
    .sheet(item: $history) { EntryHistorySheet(id: $0.id) }
    .sheet(isPresented: $addingCode) { AddCodeSheet() }
    .sheet(item: $moving) { MoveToCategorySheet(ids: [$0.id]) }
    .confirmationDialog(
      store.t("清空回收站？", "Empty Trash?"), isPresented: $emptyingTrash, titleVisibility: .visible
    ) {
      let plan = TrashPlan(items: store.items, canEdit: store.canEdit)
      if !plan.removable.isEmpty {
        Button(store.t("永久删除 \(plan.removable.count) 项", "Delete \(plan.removable.count) items permanently"), role: .destructive) {
          Task { await store.emptyTrash() }
        }
      }
      Button(store.t("取消", "Cancel"), role: .cancel) {}
    } message: {
      let plan = TrashPlan(items: store.items, canEdit: store.canEdit)
      Text(
        (plan.removable.isEmpty
          ? store.t("没有可以永久删除的项目。", "There is nothing this device can delete permanently.")
          : store.t("将永久删除 \(plan.removable.count) 个项目，无法恢复。", "\(plan.removable.count) items will be deleted permanently. This cannot be undone."))
        + (plan.kept > 0
          ? store.t("共享资料库中的 \(plan.kept) 个项目会保留在回收站。", " \(plan.kept) shared items stay in Trash.") : ""))
    }
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
