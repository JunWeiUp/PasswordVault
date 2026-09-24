import SwiftUI

struct EntryDetailView: View {
  @EnvironmentObject private var store: AppStore
  let item: VaultItem
  @State private var showSource = false
  @State private var switchingSource = false
  @State private var editorGeneration = UUID()
  private var preview: Bool {
    get { store.notePreviewModes[item.id] ?? true }
    nonmutating set { store.notePreviewModes[item.id] = newValue }
  }
  @State private var showNoteInfo = false
  @State private var confirmTrash = false
  @State private var confirmDelete = false
  @FocusState private var noteTitleFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      detailToolbar
      ScrollViewReader { reader in
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          HStack {
            Spacer()
            if store.saveFailed {
              Label(store.t("修改尚未保存", "Changes not saved"), systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
              Button(store.t("重试保存", "Retry save")) { Task { await store.flushChanges() } }.font(
                .caption)
            } else {
              Label(
                store.saving ? store.t("正在保存…", "Saving…") : store.t("已加密保存", "Saved encrypted"),
                systemImage: store.saving ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
              ).font(.caption).foregroundStyle(store.saving ? .secondary : Color.green)
            }
          }.id("entry-top")
          if item.isDeleted {
            HStack {
              Label(store.t("此条目在回收站中", "This entry is in Trash"), systemImage: "trash")
              Spacer()
              Button(store.t("恢复", "Restore")) { Task { await store.trash(item) } }
            }.padding(12).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 8))
          }
          if store.canEdit(item) {
            TextField(store.t("标题", "Title"), text: noteBinding("title")).font(
              .system(size: 30, weight: .semibold)
            ).textFieldStyle(.plain).focused($noteTitleFocused)
          } else {
            Text(item.title).font(.system(size: 30, weight: .semibold)).textSelection(.enabled)
          }
          if item.type == "secureNote" {
            if showSource && store.canEdit(item) {
              TextEditor(text: noteBinding("note", markdown: true)).font(.system(size: 16, design: .monospaced)).scrollContentBackground(.hidden).frame(minHeight: 550)
            } else {
              if item.string("noteFormat") == "markdown" {
                MarkdownNoteEditor(item: item, editing: !preview, beginEditing: { preview = false }).id(editorGeneration)
              } else {
                EditableNotePreview(text: noteBinding("note"), markdown: false, chinese: store.chinese, editing: !preview, canEdit: store.canEdit(item), beginEditing: { preview = false })
              }
            }
          } else {
            InlineRecordFields(item: item)
          }
          if item.type == "secureNote" && showNoteInfo { EntryMetadata(item: item) }
          Spacer(minLength: 40)
        }.padding(.horizontal, 36).padding(.bottom, 36).frame(maxWidth: 900, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onAppear { if let anchor = store.browserAccountAnchor { reader.scrollTo(anchor, anchor: .top) } }
      .onChange(of: store.browserNavigationID) { _ in
        if let anchor = store.browserAccountAnchor { reader.scrollTo(anchor, anchor: .top) }
      }
      }
    }
    .onAppear {
      if store.editingNewNoteID == item.id {
        preview = false
        noteTitleFocused = true
        store.editingNewNoteID = nil
      }
    }
    .onDisappear { store.endEntryEditing(item.id) }
    .confirmationDialog(
      store.t("移到回收站？", "Move to trash?"), isPresented: $confirmTrash, titleVisibility: .visible
    ) {
      Button(store.t("移到回收站", "Move to trash"), role: .destructive) {
        Task { await store.trash(item) }
      }
      Button(store.t("取消", "Cancel"), role: .cancel) {}
    } message: {
      Text(store.t("之后可以从回收站恢复。", "You can restore it from Trash later."))
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
      Text(store.t("此操作无法撤销。", "This cannot be undone."))
    }
  }

  private var detailToolbar: some View {
    ViewThatFits(in: .horizontal) {
      toolbarLayout(breadcrumb: true, compactNoteInfo: false)
      toolbarLayout(breadcrumb: false, compactNoteInfo: false)
      toolbarLayout(breadcrumb: false, compactNoteInfo: true)
    }
    .font(.system(size: 13))
    .padding(.horizontal, 36)
    .padding(.top, 47)
    .padding(.bottom, 24)
    .frame(maxWidth: 900, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func toolbarLayout(breadcrumb: Bool, compactNoteInfo: Bool) -> some View {
    HStack(spacing: 12) {
      if breadcrumb {
        Text(item.category.isEmpty ? store.destination.title(chinese: store.chinese) : item.category)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(minWidth: 72, maxWidth: .infinity, alignment: .leading)
      } else {
        Spacer(minLength: 0)
      }
      if item.type == "secureNote" && !item.isDeleted {
        noteToolbarControls(compact: compactNoteInfo)
      }
      HStack(spacing: 8) {
        Button {
          Task { await store.toggleFavorite(item.id) }
        } label: {
          toolbarIcon(item.isFavorite ? "star.fill" : "star")
        }
        .buttonStyle(VaultButtonStyle(.plain))
        .foregroundStyle(item.isFavorite ? Palette.accent : .secondary)
        .accessibilityLabel(item.isFavorite ? store.t("取消收藏", "Unfavorite") : store.t("收藏", "Favorite"))
        .accessibilityIdentifier("entry.favorite")
        .help(item.isFavorite ? store.t("取消收藏", "Unfavorite") : store.t("收藏", "Favorite"))

        Button(role: .destructive) {
          if item.isDeleted { confirmDelete = true } else { confirmTrash = true }
        } label: {
          toolbarIcon("trash")
        }
        .buttonStyle(VaultButtonStyle(.plain))
        .foregroundStyle(.red)
        .accessibilityLabel(item.isDeleted ? store.t("永久删除", "Delete permanently") : store.t("移到回收站", "Move to Trash"))
        .accessibilityIdentifier("entry.delete")
        .help(item.isDeleted ? store.t("永久删除此条目", "Delete this entry permanently") : store.t("移到回收站，可恢复", "Move to Trash; can be restored"))

        entryActionsMenu
      }
      .fixedSize(horizontal: true, vertical: false)

      Divider().frame(height: 20)
      Button(action: store.lock) {
        Label(store.t("锁定", "Lock"), systemImage: "lock.fill")
          .lineLimit(1)
          .frame(width: 64, height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(VaultButtonStyle(.plain))
      .accessibilityIdentifier("entry.lock")
      .help(store.t("锁定资料库 ⌘L", "Lock vault ⌘L"))
      .fixedSize(horizontal: true, vertical: false)
    }
    .frame(height: 32)
  }

  private func noteToolbarControls(compact: Bool) -> some View {
    HStack(spacing: 8) {
      Picker(store.t("显示方式", "Display"), selection: Binding(get: { preview }, set: { preview = $0; showSource = false })) {
        Text(store.t("编辑", "Edit")).tag(false)
        Text(store.t("预览", "Preview")).tag(true)
      }
      .disabled(!store.canEdit(item))
      .pickerStyle(.segmented)
      .controlSize(.large)
      .tint(Palette.blue)
      .labelsHidden()
      .frame(width: 136, height: 32)

      Button { showNoteInfo.toggle() } label: {
        Group {
          if compact {
            toolbarIcon("info.circle")
          } else {
            Text(store.t("笔记信息", "Note info"))
              .lineLimit(1)
              .padding(.horizontal, 10)
              .frame(height: 32)
              .contentShape(Rectangle())
          }
        }
      }
      .buttonStyle(VaultButtonStyle(.plain))
      .foregroundStyle(showNoteInfo ? Palette.accent : .primary)
      .accessibilityLabel(store.t("笔记信息", "Note info"))
      .accessibilityIdentifier("entry.note-info")
      .help(store.t("笔记信息", "Note info"))
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private func toolbarIcon(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 15, weight: .medium))
      .frame(width: 32, height: 32)
      .contentShape(Rectangle())
  }

  private var entryActionsMenu: some View {
    Menu {
      Group {
        if item.type == "secureNote" && store.canEdit(item) {
          Button(store.t(showSource ? "返回笔记" : "Markdown 源码", showSource ? "Back to note" : "Markdown source")) {
            if showSource { showSource = false; preview = false }
            else {
              switchingSource = true
              Task {
                let captured = await store.prepareNoteSource(item.id)
                if captured { showSource = true; preview = false }
                else { editorGeneration = UUID() }
                switchingSource = false
              }
            }
          }.disabled(switchingSource)
        }
        if item.isDeleted {
          Button(store.t("恢复", "Restore")) { Task { await store.trash(item) } }
          Button(store.t("永久删除", "Delete permanently"), role: .destructive) {
            confirmDelete = true
          }
        } else {
          Button(item.isPinned ? store.t("取消置顶", "Unpin") : store.t("置顶", "Pin")) {
            Task { await store.togglePin(item.id) }
          }
          Button(store.t("移到回收站", "Move to trash"), role: .destructive) { confirmTrash = true }
        }
      }.buttonStyle(.automatic)
    } label: {
      toolbarIcon("ellipsis")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .frame(width: 32, height: 32)
    .vaultHoverFeedback()
    .accessibilityLabel(store.t("更多条目操作", "More entry actions"))
    .accessibilityIdentifier("entry.more")
    .help(store.t("更多条目操作", "More entry actions"))
  }

  private func noteBinding(_ key: String, markdown: Bool = false) -> Binding<String> {
    Binding(
      get: { item.string(key) },
      set: { value in
        var changed = store.items.first(where: { $0.id == item.id }) ?? item
        changed.set(key, value)
        if markdown { changed.set("noteFormat", "markdown") }
        store.editNote(changed)
      })
  }
}

private struct PasswordFields: View {
  @EnvironmentObject private var store: AppStore
  let item: VaultItem
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ValueRow(title: store.t("用户名", "Username"), value: item.username)
      ValueRow(title: store.t("密码", "Password"), value: item.password, secret: true)
      ValueRow(title: store.t("网站", "Website"), value: item.string("url"), website: true)
      if let accounts = item.fields["accounts"]?.array, !accounts.isEmpty {
        DisclosureGroup(store.t("其他账号", "Additional accounts") + "  \(accounts.count)") {
          ForEach(Array(accounts.enumerated()), id: \.offset) { _, account in
            ValueRow(
              title: account.object["label"]?.string ?? store.t("用户名", "Username"),
              value: account.object["username"]?.string ?? "")
            ValueRow(
              title: store.t("密码", "Password"), value: account.object["password"]?.string ?? "",
              secret: true)
          }
        }.padding(.vertical, 20)
        Divider()
      }
      if let history = item.fields["passwordHistory"]?.array, !history.isEmpty {
        DisclosureGroup(store.t("密码历史", "Password history")) {
          ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
            ValueRow(
              title: entry.object["changedAt"]?.string ?? "",
              value: entry.object["password"]?.string ?? "", secret: true)
          }
        }.padding(.vertical, 20)
      }
    }
  }
}

struct ValueRow: View {
  @EnvironmentObject private var store: AppStore
  let title: String
  let value: String
  var secret = false
  var website = false
  @State private var revealed = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
      HStack(alignment: .center, spacing: 16) {
        Text(secret && !revealed && !value.isEmpty ? "••••••••••••" : (value.isEmpty ? "—" : value))
          .font(.system(size: 16, design: secret ? .monospaced : .default)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if secret {
          Button {
            revealed.toggle()
          } label: {
            Image(systemName: revealed ? "eye.slash" : "eye")
          }.buttonStyle(VaultButtonStyle(.plain)).help(store.t("显示或隐藏", "Reveal or conceal"))
            .accessibilityLabel(
              revealed
                ? store.t("隐藏\(title)", "Hide \(title)") : store.t("显示\(title)", "Reveal \(title)"))
        }
        if website, let url = URL(string: value), ["https", "http"].contains(url.scheme ?? "") {
          Link(destination: url) { Image(systemName: "arrow.up.right.square") }.vaultHoverFeedback()
            .help(
              store.t("打开网站", "Open website"))
        }
        Button {
          store.copy(value)
        } label: {
          Label(store.t("复制", "Copy"), systemImage: "doc.on.doc")
        }.buttonStyle(VaultButtonStyle(.plain)).foregroundStyle(Palette.accent).disabled(
          value.isEmpty)
      }
    }.padding(.vertical, 19)
    Divider()
  }
}

