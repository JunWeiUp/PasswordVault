import XCTest
@testable import CommonRelay
final class CryptoTests: XCTestCase {
    func testPythonVectorsAndTamper() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let v = try dictionary(Data(contentsOf: root.appendingPathComponent("protocol/crypto-vectors.json")))
        let id = v["id"] as! String
        let bob = try RelayIdentity(app: "example", group: "test", device: "bob", secretKey: Data(relayHex: v["bob_secret"] as! String), trustedPeers: ["alice": Data(relayHex: v["alice_public"] as! String)])
        XCTAssertEqual(bob.publicKey.relayHex, v["bob_public"] as? String)
        let plain = try bob.open(from: "alice", kind: "message", id: id, body: v["message"] as! String)
        XCTAssertEqual(plain["data"] as? String, "aGVsbG8=")
        XCTAssertThrowsError(try bob.open(from: "alice", kind: "message", id: String(repeating: "0", count: 32), body: v["message"] as! String))
        XCTAssertEqual(try bob.open(from: "alice", kind: "message", id: id, body: v["offline_message"] as! String)["expires"] as? Int, v["offline_expires"] as? Int)
        let stream = try SecretStream(descriptor: v["stream_descriptor"] as! [String: Any])
        let aad = try bob.aad(from: "alice", to: "bob", id: id, sequence: 0)
        XCTAssertEqual(String(data: aad, encoding: .utf8), v["stream_aad"] as? String)
        XCTAssertEqual(try stream.pull(Data(relayHex: v["stream_ciphertext"] as! String), aad: aad), Data("hello".utf8))
        XCTAssertTrue(stream.finished)
        XCTAssertThrowsError(try stream.pull(Data(relayHex: v["stream_ciphertext"] as! String), aad: aad))
    }
}
