import AppKit
import CodexIPC
import Combine
import SwiftUI

enum StatusItemClickIntent: Equatable {
  case openTask
  case showMenu
  case showOverflowMenu
}

enum MenuBarConfigurationElement: Equatable {
  case tasksOnMenuBar
  case codexCapacity
  case speakAnnouncements
}

enum MenuBarConfigurationPolicy {
  static let elements: [MenuBarConfigurationElement] = [
    .codexCapacity,
    .speakAnnouncements,
    .tasksOnMenuBar,
  ]
}

enum TaskCustomizationMenuElement: Equatable {
  case color
  case voice
}

enum TaskCustomizationMenuScope: Equatable {
  case project
  case task
}

enum TaskCustomizationMenuPolicy {
  static func elements(speaksAnnouncements: Bool) -> [TaskCustomizationMenuElement] {
    speaksAnnouncements ? [.color, .voice] : [.color]
  }

  static func scopes(hasParentScope: Bool) -> [TaskCustomizationMenuScope] {
    hasParentScope ? [.project, .task] : [.task]
  }
}

enum TaskCustomizationInheritancePolicy {
  static func colorTitle(
    for identity: TaskProjectIdentity?
  ) -> String? {
    switch identity {
    case .project: "Use Project Color"
    case .noProject: "Use No Project Color"
    case nil: nil
    }
  }

  static func voiceTitle(
    for identity: TaskProjectIdentity?
  ) -> String? {
    switch identity {
    case .project: "Use Project Voice"
    case .noProject: "Use No Project Voice"
    case nil: nil
    }
  }
}

enum StatusItemClickTarget: Equatable {
  case task
  case overflow
  case background
}

enum StatusItemMenuPresentationPolicy {
  @MainActor
  static func schedule(_ presentation: @escaping @MainActor () -> Void) {
    // Pointer dispatch must finish before AppKit starts native menu tracking.
    DispatchQueue.main.async {
      presentation()
    }
  }
}

struct StatusItemActionEventIdentity: Equatable {
  let eventNumber: Int
  let timestamp: TimeInterval
}

enum StatusItemSecondaryActionPolicy {
  static func canReadIdentity(for eventType: NSEvent.EventType) -> Bool {
    eventType == .rightMouseUp
  }

  static func shouldHandle(
    eventType: NSEvent.EventType,
    identity: StatusItemActionEventIdentity,
    lastHandledIdentity: StatusItemActionEventIdentity?
  ) -> Bool {
    canReadIdentity(for: eventType) && identity != lastHandledIdentity
  }
}

enum StatusItemClickPolicy {
  static func intent(
    isSecondaryClick: Bool,
    target: StatusItemClickTarget,
    taskOpenMouseButton: TaskOpenMouseButton = .left
  ) -> StatusItemClickIntent {
    let clickedMouseButton: TaskOpenMouseButton = isSecondaryClick ? .right : .left
    let isTaskOpeningClick = clickedMouseButton == taskOpenMouseButton
    switch target {
    case .task:
      return isTaskOpeningClick ? .openTask : .showMenu
    case .overflow:
      return .showOverflowMenu
    case .background:
      return .showMenu
    }
  }
}

enum StatusItemPrimaryGesturePolicy {
  static func shouldAttemptPan(
    isCommandModified: Bool,
    target: StatusItemClickTarget
  ) -> Bool {
    !isCommandModified && target == .task
  }
}

enum StatusItemContextMenuScope {
  case appScoped
  case task(TaskPresentation)
}

enum StatusItemContextMenuTaskPolicy {
  static func task(
    in tasks: [TaskPresentation],
    scope: StatusItemContextMenuScope
  ) -> TaskPresentation? {
    guard case .task(let clickedTask) = scope else { return nil }
    return tasks.first { $0.id == clickedTask.id }
  }
}

enum TaskMenuTextPolicy {
  static let maximumTextWidth: CGFloat = 320
  static var titleFont: NSFont { NSFont.menuFont(ofSize: 0) }
  static var subtitleFont: NSFont {
    NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
  }

  static func displayedTitle(_ title: String) -> String {
    truncated(title, font: titleFont)
  }

  static func configureTaskTitle(_ title: String, on item: NSMenuItem) {
    item.title = displayedTitle(title)
    item.toolTip = nil
    item.setAccessibilityLabel(title)
  }

  static func displayedSubtitle(_ subtitle: String) -> String {
    truncated(subtitle, font: subtitleFont)
  }

