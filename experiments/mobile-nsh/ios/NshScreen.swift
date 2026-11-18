import NativeShell
import SwiftUI

/// Host functions the shared NSH mobile UI (apps/mobile) may call. Secrets never cross
/// into the NSH app: codes are computed here and copies go through `store.copy`, which
/// applies the local-only clipboard and expiry rules. The names match the bundle's
/// `capabilities.host` grant.
@MainActor
enum NshHost {
  static func install(on view: NshAppView, store: MobileVaultStore, open: @escaping (String) -> Void) {
    view.handle("vault.codes") { [weak store] _ in
      guard let store, store.unlocked else { throw NshHostError.locked }
      return ["codes": try await codes(store)]
    }
    view.handle("clipboard.copy") { [weak store] data in
      guard let store, store.unlocked,
        let object = data as? [String: Any], let text = object["text"] as? String, !text.isEmpty
      else { throw NshHostError.invalid }
      store.copy(text)
      return nil
    }
    view.handle("vault.open") { data in
      guard let id = (data as? [String: Any])?["id"] as? String, !id.isEmpty else { throw NshHostError.invalid }
      open(id)
      return nil
    }
  }

  static func codes(_ store: MobileVaultStore) async throws -> [[String: Any]] {
    let now = Date().timeIntervalSince1970
    var rows: [[String: Any]] = []
    for item in store.items where item.type == "totp" && !item.isDeleted {
      let period = max(item.number("period", fallback: 30), 1)
      let code =
        (try? await store.perform([
          "op": .string("totp"), "secret": .string(item.string("secret")),
          "period": .number(period), "time": .number(now.rounded(.down)),
        ]).object["code"]?.string) ?? ""
      rows.append([
        "id": item.id, "title": item.title, "username": item.username, "code": code,
        "period": period, "remaining": period - now.truncatingRemainder(dividingBy: period),
      ])
    }
    return rows.sorted { ($0["title"] as? String ?? "") .localizedStandardCompare($1["title"] as? String ?? "") == .orderedAscending }
  }
}

enum NshHostError: LocalizedError {
  case locked, invalid, missingBundle
  var errorDescription: String? {
    switch self {
    case .locked: return "Locked"
    case .invalid: return "InvalidData"
    case .missingBundle: return "MissingBundle"
    }
  }
}

/// An NSH page from the shared mobile UI bundle, hosted in SwiftUI.
struct NshScreen: UIViewRepresentable {
  @EnvironmentObject private var store: MobileVaultStore
  var open: (String) -> Void

  func makeUIView(context: Context) -> NshAppView {
    let view = NshAppView()
    NshHost.install(on: view, store: store, open: open)
    if let url = Bundle.main.url(forResource: "bundle", withExtension: "nshc", subdirectory: "nsh") {
      try? view.loadBundle(at: url)
    }
    return view
  }

  func updateUIView(_ view: NshAppView, context: Context) {}
}

/// The codes tab on NSH: the list is the shared TSX page, details and editing stay native.
struct NshCodesTab: View {
  @EnvironmentObject private var store: MobileVaultStore
  @State private var openedID: String?
  @State private var editor: VaultItem?

  var body: some View {
    NshScreen { openedID = $0 }
      .accessibilityIdentifier("nsh.codes")
      .ignoresSafeArea(edges: .bottom)
      // The NSH page draws its own large title; keep the bar for the native actions only.
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(isPresented: Binding(get: { openedID != nil }, set: { if !$0 { openedID = nil } })) {
        if let id = openedID { MobileEntryDetail(id: id) }
      }
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button(action: store.lock) { Image(systemName: "lock") }.accessibilityLabel(store.t("锁定", "Lock"))
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button { editor = .blank(type: "totp", title: "") } label: { Image(systemName: "plus") }
            .accessibilityLabel(store.t("新建", "Add")).disabled(!store.canWriteLibrary)
        }
      }
      .sheet(item: $editor) { MobileEntryEditor(item: $0) }
  }
}
