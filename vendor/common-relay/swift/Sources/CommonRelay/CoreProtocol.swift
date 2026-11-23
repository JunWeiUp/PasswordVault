import Foundation

/// Bridge to the shared Rust protocol in PasswordVault's vault-core
/// (`crates/vault-core/src/relay_protocol`). Group-chain verification, signing, strict
/// payload parsing, invitation links and message envelopes are implemented once there;
/// this SDK only keeps transport, file streams and the delivery journal.
/// The host app installs a backend that forwards to `VaultCore.relayProtocol(request:)`.
public enum RelayCoreProtocol {
    /// Executes one `relay-protocol-*` JSON request and returns its JSON result.
    public typealias Backend = @Sendable (String) throws -> String
    private static let lock = NSLock()
    nonisolated(unsafe) private static var backend: Backend?

    public static func install(_ value: @escaping Backend) { lock.lock(); backend = value; lock.unlock() }
    public static var installed: Bool { lock.lock(); defer { lock.unlock() }; return backend != nil }

    static func call(_ op: String, _ request: [String: Any]) throws -> [String: Any] {
        lock.lock(); let current = backend; lock.unlock()
        guard let current else { throw RelayError.invalid("relay protocol backend not installed") }
        var request = request; request["op"] = "relay-protocol-" + op
        let text = String(decoding: try json(request), as: UTF8.self)
        return try dictionary(Data(try current(text).utf8))
    }
}
