import Foundation

@MainActor
final class CrewRingStateStore {
  static let orderKey = "crewOrderV1"
  static let hiddenTaskIDsKey = "hiddenCrewTaskIDs"
  static let manuallyShownTaskIDsKey = "manuallyShownCrewTaskIDs"

  private let userDefaults: UserDefaults
  private(set) var preferredTaskIDs: [String]
  private var hiddenTaskIDs: Set<String>
  private var manuallyShownTaskIDs: Set<String>

  init(userDefaults: UserDefaults) {
    self.userDefaults = userDefaults
    self.preferredTaskIDs = CrewRingOrderPersistence.load(
      from: userDefaults,
      key: Self.orderKey
    )
    self.hiddenTaskIDs = Set(
      userDefaults.stringArray(forKey: Self.hiddenTaskIDsKey) ?? []
    )
    self.manuallyShownTaskIDs = Set(
      userDefaults.stringArray(forKey: Self.manuallyShownTaskIDsKey) ?? []
    )
  }

  func isHidden(_ taskID: String) -> Bool {
    hiddenTaskIDs.contains(taskID)
  }

  func shouldDisplay(_ taskID: String, showsByDefault: Bool) -> Bool {
    (showsByDefault || manuallyShownTaskIDs.contains(taskID))
      && !hiddenTaskIDs.contains(taskID)
  }

  func hide(_ taskID: String) {
    manuallyShownTaskIDs.remove(taskID)
    hiddenTaskIDs.insert(taskID)
    persistHiddenTaskIDs()
    persistManuallyShownTaskIDs()
  }

  func orderedTaskIDs(for displayedTaskIDs: [String]) -> [String] {
    let updatedTaskIDs = CrewRingOrderPolicy.appendingMissing(
      taskIDs: displayedTaskIDs,
      to: preferredTaskIDs
    )
    if updatedTaskIDs != preferredTaskIDs {
      setPreferredTaskIDs(updatedTaskIDs)
    }

    let displayedTaskIDSet = Set(displayedTaskIDs)
    return preferredTaskIDs.filter(displayedTaskIDSet.contains)
  }

  func move(
    _ taskID: String,
    toVisibleIndex destinationIndex: Int,
    visibleTaskIDs: [String],
    displayedTaskIDs: [String]
  ) -> Bool {
    guard let reorderedTaskIDs = CrewRingOrderPolicy.moving(
      taskID: taskID,
      toVisibleIndex: destinationIndex,
      visibleTaskIDs: visibleTaskIDs,
      displayedTaskIDs: displayedTaskIDs,
      preferredTaskIDs: preferredTaskIDs
    ) else { return false }

    setPreferredTaskIDs(reorderedTaskIDs)
    return true
  }

  func addOverflowTaskToVisibleEnd(
    _ taskID: String,
    visibleLimit: Int,
    displayedTaskIDs: [String]
  ) -> Bool {
    guard let reorderedTaskIDs = CrewRingOrderPolicy.addingToVisibleEnd(
      taskID: taskID,
      visibleLimit: visibleLimit,
      displayedTaskIDs: displayedTaskIDs,
      preferredTaskIDs: preferredTaskIDs
    ) else { return false }

    setPreferredTaskIDs(reorderedTaskIDs)
    return true
  }

  func replaceVisibleEnd(
    with taskID: String,
    visibleLimit: Int,
    displayedTaskIDs: [String]
  ) -> Bool {
    guard let reorderedTaskIDs = CrewRingOrderPolicy.replacingVisibleEnd(
      taskID: taskID,
      visibleLimit: visibleLimit,
      displayedTaskIDs: displayedTaskIDs,
      preferredTaskIDs: preferredTaskIDs
    ) else { return false }

    setPreferredTaskIDs(reorderedTaskIDs)
    return true
  }

  func restoreAtEnd(_ taskID: String, wasAutomaticallyHidden: Bool) -> Bool {
    let wasManuallyHidden = hiddenTaskIDs.remove(taskID) != nil
    guard wasManuallyHidden || wasAutomaticallyHidden else { return false }

    preferredTaskIDs = CrewRingOrderPolicy.restoringAtEnd(
      taskID: taskID,
      preferredTaskIDs: preferredTaskIDs
    )
    if wasManuallyHidden { persistHiddenTaskIDs() }
    persistPreferredTaskIDs()
    return true
  }

  func remove(_ taskID: String) {
    if hiddenTaskIDs.remove(taskID) != nil { persistHiddenTaskIDs() }
    if manuallyShownTaskIDs.remove(taskID) != nil { persistManuallyShownTaskIDs() }

    let previousTaskIDs = preferredTaskIDs
    preferredTaskIDs.removeAll { $0 == taskID }
    if preferredTaskIDs != previousTaskIDs { persistPreferredTaskIDs() }
  }

  func retain(taskIDs: Set<String>) {
    let previousHiddenCount = hiddenTaskIDs.count
    hiddenTaskIDs.formIntersection(taskIDs)
    if hiddenTaskIDs.count != previousHiddenCount { persistHiddenTaskIDs() }

    let previousTaskIDs = preferredTaskIDs
    preferredTaskIDs.removeAll { !taskIDs.contains($0) }
    if preferredTaskIDs != previousTaskIDs { persistPreferredTaskIDs() }

    let previousManuallyShownCount = manuallyShownTaskIDs.count
    manuallyShownTaskIDs.formIntersection(taskIDs)
    if manuallyShownTaskIDs.count != previousManuallyShownCount {
      persistManuallyShownTaskIDs()
    }
  }

  // Catalog cleanup historically removes live conversations before comparing the
  // remaining order for persistence. Keep that distinction explicit until a
  // separately reviewed migration can change the on-disk behavior.
  func removeFromCurrentOrder(taskIDs: Set<String>) {
    preferredTaskIDs.removeAll { taskIDs.contains($0) }
  }

  private func setPreferredTaskIDs(_ taskIDs: [String]) {
    preferredTaskIDs = taskIDs
    persistPreferredTaskIDs()
  }

  private func persistPreferredTaskIDs() {
    CrewRingOrderPersistence.save(
      preferredTaskIDs,
      to: userDefaults,
      key: Self.orderKey
    )
  }

  private func persistHiddenTaskIDs() {
    userDefaults.set(Array(hiddenTaskIDs).sorted(), forKey: Self.hiddenTaskIDsKey)
  }

  private func persistManuallyShownTaskIDs() {
    userDefaults.set(
      Array(manuallyShownTaskIDs).sorted(),
      forKey: Self.manuallyShownTaskIDsKey
    )
  }
}

enum CrewRingOrderPersistence {
  static func load(from userDefaults: UserDefaults, key: String) -> [String] {
    userDefaults.stringArray(forKey: key) ?? []
  }

  static func save(_ taskIDs: [String], to userDefaults: UserDefaults, key: String) {
    userDefaults.set(taskIDs, forKey: key)
  }
}
