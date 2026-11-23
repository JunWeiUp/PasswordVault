import Foundation
import Clibsodium

public enum RelayError: Error { case invalid(String), closed, backpressure }

/// Server-wide access password sent as `Relay-Access` on every `/relay/v1` request.
public enum RelayAccess {
    public static let header = "Relay-Access"
    /// 8-128 printable ASCII characters (0x21-0x7E). The password itself is never included in errors.
    public static func validate(_ password: String?) throws {
        guard let password else { return }
        let bytes = Array(password.utf8)
        guard (8...128).contains(bytes.count), bytes.allSatisfy({ (0x21...0x7e).contains($0) }) else { throw RelayError.invalid("access password must be 8-128 printable ASCII characters") }
    }
    static func apply(_ password: String?, to request: inout URLRequest) { if let password { request.setValue(password, forHTTPHeaderField: header) } }
}
public extension Data {
    init(relayHex: String) throws {
        guard relayHex.count % 2 == 0 else { throw RelayError.invalid("hex") }
        var result = Data(); var index = relayHex.startIndex
        while index < relayHex.endIndex { let end = relayHex.index(index, offsetBy: 2); guard let b = UInt8(relayHex[index..<end], radix: 16) else { throw RelayError.invalid("hex") }; result.append(b); index = end }
        self = result
    }
    var relayHex: String { map { String(format: "%02x", $0) }.joined() }
}
func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
func dictionary(_ data: Data) throws -> [String: Any] { guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RelayError.invalid("object") }; return value }
func checked(_ code: Int32) throws { guard code == 0 else { throw RelayError.invalid("cryptographic verification") } }

public struct RelayIdentity: Sendable {
    public let app: String, group: String, device: String
    private let secret: [UInt8], trusted: [String: Data]
    public init(app: String, group: String, device: String, secretKey: Data, trustedPeers: [String: Data]) throws {
        guard secretKey.count == 32, trustedPeers.values.allSatisfy({ $0.count == 32 }), sodium_init() >= 0 else { throw RelayError.invalid("key") }
        self.app = app; self.group = group; self.device = device; secret = Array(secretKey); trusted = trustedPeers
    }
    public static func generateSecretKey() -> Data { var data = [UInt8](repeating: 0, count: 32); randombytes_buf(&data, 32); return Data(data) }
    /// Envelope public key, derived in vault-core.
    public var publicKey: Data { get throws {
        guard let key = try RelayCoreProtocol.call("keys", ["secret": Data(secret).relayHex])["publicKey"] as? String else { throw RelayError.invalid("key") }
        return try Data(relayHex: key)
    } }
    func context(from: String, to: String, kind: String, id: String) -> [Any] { [1, app, group, from, to, kind, id] }
    func aad(from: String, to: String, kind: String = "stream", id: String, sequence: UInt64) throws -> Data { try json(context(from: from, to: to, kind: kind, id: id) + [sequence]) }
    /// Envelope sealing/opening (context binding included) is implemented in vault-core.
    private func envelope(_ peer: String) throws -> [String: Any] {
        guard let key = trusted[peer] else { throw RelayError.invalid("untrusted peer") }
        return ["app": app, "group": group, "device": device, "secret": Data(secret).relayHex, "peerKey": key.relayHex]
    }
    public func seal(to: String, kind: String, id: String, value: [String: Any]) throws -> String {
        var request = try envelope(to); request["to"] = to; request["kind"] = kind; request["id"] = id; request["value"] = value
        guard let body = try RelayCoreProtocol.call("envelope-seal", request)["body"] as? String else { throw RelayError.invalid("envelope") }
        return body
    }
    public func open(from: String, kind: String, id: String, body: String) throws -> [String: Any] {
        var request = try envelope(from); request["from"] = from; request["kind"] = kind; request["id"] = id; request["body"] = body
        guard let value = try RelayCoreProtocol.call("envelope-open", request)["value"] as? [String: Any] else { throw RelayError.invalid("context mismatch") }
        return value
    }
}

final class SecretStream {
    private var state = crypto_secretstream_xchacha20poly1305_state()
    private var key: [UInt8], header: [UInt8]
    private let writer: Bool
    private(set) var finished = false
    init() throws {
        writer = true; key = Array(RelayIdentity.generateSecretKey()); header = [UInt8](repeating: 0, count: 24)
        try checked(crypto_secretstream_xchacha20poly1305_init_push(&state, &header, key))
    }
    init(descriptor: [String: Any]) throws {
        guard let k = descriptor["key"] as? String, let h = descriptor["header"] as? String else { throw RelayError.invalid("stream descriptor") }
        key = Array(try Data(relayHex: k)); header = Array(try Data(relayHex: h)); writer = false
        guard key.count == 32, header.count == 24 else { throw RelayError.invalid("stream key") }
        try checked(crypto_secretstream_xchacha20poly1305_init_pull(&state, header, key))
    }
    var descriptor: [String: Any] { ["key": Data(key).relayHex, "header": Data(header).relayHex] }
    func push(_ plain: Data, aad: Data, final: Bool) throws -> Data {
        guard writer, !finished, plain.count <= 65519 else { throw RelayError.invalid("stream state") }
        var out = [UInt8](repeating: 0, count: plain.count + 17)
        try checked(crypto_secretstream_xchacha20poly1305_push(&state, &out, nil, Array(plain), UInt64(plain.count), Array(aad), UInt64(aad.count), final ? 3 : 0)); finished = final
        return Data(out)
    }
    func pull(_ cipher: Data, aad: Data) throws -> Data {
        guard !writer, !finished, (17...65536).contains(cipher.count) else { throw RelayError.invalid("stream state") }
        var out = [UInt8](repeating: 0, count: cipher.count - 17); var tag: UInt8 = 0
        try checked(crypto_secretstream_xchacha20poly1305_pull(&state, &out, nil, &tag, Array(cipher), UInt64(cipher.count), Array(aad), UInt64(aad.count)))
        guard tag == 0 || tag == 3 else { throw RelayError.invalid("stream tag") }; finished = tag == 3; return Data(out)
    }
    deinit { sodium_memzero(&state, MemoryLayout.size(ofValue: state)); key.withUnsafeMutableBytes { sodium_memzero($0.baseAddress, $0.count) } }
}
