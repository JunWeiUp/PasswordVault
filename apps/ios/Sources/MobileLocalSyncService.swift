import Darwin
import Foundation
@preconcurrency import Network

@MainActor
final class MobileLocalSyncService: ObservableObject {
  @Published var running = false
  @Published var endpoint = ""
  @Published var peers: [String] = []
  private weak var store: MobileVaultStore?
  private var listener: NWListener?
  private var browser: NWBrowser?
  private var connections: [UUID: NWConnection] = [:]
  private let queue = DispatchQueue(label: "PasswordVault.local-sync")

  init(store: MobileVaultStore) { self.store = store }

  func start() {
    guard !running else { return }
    do {
      let parameters = NWParameters.tcp
      let websocket = NWProtocolWebSocket.Options()
      websocket.maximumMessageSize = 4 * 1024 * 1024
      websocket.autoReplyPing = true
      websocket.setClientRequestHandler(queue) { protocols, _ in
        NWProtocolWebSocket.Response(
          status: protocols.contains("passwordvault-v2") ? .accept : .reject,
          subprotocol: "passwordvault-v2", additionalHeaders: [])
      }
      parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
      let server = try NWListener(using: parameters, on: .any)
      server.service = NWListener.Service(name: "PasswordVault", type: "_passwordvault._tcp")
      server.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.accept(connection) }
      }
      server.stateUpdateHandler = { [weak self, weak server] state in
        Task { @MainActor in
          guard let self, self.listener === server else { return }
          if case .ready = state, let port = server?.port {
            self.running = true
            self.endpoint = "ws://\(Self.localAddress()):\(port.rawValue)"
          } else if case .failed = state {
            self.stop()
            self.store?.error = self.store?.t("无法启动局域网共享。", "Could not start local sharing.")
          }
        }
      }
      listener = server
      server.start(queue: queue)
      let discovery = NWBrowser(
        for: .bonjour(type: "_passwordvault._tcp", domain: nil), using: .tcp)
      discovery.browseResultsChangedHandler = { [weak self] results, _ in
        let names = results.compactMap { result -> String? in
          if case .service(let name, _, _, _) = result.endpoint { return name }
          return nil
        }
        Task { @MainActor in self?.peers = names.sorted() }
      }
      browser = discovery
      discovery.start(queue: queue)
    } catch { store?.report(error) }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    browser?.cancel()
    browser = nil
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
    running = false
    endpoint = ""
    peers = []
  }

  private func accept(_ connection: NWConnection) {
    guard connections.count < 8, store?.unlocked == true else {
      connection.cancel()
      return
    }
    let id = UUID()
    connections[id] = connection
    connection.start(queue: queue)
    connection.receiveMessage { [weak self] data, _, _, error in
      Task { @MainActor in
        guard let self else {
          connection.cancel()
          return
        }
        defer { self.connections.removeValue(forKey: id) }
        guard error == nil, let data, data.count <= 4 * 1024 * 1024,
          let packet = try? JSONDecoder().decode(JSONValue.self, from: data),
          let store = self.store, store.unlocked
        else {
          connection.cancel()
          return
        }
        do {
          let response = try await store.perform(["op": .string("sync-respond"), "packet": packet])
          let result = try JSONEncoder().encode(response)
          guard result.count <= 4 * 1024 * 1024 else { throw VaultError.InvalidData }
          let context = NWConnection.ContentContext(
            identifier: "PasswordVault-v2",
            metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
          connection.send(
            content: result, contentContext: context, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
          try await store.refresh()
        } catch { connection.cancel() }
      }
    }
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 20_000_000_000)
      self?.connections.removeValue(forKey: id)?.cancel()
    }
  }

  static func exchange(endpoint: String, packet: JSONValue) async throws -> JSONValue {
    guard let url = URL(string: endpoint), ["ws", "wss"].contains(url.scheme ?? ""),
      url.host != nil,
      url.user == nil, url.password == nil
    else { throw VaultError.InvalidData }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 20
    let session = URLSession(configuration: config)
    let task = session.webSocketTask(with: url, protocols: ["passwordvault-v2"])
    task.maximumMessageSize = 4 * 1024 * 1024
    defer {
      task.cancel(with: .goingAway, reason: nil)
      session.invalidateAndCancel()
    }
    task.resume()
    try await task.send(.data(JSONEncoder().encode(packet)))
    let response = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) {
      group in
      group.addTask { try await task.receive() }
      group.addTask {
        try await Task.sleep(nanoseconds: 15_000_000_000)
        task.cancel(with: .goingAway, reason: nil)
        throw VaultError.Storage
      }
      let first = try await group.next()!
      group.cancelAll()
      return first
    }
    let data: Data
    switch response {
    case .data(let bytes): data = bytes
    case .string(let text): data = Data(text.utf8)
    @unknown default: throw VaultError.InvalidData
    }
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  private static func localAddress() -> String {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { return "127.0.0.1" }
    defer { freeifaddrs(first) }
    var current = first
    while let pointer = current {
      defer { current = pointer.pointee.ifa_next }
      guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
        String(cString: pointer.pointee.ifa_name).hasPrefix("en")
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(
        address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
        NI_NUMERICHOST) == 0
      {
        return String(cString: host)
      }
    }
    return "127.0.0.1"
  }
}
