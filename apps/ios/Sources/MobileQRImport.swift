import PhotosUI
import SwiftUI
import Vision

struct MobileQRImport: View {
  @EnvironmentObject private var store: MobileVaultStore
  @Environment(\.dismiss) private var dismiss
  let apply: ([String: JSONValue]) -> Void
  var payloadHandler: ((String) -> Void)? = nil
  /// Saves the parsed code before closing; returns an error message to show instead.
  var save: (([String: JSONValue]) async -> String?)? = nil
  /// "Add code" layout: scan first, then image, link and manual key entry.
  var manual = false
  @State private var selection: PhotosPickerItem?
  @State private var camera = false
  @State private var busy = false
  @State private var message: String?
  @State private var uri = ""
  var body: some View {
    let photoLabel = store.t("从图片识别二维码", "Scan QR from photo")
    NavigationStack {
      Form {
        Section {
          if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button {
              camera = true
            } label: {
              Label(manual ? store.t("扫描二维码", "Scan QR code") : store.t("拍摄二维码", "Capture QR code"), systemImage: "camera")
            }
          }
          PhotosPicker(selection: $selection, matching: .images) {
            Label(photoLabel, systemImage: "photo")
          }
          if manual, let save {
            NavigationLink {
              ManualCodeForm(save: save, done: { dismiss() })
            } label: {
              Label(store.t("手动输入密钥", "Enter setup key"), systemImage: "keyboard")
            }.accessibilityIdentifier("code.manual")
          }
        } footer: {
          if manual {
            Text(store.t("扫描网站提供的二维码，或手动输入密钥。相机画面只在本机处理；拒绝相机权限时仍可手动输入。",
              "Scan the QR code the website shows, or enter the key. The camera image stays on this device; without camera access you can still type the key."))
          }
        }
        Section(store.t("也可粘贴设置链接", "Or paste a setup link")) {
          TextField("otpauth://…", text: $uri).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button(store.t("导入", "Import")) { parse(uri) }.disabled(uri.isEmpty)
        }
        if busy { ProgressView() }
        if let message { Text(message).foregroundStyle(.red) }
      }.disabled(busy).navigationTitle(manual ? store.t("添加验证码", "Add code") : store.t("导入验证码", "Import authenticator"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(store.t("取消", "Cancel")) { dismiss() }
          }
        }
        .onChange(of: selection) { value in
          Task {
            guard let data = try? await value?.loadTransferable(type: Data.self),
              data.count <= 20 * 1024 * 1024
            else {
              message = store.t("图片无法读取或过大", "Image unreadable or too large")
              return
            }
            scan(data)
          }
        }
        .sheet(isPresented: $camera) {
          QRCamera { image in
            camera = false
            if let data = image?.jpegData(compressionQuality: 0.9) { scan(data) }
          }
        }
    }
  }
  private func scan(_ data: Data) {
    busy = true
    message = nil
    let rawPayload = payloadHandler != nil
    Task {
      do {
        let payload = try await Task.detached { () -> String in
          let request = VNDetectBarcodesRequest()
          request.symbologies = [.qr]
          try VNImageRequestHandler(data: data).perform([request])
          guard
            let value = request.results?.compactMap(\.payloadStringValue).first(where: {
              rawPayload || $0.lowercased().hasPrefix("otpauth://")
            })
          else { throw VaultError.InvalidData }
          return value
        }.value
        busy = false
        parse(payload)
      } catch {
        busy = false
        message = store.t(
          "没有发现有效的验证码二维码，可手动粘贴设置链接。",
          "No authenticator QR found. You can paste the setup link instead.")
      }
    }
  }
  private func parse(_ text: String) {
    if let payloadHandler { payloadHandler(text); dismiss(); return }
    busy = true
    Task {
      defer { busy = false }
      do {
        let result = try await store.perform(CoreRequest.parseTotp(uri: text))
        if let save {
          if let failure = await save(result.object) { message = failure; return }
        } else {
          apply(result.object)
        }
        dismiss()
      } catch {
        message = store.t(
          "设置链接无效。仅支持 TOTP 验证器。", "Invalid setup link. Only TOTP authenticators are supported.")
      }
    }
  }
}
private struct QRCamera: UIViewControllerRepresentable {
  let complete: (UIImage?) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(complete) }
  func makeUIViewController(context: Context) -> UIImagePickerController {
    let controller = UIImagePickerController()
    controller.sourceType = .camera
    controller.delegate = context.coordinator
    return controller
  }
  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate
  {
    let complete: (UIImage?) -> Void
    init(_ complete: @escaping (UIImage?) -> Void) { self.complete = complete }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { complete(nil) }
    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) { complete(info[.originalImage] as? UIImage) }
  }
}
