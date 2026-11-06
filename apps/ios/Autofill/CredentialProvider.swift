import AuthenticationServices
import CryptoKit
import SwiftUI

final class CredentialProvider: ASCredentialProviderViewController {
  private let requests = CredentialRequestLifetime()
  private var closing: Task<Void, Never>?
  private var core: MobileCore?
  private var backupExporter: PasskeyBackupExporter?
  private var host: UIViewController?
  override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    let origins = serviceIdentifiers.compactMap { identifier -> String? in
      let raw =
        identifier.type == .domain ? "https://" + identifier.identifier : identifier.identifier
      guard let url = URL(string: raw), let scheme = url.scheme,
        ["https", "http"].contains(scheme), url.host != nil, url.user == nil, url.password == nil
      else { return nil }
      return raw
    }
    show(origins: origins)
  }
  override func provideCredentialWithoutUserInteraction(
    for credentialIdentity: ASPasswordCredentialIdentity
  ) {
    extensionContext.cancelRequest(
      withError: NSError(
        domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
  }
  override func prepareInterfaceToProvideCredential(
    for credentialIdentity: ASPasswordCredentialIdentity
  ) {
    prepareCredentialList(for: [credentialIdentity.serviceIdentifier])
  }
  private func show(origins: [String]) {
    let requestGeneration = requests.advance()
    let previous = core
    core = nil
    let priorClosing = closing
    closing = Task {
      await priorClosing?.value
      await previous?.close()
    }
    if let host {
      host.willMove(toParent: nil)
      host.view.removeFromSuperview()
      host.removeFromParent()
    }
    host = nil
    let picker = CredentialPicker(
      origins: origins,
      unlock: { [weak self] password in
        guard let self, self.requests.isCurrent(requestGeneration) else { throw VaultError.Locked }
        await self.closing?.value
        guard self.requests.isCurrent(requestGeneration) else { throw VaultError.Locked }
        guard let group = Bundle.main.object(forInfoDictionaryKey: "VaultAppGroup") as? String,
          let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group)
        else { throw VaultError.InvalidData }
        let location = container.appendingPathComponent("PasswordVaultNative")
        guard
          FileManager.default.fileExists(
            atPath: location.appendingPathComponent("vault/header.json").path)
        else { throw VaultError.InvalidData }
        let value: MobileCore
        if let existing = self.core {
          value = existing
        } else {
          value = try MobileCore(directory: location)
          self.core = value
        }
        _ = try await value.call(["op": .string("unlock"), "password": .string(password)])
        guard self.requests.isCurrent(requestGeneration) else {
          await value.close()
          throw VaultError.Locked
        }
        var matches: [CredentialChoice] = []
        for origin in origins {
          let response = try await value.call(["op": .string("matches"), "origin": .string(origin)])
          for entry in response.array {
            matches.append(CredentialChoice(origin: origin, fields: entry.object))
          }
        }
        guard self.requests.isCurrent(requestGeneration) else {
          await value.close()
          throw VaultError.Locked
        }
        return matches
      },
      choose: { [weak self] choice in
        guard let self, self.requests.isCurrent(requestGeneration), let core else {
          throw VaultError.Locked
        }
        let response = try await core.call([
          "op": .string("fill"), "origin": .string(choice.origin),
          "id": choice.fields["id"] ?? .null, "accountId": choice.fields["accountId"] ?? .null,
        ])
        guard self.requests.isCurrent(requestGeneration) else { throw VaultError.Locked }
        let credential = ASPasswordCredential(
          user: response.object["username"]?.string ?? "",
          password: response.object["password"]?.string ?? "")
        await core.close()
        guard self.requests.isCurrent(requestGeneration) else { throw VaultError.Locked }
        self.core = nil
        self.extensionContext.completeRequest(
          withSelectedCredential: credential, completionHandler: nil)
      },
      cancel: { [weak self] in
        guard let self, self.requests.isCurrent(requestGeneration) else { return }
        // Invalidate synchronously: an in-flight fill must never complete after Cancel.
        let cancellation = self.requests.advance()
        let previous = self.core
        self.core = nil
        let priorClosing = self.closing
        self.closing = Task {
          await priorClosing?.value
          await previous?.close()
        }
        let cleanup = self.closing
        Task {
          await cleanup?.value
          guard self.requests.isCurrent(cancellation) else { return }
          self.extensionContext.cancelRequest(
            withError: NSError(
              domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
        }
      })
    let host = UIHostingController(rootView: picker)
    self.host = host
    addChild(host)
    view.addSubview(host.view)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
  }
}
struct CredentialChoice: Identifiable {
  let origin: String
  let fields: [String: JSONValue]
  var id: String { origin + (fields["id"]?.string ?? "") + (fields["accountId"]?.string ?? "") }
}
struct CredentialPicker: View {
  let origins: [String]
  let unlock: (String) async throws -> [CredentialChoice]
  let choose: (CredentialChoice) async throws -> Void
  let cancel: () -> Void
  @State private var password = ""
  @State private var choices: [CredentialChoice]?
  @State private var message: String?
  @State private var working = false
  var body: some View {
    NavigationStack {
      List {
        Section("填入目标 / Destination") {
          ForEach(origins, id: \.self) { Text(URL(string: $0)?.host ?? $0) }
        }
        if let message { Text(message).foregroundStyle(.red) }
        if let choices {
          if choices.isEmpty {
            Text(
              "没有匹配账号，请先在 PasswordVault 中保存此网站。\nNo matching accounts. Save this website in PasswordVault first."
            )
          }
          ForEach(choices) { choice in
            Button {
              working = true
              Task {
                defer { working = false }
                do { try await choose(choice) } catch {
                  message = "填充未完成，请重试 / Could not fill; retry"
                }
              }
            } label: {
              VStack(alignment: .leading) {
                Text(choice.fields["title"]?.string ?? "")
                Text(choice.fields["username"]?.string ?? "").foregroundStyle(.secondary)
              }
            }
          }
        } else {
          SecureField("主密码 / Master password", text: $password)
          Button("解锁 / Unlock") {
            working = true
            Task {
              defer {
                working = false
                password = ""
              }
              do { choices = try await unlock(password) } catch {
                message =
                  "无法解锁，请检查主密码并关闭主应用中的操作。\nCould not unlock. Check the password and close operations in the main app."
              }
            }
          }.disabled(password.isEmpty || origins.isEmpty)
        }
      }.disabled(working).navigationTitle("PasswordVault").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消 / Cancel", action: cancel) }
      }
    }.privacySensitive()
  }
}

@available(iOS 17.0, *)
extension CredentialProvider {
  override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters) {
    showPasskey(rp: requestParameters.relyingPartyIdentifier, hash: requestParameters.clientDataHash,
      allowed: requestParameters.allowedCredentials, registration: nil)
  }
  override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
    extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
  }
  override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
    guard let request = credentialRequest as? ASPasskeyCredentialRequest,
      let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else {
      if let identity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity {
        prepareCredentialList(for: [identity.serviceIdentifier])
      }
      return
    }
    showPasskey(rp: identity.relyingPartyIdentifier, hash: request.clientDataHash, allowed: [identity.credentialID], registration: nil)
  }
  override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
    guard let request = registrationRequest as? ASPasskeyCredentialRequest,
      let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
      request.supportedAlgorithms.contains(ASCOSEAlgorithmIdentifier(rawValue: -7)) else {
      extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue)); return
    }
    var excluded: [Data] = []
    if #available(iOS 18.0, *) { excluded = request.excludedCredentials?.map(\.credentialID) ?? [] }
    showPasskey(rp: identity.relyingPartyIdentifier, hash: request.clientDataHash, allowed: [], registration: identity, excluded: excluded)
  }
  private func showPasskey(rp: String, hash: Data, allowed: [Data], registration: ASPasskeyCredentialIdentity?, excluded: [Data] = []) {
    let generation = requests.advance()
    guard hash.count == 32, let url = URL(string: "https://" + rp), url.host == rp, url.path.isEmpty else { return }
    let prior = core; core = nil
    closing = Task { await prior?.close() }
    if let host { host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
    let encode: (Data) -> String = { $0.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    let decode: (String) throws -> Data = { value in
      var raw = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
      guard let data = Data(base64Encoded: raw) else { throw VaultError.InvalidData }; return data
    }
    var pendingRegistration: JSONValue?
    let picker = PasskeyPicker(rp: rp, registering: registration != nil, load: { [weak self] secret in
      guard let self, self.requests.isCurrent(generation) else { throw VaultError.Locked }
      await self.closing?.value
      guard let group = Bundle.main.object(forInfoDictionaryKey: "VaultAppGroup") as? String,
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw VaultError.InvalidData }
      let value: MobileCore
      if let existing = self.core { value = existing }
      else { value = try MobileCore(directory: container.appendingPathComponent("PasswordVaultNative")); self.core = value }
      _ = try await value.call(["op": .string("unlock"), "password": .string(secret)])
      guard self.requests.isCurrent(generation) else { await value.close(); throw VaultError.Locked }
      if registration != nil { return [] }
      let result = try await value.call(["op": .string("passkey-matches"), "rpId": .string(rp)])
      return result.array.filter { allowed.isEmpty || allowed.map(encode).contains($0.object["id"]?.string ?? "") }
    }, choose: { [weak self] selected, secret, backupSecret in
      guard let self, self.requests.isCurrent(generation), let core = self.core else { throw VaultError.Locked }
      var query: [String: JSONValue] = ["op": .string(registration == nil ? "passkey-system-assert" : "passkey-system-create"), "rpId": .string(rp), "clientDataHash": .string(encode(hash)), "currentPassword": .string(secret)]
      if let registration {
        query["library"] = .string("")
        query["excluded"] = .array(excluded.map { .string(encode($0)) })
        query["userHandle"] = .string(encode(registration.userHandle)); query["userName"] = .string(registration.userName)
      } else {
        query["library"] = selected?.object["library"]
        query["itemId"] = selected?.object["itemId"]; query["credentialId"] = selected?.object["id"]
        query["allowed"] = .array(allowed.map { .string(encode($0)) })
      }
      if registration != nil && (backupSecret.count < 10 || backupSecret == secret) { throw VaultError.InvalidData }
      var result: JSONValue
      if registration != nil, let pendingRegistration { result = pendingRegistration }
      else { result = try await core.call(query); if registration != nil { pendingRegistration = result } }
      guard self.requests.isCurrent(generation) else { throw VaultError.Locked }
      let authenticator = try decode(result.object["authenticatorData"]?.string ?? "")
      guard authenticator.count > 32 else { throw VaultError.InvalidData }
      if authenticator[32] & 16 == 0 {
        guard backupSecret.count >= 10, backupSecret != secret else { throw VaultError.InvalidData }
        let index = try await core.call(["op": .string("passkey-index")])
        let expectedLibrary = registration == nil ? selected?.object["library"] : result.object["library"]
        let expectedItem = registration == nil ? selected?.object["itemId"] : result.object["itemId"]
        guard let expectedLibrary, let expectedItem,
          let source = index.object["passkeys"]?.array.first(where: {
            $0.object["id"] == result.object["id"] && $0.object["rpId"] == .string(rp)
              && $0.object["library"] == expectedLibrary && $0.object["itemId"] == expectedItem
          }) else { throw VaultError.InvalidData }
        let export = try await core.call(["op": .string("passkey-backup-export"), "credentialId": result.object["id"] ?? .null,
          "itemId": source.object["itemId"] ?? .null, "library": source.object["library"] ?? .string(""),
          "currentPassword": .string(secret), "backupPassword": .string(backupSecret)])
        guard self.requests.isCurrent(generation), let content = export.object["content"]?.string else { throw VaultError.Locked }
        try await self.savePasskeyBackup(content)
        guard self.requests.isCurrent(generation) else { throw VaultError.Locked }
        _ = try await core.call(["op": .string("passkey-backup-confirm"), "receipt": export.object["receipt"] ?? .null, "currentPassword": .string(secret),
          "credentialId": result.object["id"] ?? .null, "itemId": source.object["itemId"] ?? .null, "library": source.object["library"] ?? .string(""),
          "actualArchiveHash": .string(SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())])
        query["credentialId"] = result.object["id"]
        query["itemId"] = source.object["itemId"]; query["library"] = source.object["library"]
        if registration != nil { query["op"] = .string("passkey-system-registration-response") }
        result = try await core.call(query)
      }
      query.removeValue(forKey: "currentPassword")
      guard self.requests.isCurrent(generation) else { throw VaultError.Locked }
      let fields = result.object
      let id = try decode(fields["id"]?.string ?? "")
      await core.close(); self.core = nil
      guard self.requests.isCurrent(generation) else { throw VaultError.Locked }
      if registration != nil {
        let credential = ASPasskeyRegistrationCredential(relyingParty: rp, clientDataHash: hash, credentialID: id, attestationObject: try decode(fields["attestationObject"]?.string ?? ""))
        if let registration {
          let identity = ASPasskeyCredentialIdentity(relyingPartyIdentifier: rp, userName: registration.userName, credentialID: id, userHandle: registration.userHandle, recordIdentifier: fields["id"]?.string)
          ASCredentialIdentityStore.shared.saveCredentialIdentities([identity]) { _, _ in }
        }
        self.extensionContext.completeRegistrationRequest(using: credential, completionHandler: nil)
      } else {
        let credential = ASPasskeyAssertionCredential(userHandle: try decode(fields["userHandle"]?.string ?? ""), relyingParty: rp, signature: try decode(fields["signature"]?.string ?? ""), clientDataHash: hash, authenticatorData: try decode(fields["authenticatorData"]?.string ?? ""), credentialID: id)
        self.extensionContext.completeAssertionRequest(using: credential, completionHandler: nil)
      }
    }, cancel: { [weak self] in
      guard let self else { return }; _ = self.requests.advance()
      let prior = self.core; self.core = nil
      Task { await prior?.close() }
      self.extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
    })
    let controller = UIHostingController(rootView: picker); host = controller
    addChild(controller); view.addSubview(controller.view); controller.view.frame = view.bounds
    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; controller.didMove(toParent: self)
  }
}

