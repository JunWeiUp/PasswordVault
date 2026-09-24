import SwiftUI

enum NoteCategoryAction: Identifiable {
  case create
  case remove(String)

  var id: String {
    switch self {
    case .create: return "create"
    case .remove(let name): return "remove:" + name
    }
  }
}

struct NoteCategorySheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let action: NoteCategoryAction
  @State private var name = ""
  @State private var working = false
  @State private var error: String?
  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      switch action {
      case .create:
        Text(store.t("添加笔记分类", "Add note category")).font(.title3.weight(.semibold))
        TextField(store.t("分类名称", "Category name"), text: $name)
          .textFieldStyle(.roundedBorder).focused($nameFocused)
          .accessibilityIdentifier("category.name")
          .onSubmit { submit() }
        Text(store.t("可以先创建空分类，再添加笔记。", "Create an empty category and add notes later."))
          .font(.callout).foregroundStyle(.secondary)
      case .remove(let category):
        Text(store.t("删除「\(category)」分类？", "Delete “\(category)” category?"))
          .font(.title3.weight(.semibold))
        Text(
          store.t(
            "笔记内容会保留，可在「全部笔记」中查看。回收站中的笔记仍保留在回收站。",
            "Your notes will remain in All notes. Trashed notes will remain in Trash.")
        )
        .fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
      }
      if let error {
        Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("category.error")
      }
      HStack {
        if working { ProgressView().controlSize(.small) }
        Spacer()
        Button(store.t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        switch action {
        case .create:
          Button(store.t("添加", "Add"), action: submit).buttonStyle(VaultButtonStyle(.primary)).tint(
            Palette.blue
          )
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .remove:
          Button(store.t("删除分类", "Delete category"), role: .destructive, action: submit)
            .keyboardShortcut(.defaultAction)
        }
      }
    }.padding(26).frame(width: 420).disabled(working)
      .interactiveDismissDisabled(working)
      .onAppear { if case .create = action { nameFocused = true } }
  }

  private func submit() {
    guard !working else { return }
    working = true
    error = nil
    Task {
      defer { working = false }
      do {
        switch action {
        case .create: try await store.addCategory(name)
        case .remove(let category): try await store.removeCategory(category)
        }
        dismiss()
      } catch VaultError.AlreadyExists {
        error = store.t("这个分类已存在，请换一个名称。", "This category already exists. Choose another name.")
      } catch VaultError.InvalidData {
        error = store.t(
          "请输入 1–80 个字符的分类名称，不要使用换行或控制字符。",
          "Use a category name with 1–80 characters and no control characters.")
      } catch VaultError.Authentication {
        error = store.t(
          "此分类包含没有编辑权限的共享笔记，暂时无法删除分类。",
          "This category contains shared notes you cannot edit and cannot be removed.")
      } catch {
        self.error = store.t(
          "未能保存分类修改，请检查存储权限后重试。笔记和分类保持原样。",
          "Could not save category changes. Check storage permissions and retry. Your notes and categories are unchanged."
        )
      }
    }
  }
}
