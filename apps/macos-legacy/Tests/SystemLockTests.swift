import AppKit
import XCTest

@testable import PasswordVault

@MainActor
final class SystemLockTests: XCTestCase {
  private let password = "Synthetic system-lock fixture only!"

  func testLegacyAndMalformedSettingsKeepImmediateLocking() async throws {
    let fixture = await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = fixture.store
    for event in AppStore.SystemLockEvent.allCases {
      for value in [nil, JSONValue.string("false"), .number(0), .bool(true)] {
        store.settings[event.settingKey] = value
        XCTAssertTrue(store.locksOnSystemEvent(event))
        store.handleSystemLockEvent(event)
        XCTAssertFalse(store.unlocked)
        await store.finishLock()
        await store.authenticate(password: password, create: false)
        XCTAssertTrue(store.unlocked)
      }
    }
    store.lock()
    await store.finishLock()
  }

  func testNotificationsRespectIndependentPoliciesAndSessionSwitches() async throws {
    let fixture = await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = fixture.store
    for screenLock in [true, false] {
      for sleep in [true, false] {
        let events: [(NotificationCenter, Notification.Name, Bool)] = [
          (fixture.screen, .init("com.apple.screenIsLocked"), screenLock),
          (fixture.workspace, NSWorkspace.willSleepNotification, sleep),
          (fixture.workspace, NSWorkspace.sessionDidResignActiveNotification, screenLock),
        ]
        for (center, name, shouldLock) in events {
          store.settings["macLockOnScreenLock"] = .bool(screenLock)
          store.settings["macLockOnSleep"] = .bool(sleep)
          center.post(name: name, object: nil)
          await drainNotificationDelivery()
          XCTAssertEqual(store.unlocked, !shouldLock, "Unexpected policy for \(name.rawValue)")
          if shouldLock {
            await store.finishLock()
            await store.authenticate(password: password, create: false)
            XCTAssertTrue(store.unlocked)
          }
        }
      }
    }
    store.lock()
    await store.finishLock()
  }

  func testSleepFollowedByScreenLockAppliesBothPolicies() async throws {
    let fixture = await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = fixture.store
    store.settings["macLockOnSleep"] = .bool(false)
    store.settings["macLockOnScreenLock"] = .bool(true)
    store.handleSystemLockEvent(.sleep)
    XCTAssertTrue(store.unlocked)
    store.handleSystemLockEvent(.screenLock)
    XCTAssertFalse(store.unlocked)
    await store.finishLock()
  }

  func testOptOutPersistsAndDoesNotDisableManualOrIdleLock() async throws {
    let fixture = await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = fixture.store
    store.settings["macLockOnScreenLock"] = .bool(false)
    store.settings["macLockOnSleep"] = .bool(false)
    store.settings["macNeverIdleLock"] = .bool(false)
    store.settings["autoLockMinutes"] = .number(1)
    let saved = await store.saveSettings()
    XCTAssertTrue(saved)
    store.handleSystemLockEvent(.screenLock)
    store.handleSystemLockEvent(.sleep)
    XCTAssertTrue(store.unlocked)
    store.lock()
    XCTAssertFalse(store.unlocked)
    await store.finishLock()
    await store.authenticate(password: password, create: false)
    XCTAssertFalse(store.locksOnSystemEvent(.screenLock))
    XCTAssertFalse(store.locksOnSystemEvent(.sleep))
    let start = Date()
    store.recordBrowserActivity(now: start)
    store.checkIdleLock(now: start.addingTimeInterval(61))
    XCTAssertFalse(store.unlocked)
    await store.finishLock()
  }

  func testFailedSaveRestoresPersistedLockPolicy() async throws {
    let fixture = await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = fixture.store
    store.settings["macLockOnScreenLock"] = .bool(false)
    store.settings["macLockOnSleep"] = .bool(false)
    store.settings["autoLockMinutes"] = .number(0)  // Rejected by the core, no disk write.
    let saved = await store.saveSettings()
    XCTAssertFalse(saved)
    XCTAssertNotNil(store.error)
    XCTAssertTrue(store.locksOnSystemEvent(.screenLock))
    XCTAssertTrue(store.locksOnSystemEvent(.sleep))
    store.handleSystemLockEvent(.sleep)
    XCTAssertFalse(store.unlocked)
    await store.finishLock()
  }

  func testImmediateSystemLockRetainsLatestUnsavedNote() async throws {
    let fixture = await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let store = fixture.store
    var note = VaultItem.blank(type: "secureNote", title: "System-lock fixture")
    try await store.saveRecord(note)
    note.note = "Synthetic final input before sleep"
    store.editNote(note)
    store.handleSystemLockEvent(.sleep)
    XCTAssertFalse(store.unlocked)
    XCTAssertTrue(store.items.isEmpty)
    await store.finishLock()
    await store.authenticate(password: password, create: false)
    XCTAssertEqual(store.items.first?.note, note.note)
    store.lock()
    await store.finishLock()
  }

  private func drainNotificationDelivery() async {
    // A run-loop barrier delivers receive(on: RunLoop.main) without wall-clock sleeps.
    let delivered = expectation(description: "System notification delivered")
    RunLoop.main.perform { delivered.fulfill() }
    await fulfillment(of: [delivered], timeout: 5)
  }

  private func makeFixture() async -> (
    store: AppStore, folder: URL, screen: NotificationCenter, workspace: NotificationCenter
  ) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let screen = NotificationCenter()
    let workspace = NotificationCenter()
    let store = AppStore(
      directory: folder, screenNotifications: screen, workspaceNotifications: workspace)
    await store.authenticate(password: password, create: true)
    XCTAssertTrue(store.unlocked)
    return (store, folder, screen, workspace)
  }
}
