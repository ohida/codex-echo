import AppKit

/// Owns the live presentation lifecycle of task rows in native status-item menus.
///
/// A menu rebuild establishes the tracked rows. While the menu is open, this
/// object refreshes elapsed activity text and animated ring images. Closing or
/// rebuilding the menu ends both timer lifecycles and releases the row bindings.
@MainActor
final class StatusMenuTaskUpdater {
  private final class Binding {
    let item: NSMenuItem
    var task: TaskPresentation
    var isAvailable = true

    init(item: NSMenuItem, task: TaskPresentation) {
      self.item = item
      self.task = task
    }
  }

  private let shouldReduceMotion: () -> Bool
  private weak var activeMenu: NSMenu?
  private var currentTasks: [TaskPresentation] = []
  private var bindings: [Binding] = []
  private var ringAnimationTimer: Timer?
  private var taskInformationTimer: Timer?
  private(set) var ringPhase = WorkerCrewMotion.reducedMotionPhase
  #if DEBUG
    private(set) var animationFrameCount = 0
  #endif

  var trackedTaskCount: Int { bindings.count }
  var isRefreshingTaskInformation: Bool { taskInformationTimer != nil }
  var isAnimatingTaskRings: Bool { ringAnimationTimer != nil }

  #if DEBUG
    var activitySummaries: [String] {
      if #available(macOS 14.4, *) {
        return bindings.map { $0.item.subtitle ?? "" }
      }
      return []
    }
  #endif

  init() {
    shouldReduceMotion = Self.systemShouldReduceMotion
  }

  init(
    shouldReduceMotion: @escaping () -> Bool
  ) {
    self.shouldReduceMotion = shouldReduceMotion
  }

  func prepareForMenuRebuild(
    _ menu: NSMenu,
    currentTasks: [TaskPresentation],
    relativeTo now: Date = Date()
  ) {
    stopRingAnimation()
    stopTaskInformationUpdates()
    bindings.removeAll()
    activeMenu = menu
    self.currentTasks = currentTasks
    ringPhase = WorkerCrewMotion.phase(
      for: now,
      reduceMotion: shouldReduceMotion()
    )
  }

  func track(_ item: NSMenuItem, presenting task: TaskPresentation) {
    item.image = MenuTaskRingImage.render(
      task: task,
      phase: ringPhase,
      reduceMotion: shouldReduceMotion()
    )
    bindings.append(Binding(item: item, task: task))
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard menu === activeMenu else { return }
    refresh(currentTasks: currentTasks)
    startTaskInformationUpdates()
  }

  @discardableResult
  func menuDidClose(_ menu: NSMenu) -> Bool {
    guard menu === activeMenu else { return false }
    stopRingAnimation()
    stopTaskInformationUpdates()
    bindings.removeAll()
    currentTasks.removeAll()
    activeMenu = nil
    return true
  }

  func refresh(
    currentTasks: [TaskPresentation],
    relativeTo now: Date = Date()
  ) {
    self.currentTasks = currentTasks
    guard !bindings.isEmpty else { return }
    let tasksByID = Dictionary(uniqueKeysWithValues: currentTasks.map { ($0.id, $0) })
    var needsMenuUpdate = false

    for binding in bindings {
      guard let task = tasksByID[binding.task.id] else {
        binding.isAvailable = false
        if binding.item.isEnabled {
          binding.item.isEnabled = false
          if #available(macOS 14.4, *) {
            binding.item.subtitle = "No Longer Available"
          }
          needsMenuUpdate = true
        }
        continue
      }

      binding.isAvailable = true
      if !binding.item.isEnabled {
        binding.item.isEnabled = true
        needsMenuUpdate = true
      }
      let displayedTitle = TaskMenuTextPolicy.displayedTitle(task.title)
      let fullTitleChanged = binding.task.title != task.title
      if binding.item.title != displayedTitle || fullTitleChanged {
        TaskMenuTextPolicy.configureTaskTitle(task.title, on: binding.item)
        needsMenuUpdate = true
      }

      let ringChanged =
        binding.task.state != task.state
        || binding.task.activeSubagentCount != task.activeSubagentCount
        || binding.task.isUnread != task.isUnread
        || binding.task.effectiveColor != task.effectiveColor
      binding.task = task
      if ringChanged {
        binding.item.image = MenuTaskRingImage.render(
          task: task,
          phase: WorkerCrewMotion.phase(
            for: now,
            reduceMotion: shouldReduceMotion()
          ),
          reduceMotion: shouldReduceMotion()
        )
        needsMenuUpdate = true
      }

      if #available(macOS 14.4, *) {
        let subtitle = TaskMenuTextPolicy.displayedSubtitle(
          task.menuActivitySummary(relativeTo: now)
        )
        if binding.item.subtitle != subtitle {
          binding.item.subtitle = subtitle
          needsMenuUpdate = true
        }
      }
    }

    reconcileRingAnimation()
    if needsMenuUpdate, let activeMenu {
      activeMenu.update()
    }
  }

  private func startTaskInformationUpdates() {
    stopTaskInformationUpdates()
    guard !bindings.isEmpty else { return }

    let timer = Timer(
      timeInterval: TaskActivityPresentationTiming.elapsedRefreshInterval,
      repeats: true
    ) { [weak self] timer in
      if self == nil {
        timer.invalidate()
        return
      }
      MainActor.assumeIsolated {
        self?.taskInformationTimerFired()
      }
    }
    timer.tolerance = 1
    RunLoop.main.add(timer, forMode: .eventTracking)
    RunLoop.main.add(timer, forMode: .common)
    taskInformationTimer = timer
  }

  private func stopTaskInformationUpdates() {
    taskInformationTimer?.invalidate()
    taskInformationTimer = nil
  }

  private func taskInformationTimerFired() {
    refresh(currentTasks: currentTasks, relativeTo: Date())
  }

  private func reconcileRingAnimation() {
    let shouldAnimate = WorkerCrewMotion.shouldAnimate(
      tasks: bindings.filter(\.isAvailable).map(\.task),
      reduceMotion: shouldReduceMotion()
    )
    guard shouldAnimate else {
      stopRingAnimation()
      return
    }
    guard ringAnimationTimer == nil else { return }

    #if DEBUG
      animationFrameCount = 0
    #endif

    let timer = Timer(
      timeInterval: 1.0 / 30.0,
      repeats: true
    ) { [weak self] timer in
      if self == nil {
        timer.invalidate()
        return
      }
      MainActor.assumeIsolated {
        self?.ringAnimationTimerFired()
      }
    }
    timer.tolerance = 1.0 / 120.0
    RunLoop.main.add(timer, forMode: .eventTracking)
    RunLoop.main.add(timer, forMode: .common)
    ringAnimationTimer = timer
  }

  private func stopRingAnimation() {
    ringAnimationTimer?.invalidate()
    ringAnimationTimer = nil
  }

  private func ringAnimationTimerFired() {
    guard !shouldReduceMotion() else {
      stopRingAnimation()
      return
    }

    let phase = Date().timeIntervalSinceReferenceDate
    for binding in bindings
    where binding.isAvailable && WorkerCrewMotion.isAnimated(binding.task) {
      binding.item.image = MenuTaskRingImage.render(
        task: binding.task,
        phase: phase,
        reduceMotion: false
      )
    }
    #if DEBUG
      animationFrameCount += 1
      if ProcessInfo.processInfo.environment["CODEX_ECHO_DEBUG_EVENTS"] == "1",
        [1, 10, 20].contains(animationFrameCount)
      {
        let animatedCount = bindings.filter {
          $0.isAvailable && WorkerCrewMotion.isAnimated($0.task)
        }.count
        print(
          "MENU_RING_ANIMATION_FRAME frame=\(animationFrameCount) "
            + "animated=\(animatedCount)"
        )
      }
      if ProcessInfo.processInfo.environment[
        "CODEX_ECHO_DEBUG_CLOSE_MENU_AFTER_ANIMATION"
      ] == "1", animationFrameCount == 36 {
        activeMenu?.cancelTracking()
      }
    #endif
  }

  private static func systemShouldReduceMotion() -> Bool {
    #if DEBUG
      if ProcessInfo.processInfo.environment[
        "CODEX_ECHO_DEBUG_REDUCE_MOTION"
      ] == "1" {
        return true
      }
    #endif
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
}