private struct WalletFields: View {
  @EnvironmentObject private var store: AppStore
  let item: VaultItem
  var body: some View {
    VStack(spacing: 0) {
      ValueRow(title: store.t("网络", "Network"), value: item.string("network"))
      ValueRow(title: store.t("地址", "Address"), value: item.string("address"))
      ValueRow(title: store.t("私钥", "Private key"), value: item.string("privateKey"), secret: true)
      ValueRow(
        title: store.t("助记词", "Recovery phrase"), value: item.string("mnemonic"), secret: true)
    }
  }
}

private struct CodeFields: View {
  @EnvironmentObject private var store: AppStore
  let item: VaultItem
  @State private var code = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text(item.username).foregroundStyle(.secondary)
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let period = max(1, Int(item.number("period", fallback: 30)))
        let seconds = Int(context.date.timeIntervalSince1970)
        VStack(alignment: .leading, spacing: 20) {
          HStack {
            Text(code.isEmpty ? "——— ———" : String(code.prefix(3)) + " " + String(code.suffix(3)))
              .font(.system(size: 40, weight: .medium, design: .monospaced))
            Spacer()
            Button(store.t("复制", "Copy")) { store.copy(code) }.disabled(code.isEmpty)
          }
          ProgressView(value: Double(period - seconds % period), total: Double(period)).tint(
            Palette.blue)
          Text(
            store.t(
              "\(period - seconds % period) 秒后更新", "Refreshes in \(period - seconds % period)s")
          ).font(.caption).foregroundStyle(.secondary)
        }.task(id: [item.string("secret"), String(period), String(seconds / period)]) {
          await refreshCode(time: seconds, period: period)
        }
      }
    }.padding(.vertical, 16)
  }
  private func refreshCode(time: Int, period: Int) async {
    do {
      let result = try await store.perform([
        "op": .string("totp"), "secret": .string(item.string("secret")),
        "period": .number(Double(period)), "time": .number(Double(time)),
      ])
      code = result.object["code"]?.string ?? ""
    } catch {
      code = ""
      store.report(error)
    }
  }
}

