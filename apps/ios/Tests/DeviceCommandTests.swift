import XCTest

@testable import PasswordVault

/// Port of Android's `DeviceCommandTest.kt`.
final class DeviceCommandTests: XCTestCase {
  private func device(_ pairs: [String: JSONValue]) -> [String: JSONValue] {
    pairs.merging(["version": .number(1)]) { current, _ in current }
  }

  func testBuildsSshCommandWithUserHostAndNonDefaultPort() {
    XCTAssertEqual(DeviceCommand.ssh(device(["host": .string("server.example.test"), "port": .number(2222), "username": .string("deploy")])), "ssh -p 2222 deploy@server.example.test")
    XCTAssertEqual(DeviceCommand.ssh(device(["host": .string("10.0.0.5"), "port": .number(22), "username": .string("deploy")])), "ssh deploy@10.0.0.5")
    XCTAssertEqual(DeviceCommand.ssh(device(["host": .string("host.example.test")])), "ssh host.example.test")
  }

  func testNeverIncludesSecrets() throws {
    let command = try XCTUnwrap(DeviceCommand.ssh(device([
      "host": .string("server.example.test"), "username": .string("deploy"),
      "password": .string("SYNTHETIC-PASSWORD-CANARY"), "privateKey": .string("SYNTHETIC-KEY-CANARY"), "notes": .string("NOTE-CANARY"),
    ])))
    XCTAssertFalse(command.contains("CANARY"))
  }

  func testRejectsUnusableOrOptionLikeValues() {
    XCTAssertNil(DeviceCommand.ssh(nil))
    XCTAssertNil(DeviceCommand.ssh(["version": .number(2), "host": .string("a.example")]))
    XCTAssertNil(DeviceCommand.ssh(device(["host": .string("")])))
    XCTAssertNil(DeviceCommand.ssh(device(["host": .string("-oProxyCommand=evil")])))
    XCTAssertNil(DeviceCommand.ssh(device(["host": .string("a.example; rm -rf /")])))
    // An unsafe username is dropped rather than passed to the shell.
    XCTAssertEqual(DeviceCommand.ssh(device(["host": .string("a.example"), "username": .string("-oProxyCommand=x")])), "ssh a.example")
    XCTAssertEqual(DeviceCommand.ssh(device(["host": .string("a.example"), "username": .string("bad user")])), "ssh a.example")
    XCTAssertEqual(DeviceCommand.ssh(device(["host": .string("a.example"), "port": .number(70000)])), "ssh a.example")
  }

  func testOnlyVersionOneIsReadable() {
    XCTAssertTrue(DeviceRecord.readable(["version": .number(1)]))
    XCTAssertFalse(DeviceRecord.readable(["version": .number(2)]))
    XCTAssertFalse(DeviceRecord.readable(["version": .string("1")]))
    XCTAssertFalse(DeviceRecord.readable(nil))
    XCTAssertEqual(DeviceRecord.portText(.number(2222)), "2222")
  }
}
