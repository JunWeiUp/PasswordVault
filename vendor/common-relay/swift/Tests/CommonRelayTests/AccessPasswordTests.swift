import XCTest
@testable import CommonRelay
final class AccessPasswordTests: XCTestCase {
    let password = "{{SECRET_ekk36hgw}}"
    func testValidation() throws {
        XCTAssertNoThrow(try RelayAccess.validate(nil))
        XCTAssertNoThrow(try RelayAccess.validate(password))
        for bad in ["short", "has space1", String(repeating: "a", count: 129), "tab\tpassword", "密码密码密码密码"] { XCTAssertThrowsError(try RelayAccess.validate(bad), bad) }
    }
    func testWebSocketUpgradeHeader() throws {
        let url = URL(string: "wss://relay.example/relay/v1/ws")!
        XCTAssertEqual(try RelayClient.upgradeRequest(url: url, token: "t", password: password).value(forHTTPHeaderField: "Relay-Access"), password)
        XCTAssertNil(try RelayClient.upgradeRequest(url: url, token: "t", password: nil).value(forHTTPHeaderField: "Relay-Access"))
        XCTAssertThrowsError(try RelayClient.upgradeRequest(url: url, token: "t", password: "short"))
    }
    func testGroupHeaderOnEveryCall() throws {
        let groups = RelayGroups(config: ["url": "wss://relay.example/relay/v1/ws", "token": "t", "password": password])
        for (method, path, auth) in [("POST", "/group/create", Optional<String>.none), ("GET", "/enroll/abc/link", "InvitationLink x"), ("POST", "/group/bootstrap", "Bootstrap y")] {
            let req = try groups.makeRequest(method, path, value: method == "POST" ? [:] : nil, authorization: auth)
            XCTAssertEqual(req.value(forHTTPHeaderField: "Relay-Access"), password, path)
        }
        XCTAssertNil(try RelayGroups(config: ["url": "wss://relay.example/relay/v1/ws"]).makeRequest("GET", "/group").value(forHTTPHeaderField: "Relay-Access"))
        XCTAssertThrowsError(try RelayGroups(config: ["url": "wss://relay.example/relay/v1/ws", "password": "bad pass word"]).makeRequest("GET", "/group"))
    }
    func testInvitationEndpointPasswordOnlyForOwnRelay() throws {
        let own = "wss://relay.example/relay/v1/ws"
        let groups = RelayGroups(config: ["url": own, "token": "t", "password": password])
        XCTAssertEqual(try RelayGroups(config: groups.invitationEndpointConfig(own)).makeRequest("GET", "/enroll/a/link").value(forHTTPHeaderField: "Relay-Access"), password)
        XCTAssertNil(try RelayGroups(config: groups.invitationEndpointConfig("wss://other.example/relay/v1/ws")).makeRequest("GET", "/enroll/a/link").value(forHTTPHeaderField: "Relay-Access"))
    }
    func testLinkPasswordWinsAndJoinStoresIt() async throws {
        let own = "wss://relay.example/relay/v1/ws", other = "wss://other.example/relay/v1/ws"
        let groups = RelayGroups(config: ["url": own, "token": "t", "password": password])
        XCTAssertEqual(groups.invitationEndpointConfig(other, linkPassword: "link-pass-1")["password"] as? String, "link-pass-1")
        XCTAssertEqual(groups.invitationEndpointConfig(own, linkPassword: "link-pass-1")["password"] as? String, "link-pass-1")
        // join validates and stores the link password before any network request (invalid ones rejected without contacting the relay).
        let joiner = RelayGroups(config: ["url": own, "app": "example", "group": "g"])
        let invitation: [String: Any] = ["version": 1, "url": own, "app": "example", "group": "g", "id": "00", "expires": Date().timeIntervalSince1970 + 60, "password": "bad pass"]
        do { try await joiner.join(invitation, name: "x"); XCTFail("expected rejection") } catch {}
        XCTAssertNil(joiner.config["password"])
    }
    func testExplicitOverrideWinsAndEmptyNeverFallsBack() throws {
        let url = "wss://relay.example/relay/v1/ws"
        let groups = RelayGroups(config: ["url": url, "password": "saved-password"])
        let changed = groups.invitationEndpointConfig(url, linkPassword: "link-password", passwordOverride: "typed-password")
        XCTAssertEqual(try RelayGroups(config: changed).makeRequest("GET", "/enroll/a/link").value(forHTTPHeaderField: "Relay-Access"), "typed-password")
        let cleared = groups.invitationEndpointConfig(url, linkPassword: "link-password", passwordOverride: "")
        XCTAssertEqual(cleared["password"] as? String, "")
        XCTAssertThrowsError(try RelayGroups(config: cleared).makeRequest("GET", "/enroll/a/link"))
        let untouched = groups.invitationEndpointConfig(url, linkPassword: "link-password")
        XCTAssertEqual(untouched["password"] as? String, "link-password")
    }
    func testFilesHeaderAndValidation() async throws {
        let files = try RelayFiles(base: URL(string: "https://relay.example/relay/v1/files")!, token: "t", password: password)
        let req = await files.makeRequest("PUT", path: "x/data", body: Data(), headers: ["Upload-Offset": "0"])
        XCTAssertEqual(req.value(forHTTPHeaderField: "Relay-Access"), password)
        await files.close()
        XCTAssertThrowsError(try RelayFiles(base: URL(string: "https://relay.example/relay/v1/files")!, token: "t", password: "short"))
    }
}