  static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
  }

  private static func truncated(_ text: String, font: NSFont) -> String {
    guard measuredWidth(text, font: font) > maximumTextWidth else { return text }

    let characters = Array(text)
    var lowerBound = 0
    var upperBound = characters.count
    while lowerBound < upperBound {
      let candidateCount = (lowerBound + upperBound + 1) / 2
      let candidate = String(characters.prefix(candidateCount)) + "…"
      if measuredWidth(candidate, font: font) <= maximumTextWidth {
        lowerBound = candidateCount
      } else {
        upperBound = candidateCount - 1
      }
    }

    let prefix = String(characters.prefix(lowerBound))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return prefix + "…"
  }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  private struct TaskColorMenuSelection {
    let taskID: String
    let preference: TaskColorPreference
  }

  private struct ProjectColorMenuSelection {
    let identity: TaskProjectIdentity
    let color: TaskAccentColor?
  }

  private struct TaskVoiceMenuSelection {
    let taskID: String
    let preference: TaskVoicePreference
  }

  private struct ProjectVoiceMenuSelection {
    let identity: TaskProjectIdentity
    let voice: SpokenUpdateVoice?
  }

  private let model: CodexActivityModel
  private let updateChecker: any AppUpdateChecking
  private let previewSpokenUpdate: (SpokenUpdateVoice) -> Void
  private let openCapacityHistory: () -> Void
  private let showDiagnostics: () -> Void
  private let interaction: StatusItemInteractionModel
  private let statusItem: NSStatusItem
  private let contextMenu = NSMenu()
  private let overflowMenu = NSMenu()
  private let menuTaskUpdater = StatusMenuTaskUpdater()
  private let accessibilityController = StatusItemAccessibilityController()
  private let labelView: HoverTrackingHostingView<SignalCoreLabel>
  private let peekController: StatusItemPeekController
  private lazy var gestureController = StatusItemGestureController(
    coordinateView: labelView,
    snapshot: { [weak self] in
      guard let self else {
        return StatusItemGestureController.Snapshot(
          taskIDs: [],
          overflowCount: 0,
          capacityRemainingPercent: nil,
          taskOpenMouseButton: .left
        )
      }
      return StatusItemGestureController.Snapshot(
        taskIDs: model.statusBarTasks.map(\.id),
        overflowCount: model.overflowCrewTasks.count,
        capacityRemainingPercent: displayedCapacityRemainingPercent,
        taskOpenMouseButton: model.settings.taskOpenMouseButton
      )
    },
    onAction: { [weak self] action in
      self?.handleGestureAction(action)
    }
  )
  private var layoutObservation: AnyCancellable?
  private var settingsObservation: AnyCancellable?
  private var usageObservation: AnyCancellable?
  private var pendingContextMenuScope = StatusItemContextMenuScope.appScoped
  private var isPresentingMenu = false
  private var previousDesktopAppRecoveryMenu: CodexDesktopAppRecoveryMenu?

  init(
    model: CodexActivityModel,
    updateChecker: any AppUpdateChecking,
    previewSpokenUpdate: @escaping (SpokenUpdateVoice) -> Void,
    openCapacityHistory: @escaping () -> Void,
    showDiagnostics: @escaping () -> Void
  ) {
    self.model = model
    self.updateChecker = updateChecker
    self.previewSpokenUpdate = previewSpokenUpdate
    self.openCapacityHistory = openCapacityHistory
    self.showDiagnostics = showDiagnostics
    let interaction = StatusItemInteractionModel()
    self.interaction = interaction
    let initialContentWidth = WorkerCrewLayout.contentWidth(
      forDisplayedCrewCount: model.statusBarTasks.count,
      overflowCount: model.overflowCrewTasks.count,
      capacityRemainingPercent:
        model.settings.showsCapacityInMenuBar
        ? model.codexUsageSnapshot?.remainingPercent
        : nil,
      showsHealthBadge: !model.statusBarTasks.isEmpty
        && model.statusPresentation.requiresStatusBadge
    )
    statusItem = NSStatusBar.system.statusItem(withLength: initialContentWidth)
    let labelView = HoverTrackingHostingView(
      rootView: SignalCoreLabel(
        model: model,
        interaction: interaction,
        settings: model.settings
      )
    )
    self.labelView = labelView
    peekController = StatusItemPeekController(
      anchorView: labelView,
      onHoveredTaskIDChange: { [weak interaction] taskID in
        interaction?.hoveredTaskID = taskID
      }
    )
    super.init()
    previousDesktopAppRecoveryMenu = model.statusPresentation.desktopAppRecoveryMenu

    guard let button = statusItem.button else {
      assertionFailure("NSStatusItem did not provide a button")
      return
    }

    button.title = ""
    button.setAccessibilityRole(.group)
    button.setAccessibilityLabel("Codex Tasks")
    button.setAccessibilityHelp("Shows Codex task status and task menus")
    button.toolTip = statusItemToolTip
    button.window?.acceptsMouseMovedEvents = true
    gestureController.install(on: button)
    contextMenu.autoenablesItems = false
    contextMenu.delegate = self
    overflowMenu.autoenablesItems = false
    overflowMenu.delegate = self

    labelView.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(labelView)
    NSLayoutConstraint.activate([
      labelView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
      labelView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
      labelView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      labelView.heightAnchor.constraint(equalToConstant: 22),
    ])
    labelView.onMouseMove = { [weak self] point in self?.updateHover(at: point) }
    labelView.onMouseExit = { [weak self] in self?.clearHover() }
    labelView.setAccessibilityElement(false)
    interaction.openTask = { [weak model] task in model?.openTask(task) }
    interaction.showOverflowMenu = { [weak self, weak button] in
      guard let self, let button else { return }
      self.present(self.overflowMenu, from: button)
    }
    validateLayout(button: button)
    updateAccessibility(button: button)
    layoutObservation = Publishers.CombineLatest4(
      model.$crewTasks,
      model.$ipcConnectionState,
      model.$appServerConnectionState,
      model.$desktopAppState
    )
    .sink { [weak self] _, ipcState, appServerState, desktopAppState in
      let recoveryMenu = CodexStatusPresentationPolicy.resolve(
        desktopAppState: desktopAppState,
        connectionHealth: CodexConnectionHealthPolicy.resolve(
          ipc: ipcState,
          appServer: appServerState
        )
      ).desktopAppRecoveryMenu
      guard let self else { return }
      RunLoop.main.perform(inModes: [.default, .eventTracking]) { [self] in
        MainActor.assumeIsolated {
          cancelTrackedMenusIfDesktopAppRecoveryChanged(to: recoveryMenu)
          updateLayout()
        }
      }
    }
    settingsObservation = model.settings.$maximumVisibleTaskCount
      .combineLatest(model.settings.$showsCapacityInMenuBar)
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.updateLayout() }
    usageObservation = model.$codexUsageSnapshot
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.updateLayout() }
    #if DEBUG
      captureViewsWhenRequested(button: button)
      openMenuWhenRequested(button: button)
      openAboutPanelWhenRequested()
      openSettingsWhenRequested()
      dumpAccessibilityWhenRequested(button: button)
    #endif
  }

  private func updateHover(at point: NSPoint) {
    peekController.updateHover(to: hoverIdentity(at: point)) { [weak self] target in
      self?.peekContent(for: target)
    }
  }

  private func clearHover() {
    peekController.clear()
  }

  private func handleGestureAction(_ action: StatusItemGestureController.Action) {
    switch action {
    case .clearHover:
      clearHover()
    case .openTask(let taskID):
      guard let task = model.statusBarTasks.first(where: { $0.id == taskID }) else { return }
      model.openTask(task)
    case .presentOverflowMenu:
      guard let button = statusItem.button else { return }
      present(overflowMenu, from: button)
    case .presentContextMenu(let taskID):
      guard let button = statusItem.button else { return }
      let task = taskID.flatMap { taskID in
        model.statusBarTasks.first { $0.id == taskID }
      }
      present(contextMenu, from: button, clickedTask: task)
    case .updateDrag(let presentation):
      interaction.ringDrag = presentation
    case .commitDrag(let presentation):
      let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
        _ = model.moveCrewRing(
          taskID: presentation.taskID,
          toVisibleIndex: presentation.destinationIndex
        )
        interaction.ringDrag = nil
      }
    }
  }

  private func hoverIdentity(at point: NSPoint) -> StatusItemPeekTarget? {
    guard labelView.bounds.contains(point) else { return nil }
    let tasks = model.statusBarTasks
    switch StatusItemHoverPolicy.target(
      at: point.x,
      displayedCrewCount: tasks.count,
      overflowCount: model.overflowCrewTasks.count,
      capacityRemainingPercent: displayedCapacityRemainingPercent
    ) {
    case .task(let index) where tasks.indices.contains(index):
      return .task(tasks[index].id)
    case .summary:
      return .summary
    case .task, nil:
      return nil
    }
  }

  private func peekContent(for target: StatusItemPeekTarget) -> StatusItemPeekContent? {
    switch target {
    case .task(let taskID):
      guard
        let index = model.statusBarTasks.firstIndex(where: { $0.id == taskID })
      else { return nil }
      return crewPeekContent(
        for: model.statusBarTasks[index],
        at: index
      )
    case .summary:
      guard let presentation = summaryPeekPresentation else { return nil }
      return summaryPeekContent(presentation)
    }
  }

  private func crewPeekContent(
    for task: TaskPresentation,
    at index: Int
  ) -> StatusItemPeekContent {
    let stride = WorkerCrewLayout.taskStride
    let cellRect = NSRect(
      x: CGFloat(index) * stride,
      y: 0,
      width: WorkerCrewLayout.cellWidth,
      height: labelView.bounds.height
    )
    let hostingController = NSHostingController(rootView: CrewPeekView(task: task))
    return StatusItemPeekContent(
      viewController: hostingController,
      anchorRect: cellRect
    )
  }

  private func summaryPeekContent(
    _ presentation: CrewSummaryPeekPresentation
  ) -> StatusItemPeekContent? {
    guard
      let summaryRange = WorkerCrewLayout.summaryRange(
        displayedCrewCount: model.statusBarTasks.count,
        overflowCount: model.overflowCrewTasks.count,
        capacityRemainingPercent: displayedCapacityRemainingPercent
      )
    else { return nil }
    let summaryRect = NSRect(
      x: summaryRange.lowerBound,
      y: 0,
      width: summaryRange.upperBound - summaryRange.lowerBound,
      height: labelView.bounds.height
    )
    let hostingController = NSHostingController(
      rootView: CrewSummaryPeekView(presentation: presentation)
    )
    return StatusItemPeekContent(
      viewController: hostingController,
      anchorRect: summaryRect
    )
  }

  func menuWillOpen(_ menu: NSMenu) {
    model.requestUsageRefresh()
    if menu === overflowMenu {
      rebuildOverflowMenu(menu)
    } else {
      rebuildContextMenu(menu, scope: pendingContextMenuScope)
    }
    clearHover()
    menuTaskUpdater.menuWillOpen(menu)
    #if DEBUG
      if ProcessInfo.processInfo.environment["CODEX_ECHO_DEBUG_EVENTS"] == "1" {
        if menu === overflowMenu {
          let separatorIndex = menu.items.firstIndex(where: \.isSeparatorItem) ?? -1
          let taskActions = menu.items.compactMap { item in
            item.submenu.map { "\(item.title):\($0.items.map(\.title))" }
          }
          print(
            "STATUS_OVERFLOW_MANAGEMENT_MENU_OPEN "
              + "visible=\(model.statusBarTasks.count) "
              + "overflow=\(model.overflowCrewTasks.count) "
              + "separator=\(separatorIndex) "
              + "titles=\(menu.items.filter { !$0.isSeparatorItem }.map(\.title)) "
              + "actions=\(taskActions)"
          )
          return
        }
        let ringActions = menu.items
          .filter { $0.action == #selector(hideTaskRingFromMenu(_:)) }
          .map(\.title)
        let activitySummaries: [String]
        if #available(macOS 14.4, *) {
          activitySummaries = menuTaskUpdater.activitySummaries
        } else {
          activitySummaries = []
        }
        print(
          "STATUS_MENU_OPEN items=\(menu.items.count) "
            + "tasks=\(model.menuTasks.count) "
            + "rings=\(model.crewTasks.count) "
            + "ringActions=\(ringActions) "
            + "titles=\(menu.items.filter { !$0.isSeparatorItem }.map(\.title)) "
            + "enabled=\(menu.items.filter { !$0.isSeparatorItem }.map { "\($0.title):\($0.isEnabled)" }) "
            + "activity=\(activitySummaries)"
        )
      }
    #endif
  }

  func menuDidClose(_ menu: NSMenu) {
    #if DEBUG
      let wasUpdatingTaskInfo = menuTaskUpdater.isRefreshingTaskInformation
    #endif
    guard menuTaskUpdater.menuDidClose(menu) else { return }
    #if DEBUG
      if ProcessInfo.processInfo.environment["CODEX_ECHO_DEBUG_EVENTS"] == "1" {
        print(
          "MENU_RING_ANIMATION_STOP frames=\(menuTaskUpdater.animationFrameCount) "
            + "taskInfo=\(wasUpdatingTaskInfo ? "stopped" : "inactive")"
        )
      }
      if ProcessInfo.processInfo.environment[
        "CODEX_ECHO_DEBUG_CLOSE_MENU_AFTER_ANIMATION"
      ] == "1" {
        NSApplication.shared.terminate(nil)
      }
    #endif
  }

  private func rebuildContextMenu(
    _ menu: NSMenu,
    scope: StatusItemContextMenuScope
  ) {
    resetTaskMenu(menu)
    let contextualTask = StatusItemContextMenuTaskPolicy.task(
      in: model.menuTasks,
      scope: scope
    )

    if let recoveryMenu = model.statusPresentation.desktopAppRecoveryMenu {
      addDesktopAppRecoveryMenu(recoveryMenu, to: menu)
    } else if let contextualTask {
      addTaskMenuItem(for: contextualTask, to: menu)
      addRingActions(for: contextualTask, to: menu)
      addTaskCustomizationConfiguration(for: contextualTask, to: menu)
    } else if model.menuTasks.isEmpty
      && model.statusPresentation.showsAuthoritativeEmptyTaskState
    {
      let emptyItem = NSMenuItem(title: "No Active or Recent Tasks", action: nil, keyEquivalent: "")
      emptyItem.image = Self.menuImage(systemName: "checkmark.circle", description: "No tasks")
      emptyItem.isEnabled = false
      menu.addItem(emptyItem)
    }

    addMenuBarConfiguration(to: menu)
    addApplicationMenuFooter(to: menu)
  }

  private func addDesktopAppRecoveryMenu(
    _ recoveryMenu: CodexDesktopAppRecoveryMenu,
    to menu: NSMenu
  ) {
    let statusItem = NSMenuItem(
      title: recoveryMenu.statusTitle,
      action: nil,
      keyEquivalent: ""
    )
    statusItem.image = Self.menuImage(
      systemName: recoveryMenu.statusSymbolName,
      description: recoveryMenu.statusTitle
    )
    statusItem.isEnabled = false
    menu.addItem(statusItem)

    if let actionTitle = recoveryMenu.actionTitle {
      let actionItem = NSMenuItem(
        title: actionTitle,
        action: #selector(openCodex(_:)),
        keyEquivalent: ""
      )
      actionItem.target = self
      if let actionSymbolName = recoveryMenu.actionSymbolName {
        actionItem.image = Self.menuImage(
          systemName: actionSymbolName,
          description: actionTitle
        )
      }
      menu.addItem(actionItem)
    }
  }

  private func addApplicationMenuFooter(to menu: NSMenu) {
    if model.statusPresentation.desktopAppRecoveryMenu == nil
      && model.statusPresentation.showsMenuStatus
    {
      menu.addItem(.separator())
      let connectionItem = NSMenuItem(
        title: model.statusPresentation.menuStatusTitle,
        action: nil,
        keyEquivalent: ""
      )
      connectionItem.image = Self.menuImage(
        systemName: model.statusPresentation.menuStatusSymbolName,
        description: model.statusPresentation.menuStatusTitle
      )
      connectionItem.isEnabled = false
      menu.addItem(connectionItem)
    }

    menu.addItem(.separator())
    for element in AppMenuFooterPolicy.elements(
      canCheckForUpdates: updateChecker.canCheckForUpdates,
      canOpenSettings: interaction.openSettings != nil
    ) {
      switch element {
      case .separator:
        menu.addItem(.separator())
      case .item(let descriptor):
        let item = NSMenuItem(
          title: descriptor.title,
          action: selector(for: descriptor.action),
          keyEquivalent: descriptor.keyEquivalent
        )
        item.target = self
        Self.configureApplicationMenuItem(item, from: descriptor)
        menu.addItem(item)
      }
    }
  }

  static func configureApplicationMenuItem(
    _ item: NSMenuItem,
    from descriptor: AppMenuFooterItem
  ) {
    if let systemSymbolName = descriptor.systemSymbolName {
      item.image = menuImage(
        systemName: systemSymbolName,
        description: descriptor.title
      )
    }
    item.isAlternate = descriptor.isAlternate
    if descriptor.isAlternate {
      item.keyEquivalentModifierMask = [.option]
    } else if !descriptor.keyEquivalent.isEmpty {
      item.keyEquivalentModifierMask = [.command]
    }
    item.isEnabled = descriptor.isEnabled
  }

  private func selector(for action: AppMenuFooterAction) -> Selector {
    switch action {
    case .about:
      #selector(showAboutPanel(_:))
    case .showDiagnostics:
      #selector(showDiagnosticsWindow(_:))
    case .checkForUpdates:
      #selector(checkForUpdates(_:))
    case .settings:
      #selector(openSettings(_:))
    case .quit:
      #selector(quitApplication(_:))
    }
  }

  private func rebuildOverflowMenu(_ menu: NSMenu) {
    resetTaskMenu(menu)
    if let recoveryMenu = model.statusPresentation.desktopAppRecoveryMenu {
      addDesktopAppRecoveryMenu(recoveryMenu, to: menu)
      addMenuBarConfiguration(to: menu)
      addApplicationMenuFooter(to: menu)
      return
    }
    let overflowTasks = model.overflowCrewTasks

    if !overflowTasks.isEmpty {
      menu.addItem(.sectionHeader(title: "More Tasks"))
      for task in overflowTasks {
        menu.addItem(overflowTaskMenuItem(for: task))
      }
    }

    if overflowTasks.isEmpty {
      let emptyItem = NSMenuItem(title: "No Tasks in Menu Bar", action: nil, keyEquivalent: "")
      emptyItem.isEnabled = false
      menu.addItem(emptyItem)
    }

    addMenuBarConfiguration(to: menu)
    addApplicationMenuFooter(to: menu)
  }

  private func resetTaskMenu(_ menu: NSMenu) {
    menuTaskUpdater.prepareForMenuRebuild(
      menu,
      currentTasks: model.menuTasks
    )
    menu.removeAllItems()
    menu.autoenablesItems = false
  }

  private func overflowTaskMenuItem(for task: TaskPresentation) -> NSMenuItem {
    let submenu = NSMenu(title: task.title)
    submenu.autoenablesItems = false

    let openItem = NSMenuItem(
      title: "Open in Codex",
      action: #selector(openTaskFromMenu(_:)),
      keyEquivalent: ""
    )
    openItem.target = self
    openItem.representedObject = task.id
    openItem.image = Self.menuImage(systemName: "arrow.up.forward.app", description: "Open")
    submenu.addItem(openItem)
    submenu.addItem(.separator())

    let visibleLimit = model.settings.maximumVisibleTaskCount
    let maximumSupportedLimit =
      MenuBarSettings.supportedMaximumVisibleTaskCount.upperBound
    let addItem = NSMenuItem(
      title: "Add to Menu Bar",
      action: #selector(addTaskToMenuBarFromMenu(_:)),
      keyEquivalent: ""
    )
    addItem.target = self
    addItem.representedObject = task.id
    addItem.image = Self.menuImage(
      systemName: "plus",
      description: "Add to Menu Bar"
    )
    addItem.isEnabled = visibleLimit < maximumSupportedLimit
    let addDescription = addItem.isEnabled
      ? "Shows up to \(visibleLimit + 1) tasks on the menu bar"
      : "Up to \(maximumSupportedLimit) tasks can appear on the menu bar"
    if #available(macOS 14.4, *) {
      addItem.subtitle = addDescription
    } else {
      addItem.toolTip = addDescription
    }
    submenu.addItem(addItem)

    let replaceItem = NSMenuItem(
      title: "Replace Rightmost Ring",
      action: #selector(replaceRightmostTaskFromMenu(_:)),
      keyEquivalent: ""
    )
    replaceItem.target = self
    replaceItem.representedObject = task.id
    replaceItem.image = Self.menuImage(
      systemName: "arrow.left.arrow.right",
      description: "Replace Rightmost Ring"
    )
    replaceItem.isEnabled = visibleLimit > 0
    let replaceDescription =
      replaceItem.isEnabled
      ? "Keeps up to \(visibleLimit) tasks on the menu bar"
      : "No task ring is currently shown"
    if #available(macOS 14.4, *) {
      replaceItem.subtitle = replaceDescription
    } else {
      replaceItem.toolTip = replaceDescription
    }
    submenu.addItem(replaceItem)
    submenu.addItem(.separator())
    submenu.addItem(
      ringActionMenuItem(.hide, for: task, usesContextualHideTitle: true)
    )
    addTaskCustomizationConfiguration(for: task, to: submenu)

    let item = NSMenuItem(
      title: TaskMenuTextPolicy.displayedTitle(task.title),
      action: nil,
      keyEquivalent: ""
    )
    item.representedObject = task.id
    item.submenu = submenu
    TaskMenuTextPolicy.configureTaskTitle(task.title, on: item)
    menuTaskUpdater.track(item, presenting: task)
    return item
  }

  private func addTaskMenuItem(for task: TaskPresentation, to menu: NSMenu) {
    let item = taskMenuItem(for: task)
    menu.addItem(item)
  }

  private func addTasksOnMenuBarSubmenu(to menu: NSMenu) {
    let title = MenuBarSettingsCopy.tasksOnMenuBarTitle
    let submenu = NSMenu(title: title)
    submenu.autoenablesItems = false
    for count in MenuBarSettings.supportedMaximumVisibleTaskCount {
      let item = NSMenuItem(
        title: String(count),
        action: #selector(setMaximumTaskRingsFromMenu(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.tag = count
      item.state = count == model.settings.maximumVisibleTaskCount ? .on : .off
      submenu.addItem(item)
    }

    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.image = Self.menuImage(systemName: "menubar.rectangle", description: title)
    item.submenu = submenu
    menu.addItem(item)
  }

  private func addSpeakAnnouncementsItem(to menu: NSMenu) {
    let title = MenuBarSettingsCopy.speakAnnouncementsMenuTitle
    let item = NSMenuItem(
      title: title,
      action: #selector(toggleSpokenAnnouncements(_:)),
      keyEquivalent: ""
    )
    item.target = self
    item.image = Self.menuImage(
      systemName: model.settings.speaksAnnouncements
        ? "speaker.wave.2"
        : "speaker.slash",
      description: title
    )
    item.state = model.settings.speaksAnnouncements ? .on : .off
    menu.addItem(item)
  }

  private func addCodexCapacityItem(to menu: NSMenu) {
    let usage = model.codexUsageSnapshot
    let presentation = CapacityMenuItemPresentation.make(
      remainingPercent: usage?.remainingPercent
    )
    let item = NSMenuItem(
      title: presentation.title,
      action: #selector(openCapacityHistoryWindow(_:)),
      keyEquivalent: ""
    )
    item.target = self
    item.image = Self.menuImage(
      systemName: CapacityMenuItemPresentation.systemImageName,
      description: presentation.title
    )
    if let remainingPercent = usage?.remainingPercent {
      item.setAccessibilityValue("\(remainingPercent) percent remaining")
    }
    menu.addItem(item)
  }

  private func addMenuBarConfiguration(to menu: NSMenu) {
    if !menu.items.isEmpty {
      menu.addItem(.separator())
    }
    for element in MenuBarConfigurationPolicy.elements {
      switch element {
      case .tasksOnMenuBar:
        addTasksOnMenuBarSubmenu(to: menu)
      case .codexCapacity:
        addCodexCapacityItem(to: menu)
      case .speakAnnouncements:
        addSpeakAnnouncementsItem(to: menu)
      }
    }
  }

  private func addRingActions(for task: TaskPresentation, to menu: NSMenu) {
    guard model.statusBarTasks.contains(where: { $0.id == task.id }) else { return }
    let actions = CrewRingMenuPolicy.actions(
      forStatusBarTaskCount: model.statusBarTasks.count
    )
    for action in actions {
      menu.addItem(ringActionMenuItem(action, for: task))
    }
  }

  private func addTaskCustomizationConfiguration(
    for task: TaskPresentation,
    to menu: NSMenu
  ) {
    menu.addItem(.separator())
    for element in TaskCustomizationMenuPolicy.elements(
      speaksAnnouncements: model.settings.speaksAnnouncements
    ) {
      switch element {
      case .color:
        menu.addItem(colorMenuItem(for: task))
      case .voice:
        menu.addItem(voiceMenuItem(for: task))
      }
    }
  }

  private func colorMenuItem(for task: TaskPresentation) -> NSMenuItem {
    let title = "Color"
    let submenu = NSMenu(title: title)
    submenu.autoenablesItems = false
    for scope in TaskCustomizationMenuPolicy.scopes(
      hasParentScope: task.projectIdentity?.projectID != nil
    ) {
      switch scope {
      case .project:
        submenu.addItem(projectColorMenuItem(for: task))
      case .task:
        submenu.addItem(taskColorMenuItem(for: task))
      }
    }

    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.image = task.effectiveColor.map(Self.colorSwatchImage)
      ?? Self.menuImage(systemName: "paintpalette", description: title)
    item.submenu = submenu
    return item
  }

  private func voiceMenuItem(for task: TaskPresentation) -> NSMenuItem {
    let title = "Voice"
    let submenu = NSMenu(title: title)
    submenu.autoenablesItems = false
    for scope in TaskCustomizationMenuPolicy.scopes(
      hasParentScope: task.projectIdentity?.projectID != nil
    ) {
      switch scope {
      case .project:
        submenu.addItem(projectVoiceMenuItem(for: task))
      case .task:
        submenu.addItem(taskVoiceMenuItem(for: task))
      }
    }

    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.image = Self.menuImage(systemName: "speaker.wave.2", description: title)
    item.submenu = submenu
    return item
  }

  private func taskColorMenuItem(for task: TaskPresentation) -> NSMenuItem {
    let submenu = NSMenu(title: "Task Color")
    submenu.autoenablesItems = false

    if let inheritedTitle = TaskCustomizationInheritancePolicy.colorTitle(
      for: task.projectIdentity
    ) {
      let inheritedItem = NSMenuItem(
        title: inheritedTitle,
        action: #selector(setTaskColorFromMenu(_:)),
        keyEquivalent: ""
      )
      inheritedItem.target = self
      inheritedItem.representedObject = TaskColorMenuSelection(
        taskID: task.id,
        preference: .inheritProject
      )
      inheritedItem.state = task.taskColorPreference == .inheritProject ? .on : .off
      submenu.addItem(inheritedItem)
    }

    let defaultColorItem = NSMenuItem(
      title: "Use Default Color",
      action: #selector(setTaskColorFromMenu(_:)),
      keyEquivalent: ""
    )
    defaultColorItem.target = self
    defaultColorItem.representedObject = TaskColorMenuSelection(
      taskID: task.id,
      preference: .system
    )
    defaultColorItem.state = {
      if task.projectIdentity == nil,
        task.taskColorPreference == .inheritProject
      {
        return .on
      }
      return task.taskColorPreference == .system ? .on : .off
    }()
    submenu.addItem(defaultColorItem)
    submenu.addItem(.separator())

    for color in TaskAccentColor.allCases {
      let item = NSMenuItem(
        title: color.displayName,
        action: #selector(setTaskColorFromMenu(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = TaskColorMenuSelection(
        taskID: task.id,
        preference: .accent(color)
      )
      item.image = Self.colorSwatchImage(color)
      item.state = task.taskColor == color ? .on : .off
      submenu.addItem(item)
    }

    let item = NSMenuItem(title: "Task Color", action: nil, keyEquivalent: "")
    item.image = task.effectiveColor.map(Self.colorSwatchImage)
      ?? Self.menuImage(systemName: "paintpalette", description: "Task Color")
    item.submenu = submenu
    return item
  }

  private func projectColorMenuItem(for task: TaskPresentation) -> NSMenuItem {
    guard let identity = task.projectIdentity else {
      preconditionFailure("Project color menus require a project identity")
    }
    let submenu = NSMenu(title: "Project Color")
    submenu.autoenablesItems = false

    let systemItem = NSMenuItem(
      title: "Use Default Color",
      action: #selector(setProjectColorFromMenu(_:)),
      keyEquivalent: ""
    )
    systemItem.target = self
    systemItem.representedObject = ProjectColorMenuSelection(identity: identity, color: nil)
    systemItem.state = task.projectColor == nil ? .on : .off
    submenu.addItem(systemItem)
    submenu.addItem(.separator())

    for color in TaskAccentColor.allCases {
      let item = NSMenuItem(
        title: color.displayName,
        action: #selector(setProjectColorFromMenu(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = ProjectColorMenuSelection(identity: identity, color: color)
      item.image = Self.colorSwatchImage(color)
      item.state = task.projectColor == color ? .on : .off
      submenu.addItem(item)
    }

    let item = NSMenuItem(title: "Project Color", action: nil, keyEquivalent: "")
    item.image = task.projectColor.map(Self.colorSwatchImage)
      ?? Self.menuImage(systemName: "folder", description: "Project Color")
    item.submenu = submenu
    return item
  }

  private func taskVoiceMenuItem(for task: TaskPresentation) -> NSMenuItem {
    let submenu = NSMenu(title: "Task Voice")
    submenu.autoenablesItems = false
    let taskVoicePreference =
      SpokenUpdateVoiceCatalog.taskMenuPreference(for: task)

    if let inheritedTitle = TaskCustomizationInheritancePolicy.voiceTitle(
      for: task.projectIdentity
    ) {
      let inheritedItem = NSMenuItem(
        title: inheritedTitle,
        action: #selector(setTaskVoiceFromMenu(_:)),
        keyEquivalent: ""
      )
      inheritedItem.target = self
      inheritedItem.representedObject = TaskVoiceMenuSelection(
        taskID: task.id,
        preference: .inheritProject
      )
      inheritedItem.state = taskVoicePreference == .inheritProject ? .on : .off
      submenu.addItem(inheritedItem)
    }

    let defaultVoice = model.settings.defaultSpokenUpdateVoice
    let defaultItem = NSMenuItem(
      title: SpokenUpdateVoiceCatalog.useDefaultVoiceTitle,
      action: #selector(setTaskVoiceFromMenu(_:)),
      keyEquivalent: ""
    )
    defaultItem.target = self
    defaultItem.representedObject = TaskVoiceMenuSelection(
      taskID: task.id,
      preference: .defaultVoice
    )
    defaultItem.state = {
      taskVoicePreference == .defaultVoice ? .on : .off
    }()
    submenu.addItem(defaultItem)
    submenu.addItem(.separator())

    for group in SpokenUpdateVoiceCatalog.availableEnglishUSVoiceGroups {
      submenu.addItem(.sectionHeader(title: group.displayName))
      for voice in group.voices {
        let item = NSMenuItem(
          title: SpokenUpdateVoiceCatalog.menuTitle(
            for: voice,
            defaultVoice: defaultVoice
          ),
          action: #selector(setTaskVoiceFromMenu(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.representedObject = TaskVoiceMenuSelection(
          taskID: task.id,
          preference: .voice(voice)
        )
        item.state = taskVoicePreference == .voice(voice) ? .on : .off
        submenu.addItem(item)
      }
    }

    let item = NSMenuItem(title: "Task Voice", action: nil, keyEquivalent: "")
    item.image = Self.menuImage(systemName: "speaker.wave.2", description: "Task Voice")
    item.submenu = submenu
    return item
  }

  private func projectVoiceMenuItem(for task: TaskPresentation) -> NSMenuItem {
    guard let identity = task.projectIdentity else {
      preconditionFailure("Project voice menus require a project identity")
    }
    let submenu = NSMenu(title: "Project Voice")
    submenu.autoenablesItems = false
    let projectVoice =
      SpokenUpdateVoiceCatalog.canonicalVoice(task.projectVoice)
    let defaultVoice = model.settings.defaultSpokenUpdateVoice

    let defaultItem = NSMenuItem(
      title: SpokenUpdateVoiceCatalog.useDefaultVoiceTitle,
      action: #selector(setProjectVoiceFromMenu(_:)),
      keyEquivalent: ""
    )
    defaultItem.target = self
    defaultItem.representedObject = ProjectVoiceMenuSelection(
      identity: identity,
      voice: nil
    )
    defaultItem.state = projectVoice == nil ? .on : .off
    submenu.addItem(defaultItem)
    submenu.addItem(.separator())

    for group in SpokenUpdateVoiceCatalog.availableEnglishUSVoiceGroups {
      submenu.addItem(.sectionHeader(title: group.displayName))
      for voice in group.voices {
        let item = NSMenuItem(
          title: SpokenUpdateVoiceCatalog.menuTitle(
            for: voice,
            defaultVoice: defaultVoice
          ),
          action: #selector(setProjectVoiceFromMenu(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.representedObject = ProjectVoiceMenuSelection(
          identity: identity,
          voice: voice
        )
        item.state = projectVoice == voice ? .on : .off
        submenu.addItem(item)
      }
    }

    let item = NSMenuItem(title: "Project Voice", action: nil, keyEquivalent: "")
    item.image = Self.menuImage(systemName: "speaker.wave.2", description: "Project Voice")
    item.submenu = submenu
    return item
  }

  private func ringActionMenuItem(
    _ action: CrewRingMenuAction,
    for task: TaskPresentation,
    usesContextualHideTitle: Bool = false
  ) -> NSMenuItem {
    let item: NSMenuItem
    switch action {
    case .hide:
      let title = usesContextualHideTitle ? "Hide from Menu Bar" : "Hide"
      item = NSMenuItem(
        title: title,
        action: #selector(hideTaskRingFromMenu(_:)),
        keyEquivalent: ""
      )
      item.image = Self.menuImage(systemName: "eye.slash", description: title)
    }
    item.target = self
    item.representedObject = task.id
    return item
  }

  private func taskMenuItem(for task: TaskPresentation) -> NSMenuItem {
    let item = NSMenuItem(
      title: TaskMenuTextPolicy.displayedTitle(task.title),
      action: #selector(openTaskFromMenu(_:)),
      keyEquivalent: ""
    )
    item.target = self
    item.representedObject = task.id
    menuTaskUpdater.track(item, presenting: task)
    if #available(macOS 14.4, *) {
      item.subtitle = TaskMenuTextPolicy.displayedSubtitle(
        task.menuActivitySummary()
      )
    }
    TaskMenuTextPolicy.configureTaskTitle(task.title, on: item)
    return item
  }

  private func present(
    _ menu: NSMenu,
    from button: NSStatusBarButton,
    clickedTask: TaskPresentation? = nil
  ) {
    guard !isPresentingMenu else { return }
    isPresentingMenu = true
    StatusItemMenuPresentationPolicy.schedule { [weak self, weak button] in
      guard let self else { return }
      guard let button else {
        self.isPresentingMenu = false
        return
      }
      self.pendingContextMenuScope = clickedTask
        .map(StatusItemContextMenuScope.task) ?? .appScoped
      self.statusItem.menu = menu
      button.performClick(nil)
      self.statusItem.menu = nil
      self.pendingContextMenuScope = .appScoped
      self.isPresentingMenu = false
    }
  }

  @objc
  private func openCodex(_ sender: Any?) {
    model.openCodex()
  }

  @objc
  private func openTaskFromMenu(_ sender: NSMenuItem) {
    guard let taskID = sender.representedObject as? String,
      let task = model.tasks.first(where: { $0.id == taskID })
    else { return }
    model.openTask(task)
  }

  @objc
  private func hideTaskRingFromMenu(_ sender: NSMenuItem) {
    guard let taskID = sender.representedObject as? String,
      let task = model.tasks.first(where: { $0.id == taskID })
    else { return }
    model.hideCrewRing(for: task)
  }

  @objc
  private func addTaskToMenuBarFromMenu(_ sender: NSMenuItem) {
    guard let taskID = sender.representedObject as? String else { return }
    model.addCrewTaskToMenuBar(taskID: taskID)
  }

  @objc
  private func replaceRightmostTaskFromMenu(_ sender: NSMenuItem) {
    guard let taskID = sender.representedObject as? String else { return }
    model.replaceRightmostCrewTask(taskID: taskID)
  }

  @objc
  private func setTaskColorFromMenu(_ sender: NSMenuItem) {
    guard let selection = sender.representedObject as? TaskColorMenuSelection else { return }
    model.setTaskColorPreference(selection.preference, for: selection.taskID)
  }

  @objc
  private func setProjectColorFromMenu(_ sender: NSMenuItem) {
    guard let selection = sender.representedObject as? ProjectColorMenuSelection else { return }
    model.setProjectColor(selection.color, for: selection.identity)
  }

  @objc
  private func setTaskVoiceFromMenu(_ sender: NSMenuItem) {
    guard let selection = sender.representedObject as? TaskVoiceMenuSelection else { return }
    model.setTaskVoicePreference(selection.preference, for: selection.taskID)
    guard let task = model.tasks.first(where: { $0.id == selection.taskID }) else { return }
    previewSpokenUpdate(
      SpokenUpdateVoiceCatalog.effectiveVoice(
        for: task,
        defaultVoice: model.settings.defaultSpokenUpdateVoice
      )
    )
  }

  @objc
  private func setProjectVoiceFromMenu(_ sender: NSMenuItem) {
    guard let selection = sender.representedObject as? ProjectVoiceMenuSelection else { return }
    model.setProjectVoice(selection.voice, for: selection.identity)
    previewSpokenUpdate(
      selection.voice ?? model.settings.defaultSpokenUpdateVoice
    )
  }

  @objc
  private func setMaximumTaskRingsFromMenu(_ sender: NSMenuItem) {
    model.settings.maximumVisibleTaskCount = sender.tag
  }

  @objc
  private func openCapacityHistoryWindow(_ sender: Any?) {
    openCapacityHistory()
  }

  @objc
  private func toggleSpokenAnnouncements(_ sender: NSMenuItem) {
    model.settings.speaksAnnouncements.toggle()
  }

  @objc
  private func showAboutPanel(_ sender: Any?) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    NSApplication.shared.orderFrontStandardAboutPanel(
      options: AppPresentationCopy.aboutPanelOptions
    )
    for window in NSApplication.shared.windows where window.isVisible {
      guard let contentView = window.contentView else { continue }
      if Self.applyAboutPanelFeedbackLinkStyle(in: contentView) {
        break
      }
    }
  }

  @objc
  private func showDiagnosticsWindow(_ sender: Any?) {
    showDiagnostics()
  }

  @MainActor
  @discardableResult
  static func applyAboutPanelFeedbackLinkStyle(in view: NSView) -> Bool {
    if let textView = view as? NSTextView {
      let attributedString = textView.attributedString()
      if attributedString.length > 0,
        attributedString.attribute(.link, at: 0, effectiveRange: nil) as? URL
          == AppPresentationCopy.feedbackFormURL
      {
        textView.linkTextAttributes =
          AppPresentationCopy.aboutPanelFeedbackLinkTextAttributes
        return true
      }
    }

    for subview in view.subviews {
      if applyAboutPanelFeedbackLinkStyle(in: subview) {
        return true
      }
    }
    return false
  }

  @objc
  private func checkForUpdates(_ sender: Any?) {
    updateChecker.checkForUpdates()
  }

  @objc
  private func openSettings(_ sender: Any?) {
    guard let openSettings = interaction.openSettings else { return }
    openSettings()
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc
  private func quitApplication(_ sender: Any?) {
    NSApplication.shared.terminate(sender)
  }

  private func validateLayout(button: NSStatusBarButton) {
    button.layoutSubtreeIfNeeded()
    assert(abs(button.bounds.width - statusItem.length) < 0.5)
    assert(abs(labelView.frame.minX - button.bounds.minX) < 0.5)
    assert(abs(labelView.frame.maxX - button.bounds.maxX) < 0.5)
  }

  private func updateLayout() {
    let displayedTasks = model.statusBarTasks
    let overflowTasks = model.overflowCrewTasks
    let showsHealthBadge =
      !displayedTasks.isEmpty
      && model.statusPresentation.requiresStatusBadge
    let contentWidth = WorkerCrewLayout.contentWidth(
      forDisplayedCrewCount: displayedTasks.count,
      overflowCount: overflowTasks.count,
      capacityRemainingPercent: displayedCapacityRemainingPercent,
      showsHealthBadge: showsHealthBadge
    )
    if let button = statusItem.button {
      button.toolTip = statusItemToolTip
      if statusItem.length != contentWidth {
        statusItem.length = contentWidth
      }
      button.layoutSubtreeIfNeeded()
      validateLayout(button: button)
      updateAccessibility(button: button)
    }

    peekController.refreshVisiblePeek(
      isAvailable: { [weak self] target in
        self?.isHoverTargetAvailable(target) ?? false
      },
      makeContent: { [weak self] target in
        self?.peekContent(for: target)
      }
    )

    if menuTaskUpdater.trackedTaskCount > 0 {
      menuTaskUpdater.refresh(currentTasks: model.menuTasks)
    }
  }

  private func cancelTrackedMenusIfDesktopAppRecoveryChanged(
    to desktopAppRecoveryMenu: CodexDesktopAppRecoveryMenu?
  ) {
    if previousDesktopAppRecoveryMenu != desktopAppRecoveryMenu {
      contextMenu.cancelTracking()
      overflowMenu.cancelTracking()
    }
    previousDesktopAppRecoveryMenu = desktopAppRecoveryMenu
  }

  private func updateAccessibility(button: NSStatusBarButton) {
    let tasks = model.statusBarTasks
    let overflowTasks = model.overflowCrewTasks
    let snapshot = StatusItemAccessibilityController.Snapshot(
      tasks: tasks.map { task in
        StatusItemAccessibilityController.Task(
          id: task.id,
          title: task.title,
          value: task.accessibilityValue,
          canMoveLeft: model.canMoveCrewRing(taskID: task.id, direction: .left),
          canMoveRight: model.canMoveCrewRing(taskID: task.id, direction: .right)
        )
      },
      overflowCount: overflowTasks.count,
      overflowAttentionCount: overflowTasks.filter { $0.state.requiresAttention }.count,
      overflowUnreadCompletionCount: overflowTasks.filter(\.showsUnreadCompletionSignal).count,
      capacityRemainingPercent: displayedCapacityRemainingPercent,
      showsHealth: !tasks.isEmpty && model.statusPresentation.requiresStatusBadge,
      statusLabel: model.statusPresentation.accessibilityLabel
    )
    accessibilityController.update(
      parent: button,
      coordinateView: labelView,
      snapshot: snapshot
    ) { [weak self] action in
      self?.handleAccessibilityAction(action) ?? false
    }
  }

  private func handleAccessibilityAction(
    _ action: StatusItemAccessibilityController.Action
  ) -> Bool {
    switch action {
    case .showContextMenu:
      guard let button = statusItem.button else { return false }
      present(contextMenu, from: button)
      return true
    case .openTask(let taskID):
      guard let task = model.tasks.first(where: { $0.id == taskID }) else {
        return false
      }
      model.openTask(task)
      return true
    case .moveTask(let taskID, let direction):
      let moveDirection: CrewRingMoveDirection =
        direction == .left ? .left : .right
      return model.moveCrewRing(taskID: taskID, direction: moveDirection)
    case .hideTask(let taskID):
      guard let task = model.tasks.first(where: { $0.id == taskID }) else {
        return false
      }
      model.hideCrewRing(for: task)
      return true
    case .showOverflowMenu:
      guard let button = statusItem.button else { return false }
      present(overflowMenu, from: button)
      return true
    }
  }

  private var statusItemToolTip: String? {
    model.statusBarTasks.isEmpty ? model.statusPresentation.accessibilityLabel : nil
  }

  private var displayedCapacityRemainingPercent: Int? {
    guard model.settings.showsCapacityInMenuBar else { return nil }
    return model.codexUsageSnapshot?.remainingPercent
  }

  private var capacityResetDescription: String? {
    model.codexUsageSnapshot?.resetsAt.map {
      "Resets \($0.formatted(date: .abbreviated, time: .shortened))"
    }
  }

  private var summaryPeekPresentation: CrewSummaryPeekPresentation? {
    let overflowTasks = model.overflowCrewTasks
    return CrewSummaryPeekPresentation.make(
      overflowCount: overflowTasks.count,
      attentionCount: overflowTasks.filter { $0.state.requiresAttention }.count,
      unreadCompletionCount: overflowTasks.filter(\.showsUnreadCompletionSignal).count,
      capacityRemainingPercent: displayedCapacityRemainingPercent,
      resetDescription:
        displayedCapacityRemainingPercent == nil ? nil : capacityResetDescription
    )
  }

  private func isHoverTargetAvailable(_ hoverTarget: StatusItemPeekTarget) -> Bool {
    switch hoverTarget {
    case .task(let taskID):
      return model.statusBarTasks.contains { $0.id == taskID }
    case .summary:
      return summaryPeekPresentation != nil
    }
  }

  private static func menuImage(systemName: String, description: String) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    return NSImage(systemSymbolName: systemName, accessibilityDescription: description)?
      .withSymbolConfiguration(configuration)
  }

  private static func colorSwatchImage(_ color: TaskAccentColor) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
      let swatchRect = NSRect(x: 4, y: 4, width: 10, height: 10)
      let swatch = NSBezierPath(ovalIn: swatchRect)
      color.nsColor.setFill()
      swatch.fill()
      NSColor.separatorColor.setStroke()
      swatch.lineWidth = 0.5
      swatch.stroke()
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = color.displayName
    return image
  }

  #if DEBUG
    private func openAboutPanelWhenRequested() {
      let environment = ProcessInfo.processInfo.environment
      let capturePath = environment["CODEX_ECHO_CAPTURE_ABOUT"]
      guard environment["CODEX_ECHO_DEBUG_OPEN_ABOUT"] == "1"
        || capturePath != nil
      else {
        return
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        self?.showAboutPanel(nil)
        guard let self, let capturePath else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          do {
            let visibleWindows = NSApplication.shared.windows.filter(\.isVisible)
            let windowDescriptions = visibleWindows.map {
              "\($0.title):\($0.frame):\(String(describing: type(of: $0)))"
            }
            guard
              let aboutWindow = visibleWindows.first(where: {
                $0.title == AppPresentationCopy.aboutMenuTitle
              }) ?? visibleWindows.max(by: {
                $0.frame.width * $0.frame.height
                  < $1.frame.width * $1.frame.height
              }),
              let contentView = aboutWindow.contentView
            else {
              throw StatusItemCaptureError.couldNotAllocateBitmap
            }
            contentView.layoutSubtreeIfNeeded()
            contentView.displayIfNeeded()
            try self.capture(view: contentView, to: capturePath)
            print(
              "ABOUT_PANEL_CAPTURED title=\(aboutWindow.title) "
                + "frame=\(aboutWindow.frame) "
                + "windows=\(windowDescriptions) "
                + "accessibility=\(Self.accessibilityTree(for: contentView)) "
                + "path=\(capturePath)"
            )
            NSApplication.shared.terminate(nil)
          } catch {
            assertionFailure("Could not capture standard About panel: \(error)")
          }
        }
      }
    }

    private func openSettingsWhenRequested() {
      let environment = ProcessInfo.processInfo.environment
      guard environment["CODEX_ECHO_DEBUG_OPEN_SETTINGS"] == "1" else {
        return
      }
      let keepsSettingsOpen =
        environment["CODEX_ECHO_DEBUG_KEEP_SETTINGS_OPEN"] == "1"
      let capturePath =
        environment["CODEX_ECHO_CAPTURE_OPEN_SETTINGS_WINDOW"]

      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        self?.openSettings(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
          let visibleWindows = NSApplication.shared.windows
            .filter { $0.isVisible && !($0 is NSPanel) }
          let settingsWindows = visibleWindows.filter {
            $0.styleMask.contains(.titled)
              && MenuBarSettingsPane.allCases.map(\.title).contains($0.title)
          }
          let visibleWindowTitles = visibleWindows.map(\.title)
          print(
            "SETTINGS_WINDOW_OPEN bridge=\(self?.interaction.openSettings != nil) "
              + "titles=\(visibleWindowTitles) "
              + "settingsWindowNumber=\(settingsWindows.first?.windowNumber ?? 0)"
          )
          if
            let self,
            let capturePath,
            let settingsWindow = settingsWindows.first,
            let frameView = settingsWindow.contentView?.superview
          {
            do {
              frameView.layoutSubtreeIfNeeded()
              frameView.displayIfNeeded()
              try self.capture(view: frameView, to: capturePath)
              print(
                "SETTINGS_WINDOW_CAPTURED title=\(settingsWindow.title) "
                  + "path=\(capturePath)"
              )
            } catch {
              assertionFailure("Could not capture Settings window: \(error)")
            }
          }
          if !keepsSettingsOpen {
            NSApplication.shared.terminate(nil)
          }
        }
      }
    }

    private func dumpAccessibilityWhenRequested(button: NSStatusBarButton) {
      guard
        ProcessInfo.processInfo.environment[
          "CODEX_ECHO_DEBUG_ACCESSIBILITY"
        ] == "1"
      else { return }

      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak button] in
        guard let button else { return }
        button.layoutSubtreeIfNeeded()
        let lines = Self.accessibilityTree(for: button)
        print(
          "STATUS_ACCESSIBILITY_SCREENS \(NSScreen.screens.map(\.frame))\n"
            + "STATUS_ACCESSIBILITY_TREE\n"
            + lines.joined(separator: "\n")
        )
        NSApplication.shared.terminate(nil)
      }
    }

    private static func accessibilityTree(
      for object: Any,
      depth: Int = 0
    ) -> [String] {
      let indentation = String(repeating: "  ", count: depth)
      let role: String
      let label: String
      let value: String
      let actions: [String]
      let children: [Any]
      let frame: NSRect?

      if let element = object as? NSAccessibilityElement {
        role = element.accessibilityRole()?.rawValue ?? "-"
        label = element.accessibilityLabel() ?? "-"
        value = element.accessibilityValue().map(String.init(describing:)) ?? "-"
        actions = element.accessibilityCustomActions()?.map(\.name) ?? []
        children = element.accessibilityChildren() ?? []
        frame = element.accessibilityFrame()
      } else if let view = object as? NSView {
        role = view.accessibilityRole()?.rawValue ?? "-"
        label = view.accessibilityLabel() ?? "-"
        value = view.accessibilityValue().map(String.init(describing:)) ?? "-"
        actions = view.accessibilityCustomActions()?.map(\.name) ?? []
        children = view.accessibilityChildren() ?? []
        frame = view.accessibilityFrame()
      } else {
        role = "-"
        label = String(describing: type(of: object))
        value = "-"
        actions = []
        children = []
        frame = nil
      }

      var lines = [
        "\(indentation)role=\(role) label=\(label) value=\(value) "
          + "actions=\(actions) frame=\(frame.map(String.init(describing:)) ?? "-")"
      ]
      for child in children {
        lines.append(contentsOf: accessibilityTree(for: child, depth: depth + 1))
      }
      return lines
    }

    private func openMenuWhenRequested(button: NSStatusBarButton) {
      let environment = ProcessInfo.processInfo.environment
      let shouldOpenMainMenu = environment["CODEX_ECHO_DEBUG_OPEN_MENU"] == "1"
      let shouldOpenTaskMenu = environment["CODEX_ECHO_DEBUG_OPEN_TASK_MENU"] == "1"
      let shouldOpenOverflowMenu =
        environment["CODEX_ECHO_DEBUG_OPEN_OVERFLOW_MENU"] == "1"
      let shouldSelectCapacityHistory =
        environment[
          "CODEX_ECHO_DEBUG_SELECT_CAPACITY_HISTORY_FROM_MENU"
        ] == "1"
      let shouldOpenLegacyOverflowManagementMenu =
        environment["CODEX_ECHO_DEBUG_OPEN_OVERFLOW_MANAGEMENT_MENU"] == "1"
      guard shouldOpenMainMenu || shouldOpenTaskMenu || shouldOpenOverflowMenu
        || shouldOpenLegacyOverflowManagementMenu
        || shouldSelectCapacityHistory
      else {
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self, weak button] in
        guard let self, let button else { return }
        if shouldOpenTaskMenu, let task = self.model.crewTasks.first {
          self.present(self.contextMenu, from: button, clickedTask: task)
        } else if shouldOpenOverflowMenu || shouldOpenLegacyOverflowManagementMenu {
          self.present(self.overflowMenu, from: button)
        } else {
          if shouldSelectCapacityHistory {
            let selectionTimer = Timer(
              timeInterval: 0.75,
              repeats: false
            ) { [weak self] _ in
              MainActor.assumeIsolated {
                guard let self else { return }
                guard let index = self.contextMenu.items.firstIndex(where: {
                  $0.action == #selector(self.openCapacityHistoryWindow(_:))
                }) else {
                  assertionFailure(
                    "Codex Capacity was missing from the common menu"
                  )
                  return
                }
                self.contextMenu.performActionForItem(at: index)
              }
              DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard
                  let historyWindow = NSApplication.shared.windows.first(
                    where: {
                      $0.title == "Codex Capacity" && $0.isVisible
                    }
                  )
                else {
                  assertionFailure(
                    "Codex Capacity did not open its window"
                  )
                  return
                }
                print(
                  "CAPACITY_HISTORY_MENU_OPENED "
                    + "frame=\(historyWindow.frame)"
                )
              }
            }
            RunLoop.main.add(selectionTimer, forMode: .eventTracking)
          }
          self.present(self.contextMenu, from: button)
        }
      }
    }

    private func captureViewsWhenRequested(button: NSStatusBarButton) {
      let environment = ProcessInfo.processInfo.environment
      let statusItemPath = environment["CODEX_ECHO_CAPTURE_STATUS_ITEM"]
      let statusItemSecondPath = environment["CODEX_ECHO_CAPTURE_STATUS_ITEM_SECOND"]
      let variantsPath = environment["CODEX_ECHO_CAPTURE_CORE_VARIANTS"]
      let peekPath = environment["CODEX_ECHO_CAPTURE_CREW_PEEK"]
      let summaryPeekPath = environment["CODEX_ECHO_CAPTURE_SUMMARY_PEEK"]
      let menuRingsPath = environment["CODEX_ECHO_CAPTURE_MENU_RINGS"]
      let settingsPath = environment["CODEX_ECHO_CAPTURE_SETTINGS"]
      let announcementSettingsPath =
        environment["CODEX_ECHO_CAPTURE_ANNOUNCEMENT_SETTINGS"]
      let announcementSettingsSearchQuery =
        environment["CODEX_ECHO_CAPTURE_ANNOUNCEMENT_SEARCH_QUERY"] ?? ""
      guard
        statusItemPath != nil || statusItemSecondPath != nil || variantsPath != nil || peekPath != nil
          || summaryPeekPath != nil || menuRingsPath != nil || settingsPath != nil
          || announcementSettingsPath != nil
      else { return }

      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak button] in
        guard let self, let button else { return }
        do {
          if let statusItemPath {
            self.labelView.layoutSubtreeIfNeeded()
            self.labelView.displayIfNeeded()
            button.layoutSubtreeIfNeeded()
            button.displayIfNeeded()
            try self.capture(view: button, to: statusItemPath)
          }

          if let variantsPath {
            let variantsView = NSHostingView(rootView: WorkerCoreVariantStrip())
            variantsView.frame = NSRect(x: 0, y: 0, width: 398, height: 54)
            variantsView.layoutSubtreeIfNeeded()
            variantsView.displayIfNeeded()
            try self.capture(view: variantsView, to: variantsPath)
          }

          if let peekPath {
            let task =
              self.model.crewTasks.first
              ?? TaskPresentation(
                id: "preview",
                title: "Refine the Codex activity rings",
                project: "codex-echo",
                state: .working,
                activeSubagentCount: 2,
                updatedAt: nil
              )
            let peekView = NSHostingView(rootView: CrewPeekView(task: task))
            peekView.frame = NSRect(origin: .zero, size: CrewPeekMetrics.size)
            peekView.layoutSubtreeIfNeeded()
            peekView.displayIfNeeded()
            try self.capture(view: peekView, to: peekPath)
          }

          if
            let summaryPeekPath,
            let presentation = CrewSummaryPeekPresentation.make(
              overflowCount: 3,
              attentionCount: 1,
              unreadCompletionCount: 1,
              capacityRemainingPercent: 43,
              resetDescription: "Resets Jul 31, 2026 at 19:49"
            )
          {
            let summaryPeekView = NSHostingView(
              rootView: CrewSummaryPeekView(presentation: presentation)
            )
            summaryPeekView.frame = NSRect(origin: .zero, size: CrewPeekMetrics.size)
            summaryPeekView.layoutSubtreeIfNeeded()
            summaryPeekView.displayIfNeeded()
            try self.capture(view: summaryPeekView, to: summaryPeekPath)
          }

          if let menuRingsPath {
            let menuRingsView = MenuTaskRingDebugStripView()
            menuRingsView.frame = NSRect(
              origin: .zero,
              size: MenuTaskRingDebugStripView.preferredSize
            )
            menuRingsView.layoutSubtreeIfNeeded()
            menuRingsView.displayIfNeeded()
            try self.capture(view: menuRingsView, to: menuRingsPath)
          }

          if let settingsPath {
            let settingsView = NSHostingView(
              rootView: MenuBarSettingsView(
                settings: self.model.settings,
                launchAtLogin: LaunchAtLoginController(),
                updateController: SparkleAppUpdateController(
                  displayVersion: AppUpdateConfiguration.displayVersion(
                    infoDictionary: Bundle.main.infoDictionary
                  ),
                  isAvailable: true,
                  canCheckForUpdates: true,
                  automaticallyChecksForUpdates: true
                ),
                previewSpokenVoice: { _ in },
                openProjectCustomizationSettings: {},
                openSpokenAnnouncementSettings: {}
              )
            )
            settingsView.layoutSubtreeIfNeeded()
            settingsView.frame = NSRect(
              origin: .zero,
              size: settingsView.fittingSize
            )
            settingsView.layoutSubtreeIfNeeded()
            settingsView.displayIfNeeded()
            try self.capture(view: settingsView, to: settingsPath)
          }

          if let announcementSettingsPath {
            let announcementSettingsView = NSHostingView(
              rootView: SpokenAnnouncementSettingsView(
                settings: self.model.settings,
                previewSpokenAnnouncement: { _ in },
                close: {},
                initialSearchText: announcementSettingsSearchQuery
              )
            )
            announcementSettingsView.frame = NSRect(
              x: 0,
              y: 0,
              width: MenuBarSettingsMetrics.announcementWindowWidth,
              height: MenuBarSettingsMetrics.announcementWindowHeight
            )
            let captureWindow = NSWindow(
              contentRect: announcementSettingsView.frame,
              styleMask: [.titled],
              backing: .buffered,
              defer: false
            )
            captureWindow.contentView = announcementSettingsView
            captureWindow.orderBack(nil)
            announcementSettingsView.layoutSubtreeIfNeeded()
            announcementSettingsView.displayIfNeeded()
            try self.capture(
              view: announcementSettingsView,
              to: announcementSettingsPath
            )
            captureWindow.close()
          }

          print(
            "SIGNAL_UI_CAPTURED item=\(button.bounds.width) policy=explicit "
              + "label=\(self.labelView.frame.width) "
              + "maximum=\(self.model.settings.maximumVisibleTaskCount) "
              + "visible=\(self.model.statusBarTasks.count) "
              + "status=\(statusItemPath ?? "-") "
              + "statusSecond=\(statusItemSecondPath ?? "-") "
              + "variants=\(variantsPath ?? "-") peek=\(peekPath ?? "-") "
              + "summaryPeek=\(summaryPeekPath ?? "-") "
              + "menuRings=\(menuRingsPath ?? "-") "
              + "settings=\(settingsPath ?? "-") "
              + "announcementSettings=\(announcementSettingsPath ?? "-")"
          )
          if let statusItemSecondPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
              do {
                self.labelView.layoutSubtreeIfNeeded()
                self.labelView.displayIfNeeded()
                button.layoutSubtreeIfNeeded()
                button.displayIfNeeded()
                try self.capture(view: button, to: statusItemSecondPath)
                print("SIGNAL_UI_SECOND_FRAME_CAPTURED status=\(statusItemSecondPath)")
              } catch {
                assertionFailure("Could not capture second Signal UI frame: \(error)")
              }
              NSApplication.shared.terminate(nil)
            }
            return
          }
          NSApplication.shared.terminate(nil)
        } catch {
          assertionFailure("Could not capture Signal UI: \(error)")
        }
      }
    }

    private func capture(view: NSView, to path: String) throws {
      guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw StatusItemCaptureError.couldNotAllocateBitmap
      }
      view.cacheDisplay(in: view.bounds, to: representation)
      guard let data = representation.representation(using: .png, properties: [:]) else {
        throw StatusItemCaptureError.couldNotEncodePNG
      }
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
  #endif
}

private final class HoverTrackingHostingView<Content: View>: NSHostingView<Content> {
  var onMouseMove: ((NSPoint) -> Void)?
  var onMouseExit: (() -> Void)?
  private var hoverTrackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    mouseMoved(with: event)
  }

  override func mouseMoved(with event: NSEvent) {
    onMouseMove?(convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    onMouseExit?()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

#if DEBUG
  private enum StatusItemCaptureError: Error {
    case couldNotAllocateBitmap
    case couldNotEncodePNG
  }
#endif