struct MarkdownPreview: View {
  let text: String
  var markdown = true
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if markdown {
        ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
          MarkdownLine(line: line)
        }
      } else {
        Text(text).font(.system(size: 16)).lineSpacing(8).textSelection(.enabled)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct MarkdownLine: View {
  let line: String
  var body: some View {
    Group {
      if line.hasPrefix("### ") {
        Text(String(line.dropFirst(4))).font(.headline).padding(.top, 10)
      } else if line.hasPrefix("## ") {
        Text(String(line.dropFirst(3))).font(.title3.weight(.semibold)).padding(.top, 18)
      } else if line.hasPrefix("# ") {
        Text(String(line.dropFirst(2))).font(.title2.weight(.semibold)).padding(.top, 18)
      } else if line == "---" {
        Divider().padding(.vertical, 8)
      } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
        HStack(alignment: .top, spacing: 12) {
          Text("•")
          inline(String(line.dropFirst(2)))
        }
      } else if line.isEmpty {
        Color.clear.frame(height: 5)
      } else {
        inline(line)
      }
    }.textSelection(.enabled).font(.system(size: 16)).lineSpacing(7)
  }
  private func inline(_ value: String) -> Text {
    // Native attributed text does not load remote images or execute HTML.
    if let parsed = try? AttributedString(
      markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    {
      return Text(parsed)
    }
    return Text(value)
  }
}
