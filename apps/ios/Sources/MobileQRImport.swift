import PhotosUI
import SwiftUI
import Vision

struct MobileQRImport: View {
  @EnvironmentObject private var store: MobileVaultStore
  @Environment(\.dismiss) private var dismiss
  let apply: ([String: JSONValue]) -> Void
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
          PhotosPicker(selection: $selection, matching: .images) {
            Label(photoLabel, systemImage: "photo")
          }
          if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button {
              camera = true
            } label: {
              Label(store.t("拍摄二维码", "Capture QR code"), systemImage: "camera")
            }
          }
        }
        Section(store.t("也可粘贴设置链接", "Or paste a setup link")) {
          TextField("otpauth://…", text: $uri).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button(store.t("导入", "Import")) { parse(uri) }.disabled(uri.isEmpty)
        }
        if busy { ProgressView() }
        if let message { Text(message).foregroundStyle(.red) }
      }.disabled(busy).navigationTitle(store.t("导入验证码", "Import authenticator"))
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
    Task {
      do {
        let payload = try await Task.detached { () -> String in
          let request = VNDetectBarcodesRequest()
          request.symbologies = [.qr]
          try VNImageRequestHandler(data: data).perform([request])
          guard
            let value = request.results?.compactMap(\.payloadStringValue).first(where: {
              $0.lowercased().hasPrefix("otpauth://")
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
    busy = true
    Task {
      defer { busy = false }
      do {
        let result = try await store.perform(["op": .string("parse-totp"), "uri": .string(text)])
        apply(result.object)
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