private struct PasskeyPicker: View {
  let rp: String
  let registering: Bool
  let load: (String) async throws -> [JSONValue]
  let choose: (JSONValue?, String, String) async throws -> Void
  let cancel: () -> Void
  @State private var secret = ""
  @State private var backupSecret = ""
  @State private var backupConfirmation = ""
  @State private var choices: [JSONValue]?
  @State private var error: String?
  @State private var busy = false
  var body: some View {
    NavigationStack {
      List {
        Text(rp)
        if let error { Text(error).foregroundStyle(.red) }
        SecureField("主密码 / Master password", text: $secret)
        if let choices {
          Text("首次使用需保存可恢复的加密 Passkey 备份。请选择资料库之外的独立位置，并单独保存备份口令。\nFirst use requires a recoverable encrypted passkey backup. Save it in an independent location outside this vault, with a separate backup password.")
          SecureField("独立备份口令（至少 10 字符） / Backup passphrase", text: $backupSecret)
          SecureField("确认备份口令 / Confirm backup passphrase", text: $backupConfirmation)
          if registering { Text("保存到个人资料库 / Save to personal vault"); Button("创建通行密钥 / Create passkey") { complete(nil) }.disabled(backupSecret.count < 10 || backupSecret != backupConfirmation || backupSecret == secret) }
          else {
            if choices.isEmpty { Text("没有匹配通行密钥 / No matching passkeys") }
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
              Button(choice.object["userName"]?.string ?? "Passkey") { complete(choice) }
            }
          }
        } else {
          Button("解锁 / Unlock") {
            busy = true
            Task { defer { busy = false }; do { choices = try await load(secret) } catch { self.error = "无法解锁 / Could not unlock" } }
          }.disabled(secret.isEmpty)
        }
      }.disabled(busy).navigationTitle("Passkey").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消 / Cancel") { secret = ""; cancel() } } }
      .privacySensitive()
    }
  }
  private func complete(_ item: JSONValue?) {
    busy = true
    Task { defer { busy = false; secret = ""; backupSecret = ""; backupConfirmation = "" }; do {
      guard backupSecret == backupConfirmation else { throw VaultError.InvalidData }
      try await choose(item, secret, backupSecret) } catch { self.error = "请求未完成：请检查主密码、独立备份口令和备份保存结果 / Check the master password, separate backup passphrase, and saved backup" } }
  }
}


