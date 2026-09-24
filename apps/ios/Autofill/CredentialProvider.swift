import AuthenticationServices
import SwiftUI

final class CredentialProvider: ASCredentialProviderViewController {
  private let requests = CredentialRequestLifetime()
  private var closing: Task<Void, Never>?
  private var core: MobileCore?
  private var host: UIHostingController<CredentialPicker>?
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
