import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct QRImportView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let accept: (VaultItem) -> Void
  @StateObject private var camera = QRScanner()
  @State private var uri = ""
  @State private var candidate: VaultItem?
  @State private var message: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text(store.t("添加验证码", "Add authenticator code")).font(.title2)
        Spacer()
        Button(store.t("取消", "Cancel")) { dismiss() }
      }
      if camera.running {
        CameraPreview(session: camera.session).frame(height: 250).clipShape(
          RoundedRectangle(cornerRadius: 10))
      }
      HStack {
        Button(store.t("启动相机", "Start camera")) { camera.start() }
        Button(store.t("从图片读取…", "Read from image…"), action: chooseImage)
      }
      if let cameraError = camera.error { Text(cameraError).foregroundStyle(.secondary) }
      TextField("otpauth://totp/…", text: $uri).textFieldStyle(.roundedBorder).onSubmit {
        Task { await parse(uri) }
      }
      Button(store.t("解析设置链接", "Parse setup link")) { Task { await parse(uri) } }
      if let message { Text(message).foregroundStyle(.red) }
      if let candidate {
        Divider()
        Text(store.t("核对账号", "Review account")).font(.headline)
        Text(candidate.title)
        Text(candidate.username).foregroundStyle(.secondary)
        Text(
          store.t(
            "刷新间隔：\(Int(candidate.number("period", fallback: 30))) 秒",
            "Period: \(Int(candidate.number("period", fallback: 30))) seconds")
        ).font(.caption)
        Button(store.t("使用此账号", "Use this account")) {
          accept(candidate)
          dismiss()
        }.buttonStyle(VaultButtonStyle(.primary)).tint(Palette.blue)
      }
      Text(
        store.t(
          "支持单账号 SHA-1、6 位 TOTP。相机不可用时可粘贴链接或手动填写密钥。",
          "Supports single-account SHA-1, 6-digit TOTP. Paste a link or enter a key manually if the camera is unavailable."
        )
      ).font(.caption).foregroundStyle(.secondary)
    }.padding(28).frame(width: 580)
      .onAppear { camera.onCode = { value in Task { await parse(value) } } }
      .onDisappear {
        camera.stop()
        camera.onCode = nil
        uri = ""
        candidate = nil
      }
  }
  private func parse(_ value: String) async {
    do {
      let parsed = try await store.perform(["op": .string("parse-totp"), "uri": .string(value)])
      candidate = try JSONDecoder().decode(VaultItem.self, from: JSONEncoder().encode(parsed))
      message = nil
      camera.stop()
    } catch {
      message = store.t(
        "二维码无效或使用了不支持的验证方式。", "Invalid QR code or unsupported authenticator format.")
    }
  }
  private func chooseImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let request = VNDetectBarcodesRequest()
      request.symbologies = [.qr]
      try VNImageRequestHandler(url: url, options: [:]).perform([request])
      guard let value = request.results?.first?.payloadStringValue else {
        throw VaultError.InvalidData
      }
      Task { await parse(value) }
    } catch { message = store.t("图片中没有可读取的二维码。", "No readable QR code was found in the image.") }
  }
}

final class QRScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  let session = AVCaptureSession()
  @Published var running = false
  @Published var error: String?
  var onCode: ((String) -> Void)?
  private let queue = DispatchQueue(label: "PasswordVault.camera")
  private var detected = false
  func start() {
    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      guard let self else { return }
      guard granted else {
        DispatchQueue.main.async { self.error = "相机权限未开启 / Camera permission denied" }
        return
      }
      self.queue.async {
        do {
          self.detected = false
          if self.session.inputs.isEmpty {
            guard let device = AVCaptureDevice.default(for: .video) else {
              throw VaultError.Unsupported
            }
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.queue)
            self.session.beginConfiguration()
            guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
              self.session.commitConfiguration()
              throw VaultError.Unsupported
            }
            self.session.addInput(input)
            self.session.addOutput(output)
            self.session.commitConfiguration()
          }
          self.session.startRunning()
          DispatchQueue.main.async {
            self.running = true
            self.error = nil
          }
        } catch { DispatchQueue.main.async { self.error = "无法启动相机 / Camera unavailable" } }
      }
    }
  }
  func stop() {
    queue.async {
      self.session.stopRunning()
      DispatchQueue.main.async { self.running = false }
    }
  }
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !detected, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    guard
      (try? VNImageRequestHandler(cvPixelBuffer: pixel, options: [:]).perform([request])) != nil,
      let value = request.results?.first?.payloadStringValue
    else { return }
    detected = true
    DispatchQueue.main.async { self.onCode?(value) }
  }
}

private struct CameraPreview: NSViewRepresentable {
  let session: AVCaptureSession
  func makeNSView(context: Context) -> VideoContainer { VideoContainer(session: session) }
  func updateNSView(_ nsView: VideoContainer, context: Context) {}
}

private final class VideoContainer: NSView {
  let preview: AVCaptureVideoPreviewLayer
  init(session: AVCaptureSession) {
    preview = AVCaptureVideoPreviewLayer(session: session)
    super.init(frame: .zero)
    wantsLayer = true
    preview.videoGravity = .resizeAspectFill
    layer = preview
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func layout() {
    super.layout()
    preview.frame = bounds
  }
}