@available(iOS 17.0, *)
private extension CredentialProvider {
  func savePasskeyBackup(_ content: String) async throws {
    let data = Data(content.utf8)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PasswordVault-Passkey-" + UUID().uuidString + ".pvault")
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    defer { try? FileManager.default.removeItem(at: url); backupExporter = nil }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let delegate = PasskeyBackupExporter(expectedHash: Data(SHA256.hash(data: data)), expectedSize: data.count, source: url, continuation: continuation)
      backupExporter = delegate
      let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
      picker.delegate = delegate
      present(picker, animated: true)
    }
  }
}
private final class PasskeyBackupExporter: NSObject, UIDocumentPickerDelegate {
  private let expectedHash: Data
  private let expectedSize: Int
  private let source: URL
  private var continuation: CheckedContinuation<Void, Error>?
  init(expectedHash: Data, expectedSize: Int, source: URL, continuation: CheckedContinuation<Void, Error>) {
    self.expectedHash = expectedHash; self.expectedSize = expectedSize; self.source = source; self.continuation = continuation
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(.failure(VaultError.Authentication)) }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first, urls.count == 1, url != source else { finish(.failure(VaultError.InvalidData)); return }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var saved = Data()
      while saved.count <= expectedSize {
        guard let chunk = try handle.read(upToCount: expectedSize + 1 - saved.count), !chunk.isEmpty else { break }
        saved.append(chunk)
      }
      guard saved.count == expectedSize, Data(SHA256.hash(data: saved)) == expectedHash else { throw VaultError.InvalidData }
      finish(.success(()))
    } catch { finish(.failure(error)) }
  }
  private func finish(_ result: Result<Void, Error>) { let pending = continuation; continuation = nil; pending?.resume(with: result) }
}
