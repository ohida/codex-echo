import XCTest

@testable import CodexEcho

final class CrewRingStateStoreTests: XCTestCase {
  @MainActor
  func testLoadsTheExistingProductionKeysWithoutChangingTheirRepresentation() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["two", "one", "two"], forKey: "crewOrderV1")
    defaults.set(["hidden", "hidden"], forKey: "hiddenCrewTaskIDs")
    defaults.set(["manual", "manual"], forKey: "manuallyShownCrewTaskIDs")

    let store = CrewRingStateStore(userDefaults: defaults)

    XCTAssertEqual(CrewRingStateStore.orderKey, "crewOrderV1")
    XCTAssertEqual(CrewRingStateStore.hiddenTaskIDsKey, "hiddenCrewTaskIDs")
    XCTAssertEqual(
      CrewRingStateStore.manuallyShownTaskIDsKey,
      "manuallyShownCrewTaskIDs"
    )
    XCTAssertEqual(store.preferredTaskIDs, ["two", "one", "two"])
    XCTAssertTrue(store.isHidden("hidden"))
    XCTAssertTrue(store.shouldDisplay("manual", showsByDefault: false))
  }

  @MainActor
  func testHideAtomicallyClearsManualShowAndPersistsHiddenPreference() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["task"], forKey: "manuallyShownCrewTaskIDs")
    let store = CrewRingStateStore(userDefaults: defaults)

    store.hide("task")

    XCTAssertTrue(store.isHidden("task"))
    XCTAssertFalse(store.shouldDisplay("task", showsByDefault: true))
    XCTAssertEqual(defaults.stringArray(forKey: "hiddenCrewTaskIDs"), ["task"])
    XCTAssertEqual(defaults.stringArray(forKey: "manuallyShownCrewTaskIDs"), [])

    let restoredStore = CrewRingStateStore(userDefaults: defaults)
    XCTAssertTrue(restoredStore.isHidden("task"))
    XCTAssertFalse(restoredStore.shouldDisplay("task", showsByDefault: true))
  }

  @MainActor
  func testOrderingAppendsDisplayedTasksWithoutDiscardingRememberedHiddenSlots() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["hidden", "two"], forKey: "crewOrderV1")
    let store = CrewRingStateStore(userDefaults: defaults)

    let orderedTaskIDs = store.orderedTaskIDs(for: ["one", "two"])

    XCTAssertEqual(orderedTaskIDs, ["two", "one"])
    XCTAssertEqual(store.preferredTaskIDs, ["hidden", "two", "one"])
    XCTAssertEqual(
      defaults.stringArray(forKey: "crewOrderV1"),
      ["hidden", "two", "one"]
    )
  }

  @MainActor
  func testMoveAndOverflowOperationsPersistTheirSuccessfulOrderOnly() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["one", "two", "three", "four"], forKey: "crewOrderV1")
    let store = CrewRingStateStore(userDefaults: defaults)

    XCTAssertTrue(
      store.move(
        "one",
        toVisibleIndex: 1,
        visibleTaskIDs: ["one", "two"],
        displayedTaskIDs: ["one", "two", "three", "four"]
      )
    )
    XCTAssertEqual(store.preferredTaskIDs, ["two", "one", "three", "four"])

    XCTAssertTrue(
      store.addOverflowTaskToVisibleEnd(
        "four",
        visibleLimit: 2,
        displayedTaskIDs: ["two", "one", "three", "four"]
      )
    )
    XCTAssertEqual(store.preferredTaskIDs, ["two", "one", "four", "three"])

    XCTAssertTrue(
      store.replaceVisibleEnd(
        with: "three",
        visibleLimit: 2,
        displayedTaskIDs: ["two", "one", "four", "three"]
      )
    )
    XCTAssertEqual(store.preferredTaskIDs, ["two", "three", "one", "four"])
    XCTAssertEqual(
      defaults.stringArray(forKey: "crewOrderV1"),
      ["two", "three", "one", "four"]
    )

    XCTAssertFalse(
      store.move(
        "missing",
        toVisibleIndex: 0,
        visibleTaskIDs: ["two", "three"],
        displayedTaskIDs: ["two", "three", "one", "four"]
      )
    )
    XCTAssertEqual(
      defaults.stringArray(forKey: "crewOrderV1"),
      ["two", "three", "one", "four"]
    )
  }

  @MainActor
  func testRestoreMovesAHiddenOrAutomaticallyHiddenTaskToTheEnd() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["hidden"], forKey: "hiddenCrewTaskIDs")
    defaults.set(["hidden", "one", "automatic"], forKey: "crewOrderV1")
    let store = CrewRingStateStore(userDefaults: defaults)

    XCTAssertTrue(store.restoreAtEnd("hidden", wasAutomaticallyHidden: false))
    XCTAssertFalse(store.isHidden("hidden"))
    XCTAssertEqual(store.preferredTaskIDs, ["one", "automatic", "hidden"])
    XCTAssertEqual(defaults.stringArray(forKey: "hiddenCrewTaskIDs"), [])

    XCTAssertTrue(store.restoreAtEnd("automatic", wasAutomaticallyHidden: true))
    XCTAssertEqual(store.preferredTaskIDs, ["one", "hidden", "automatic"])
    XCTAssertEqual(
      defaults.stringArray(forKey: "crewOrderV1"),
      ["one", "hidden", "automatic"]
    )
    XCTAssertFalse(store.restoreAtEnd("one", wasAutomaticallyHidden: false))
  }

  @MainActor
  func testRetainAndRemovePruneEveryOwnedPreferenceUsingExistingKeys() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["stale", "hidden", "visible"], forKey: "crewOrderV1")
    defaults.set(["stale", "hidden"], forKey: "hiddenCrewTaskIDs")
    defaults.set(["stale", "manual"], forKey: "manuallyShownCrewTaskIDs")
    let store = CrewRingStateStore(userDefaults: defaults)

    store.retain(taskIDs: Set(["hidden", "visible", "manual"]))

    XCTAssertEqual(store.preferredTaskIDs, ["hidden", "visible"])
    XCTAssertEqual(defaults.stringArray(forKey: "hiddenCrewTaskIDs"), ["hidden"])
    XCTAssertEqual(defaults.stringArray(forKey: "manuallyShownCrewTaskIDs"), ["manual"])
    XCTAssertEqual(defaults.stringArray(forKey: "crewOrderV1"), ["hidden", "visible"])

    store.remove("hidden")

    XCTAssertFalse(store.isHidden("hidden"))
    XCTAssertEqual(store.preferredTaskIDs, ["visible"])
    XCTAssertEqual(defaults.stringArray(forKey: "hiddenCrewTaskIDs"), [])
    XCTAssertEqual(defaults.stringArray(forKey: "crewOrderV1"), ["visible"])
  }

  @MainActor
  func testCurrentOrderRemovalPreservesTheExistingNonPersistentCatalogContract() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["removed", "kept"], forKey: "crewOrderV1")
    let store = CrewRingStateStore(userDefaults: defaults)

    store.removeFromCurrentOrder(taskIDs: Set(["removed"]))
    store.retain(taskIDs: Set(["kept"]))

    XCTAssertEqual(store.preferredTaskIDs, ["kept"])
    XCTAssertEqual(defaults.stringArray(forKey: "crewOrderV1"), ["removed", "kept"])
  }

  private func makeDefaults() throws -> (UserDefaults, String) {
    let suiteName = "CrewRingStateStoreTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }
}
