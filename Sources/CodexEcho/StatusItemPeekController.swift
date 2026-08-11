import AppKit

enum StatusItemPeekTarget: Equatable {
  case task(String)
  case summary

  var taskID: String? {
    guard case .task(let taskID) = self else { return nil }
    return taskID
  }

  var debugDescription: String {
    switch self {
    case .task(let taskID):
      "task:\(taskID)"
    case .summary:
      "summary"
    }
  }
}

struct StatusItemPeekContent {
  let viewController: NSViewController
  let anchorRect: NSRect
}

enum StatusItemPeekPlacement {
  static func origin(
    anchoredTo anchorRect: NSRect,
    peekSize: NSSize,
    visibleScreenFrame: NSRect?
  ) -> NSPoint {
    var origin = NSPoint(
      x: anchorRect.midX - peekSize.width / 2,
      y: anchorRect.minY - peekSize.height - CrewPeekMetrics.gap
    )
    guard let visibleScreenFrame else { return origin }

    origin.x = min(
      max(origin.x, visibleScreenFrame.minX + CrewPeekMetrics.screenInset),
      visibleScreenFrame.maxX - peekSize.width - CrewPeekMetrics.screenInset
    )
    if origin.y < visibleScreenFrame.minY + CrewPeekMetrics.screenInset {
      origin.y = anchorRect.maxY + CrewPeekMetrics.gap
    }
    return origin
  }
}

/// Owns delayed hover selection and the lifecycle of the nonactivating status-item peek panel.
@MainActor
final class StatusItemPeekController {
  typealias ContentProvider = (StatusItemPeekTarget) -> StatusItemPeekContent?

  private weak var anchorView: NSView?
  private let panel: NSPanel
  private let hoverDelay: TimeInterval
  private let onHoveredTaskIDChange: (String?) -> Void
  private var currentTarget: StatusItemPeekTarget?
  private var pendingTarget: StatusItemPeekTarget?
  private var visibleTarget: StatusItemPeekTarget?
  private var showWorkItem: DispatchWorkItem?

  #if DEBUG
    var isVisible: Bool { panel.isVisible }
    var activeTarget: StatusItemPeekTarget? { currentTarget }
  #endif

  init(
    anchorView: NSView,
    hoverDelay: TimeInterval = 0.18,
    onHoveredTaskIDChange: @escaping (String?) -> Void
  ) {
    self.anchorView = anchorView
    self.hoverDelay = hoverDelay
    self.onHoveredTaskIDChange = onHoveredTaskIDChange
    panel = Self.makePanel()
  }

  func updateHover(
    to target: StatusItemPeekTarget?,
    makeContent: @escaping ContentProvider
  ) {
    guard let target else {
      clear()
      return
    }

    if currentTarget != target {
      let previousTaskID = currentTarget?.taskID
      cancelPendingShow()
      currentTarget = target
      if previousTaskID != target.taskID {
        onHoveredTaskIDChange(target.taskID)
      }
    }

    if panel.isVisible {
      if visibleTarget != target {
        show(target, makeContent: makeContent)
      }
      return
    }
    guard pendingTarget != target else { return }

    pendingTarget = target
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.currentTarget == target else { return }
      self.showWorkItem = nil
      self.pendingTarget = nil
      self.show(target, makeContent: makeContent)
    }
    showWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + hoverDelay,
      execute: workItem
    )
  }

  func refreshVisiblePeek(
    isAvailable: (StatusItemPeekTarget) -> Bool,
    makeContent: ContentProvider
  ) {
    guard let currentTarget else { return }
    guard isAvailable(currentTarget) else {
      clear()
      return
    }
    if panel.isVisible {
      show(currentTarget, makeContent: makeContent)
    }
  }

  func clear() {
    let hadHoveredTask = currentTarget?.taskID != nil
    cancelPendingShow()
    currentTarget = nil
    visibleTarget = nil
    if hadHoveredTask {
      onHoveredTaskIDChange(nil)
    }
    panel.orderOut(nil)
  }

  private func cancelPendingShow() {
    showWorkItem?.cancel()
    showWorkItem = nil
    pendingTarget = nil
  }

  private func show(
    _ target: StatusItemPeekTarget,
    makeContent: ContentProvider
  ) {
    guard let content = makeContent(target) else {
      clear()
      return
    }
    guard let anchorView, let window = anchorView.window else { return }

    let size = CrewPeekMetrics.size
    let anchorRectInWindow = anchorView.convert(content.anchorRect, to: nil)
    let anchorRectOnScreen = window.convertToScreen(anchorRectInWindow)
    content.viewController.view.frame = NSRect(origin: .zero, size: size)
    panel.contentViewController = content.viewController
    let origin = StatusItemPeekPlacement.origin(
      anchoredTo: anchorRectOnScreen,
      peekSize: size,
      visibleScreenFrame: window.screen?.visibleFrame
    )

    panel.setFrame(NSRect(origin: origin, size: size), display: true)
    visibleTarget = target
    #if DEBUG
      if ProcessInfo.processInfo.environment["CODEX_ECHO_DEBUG_EVENTS"] == "1" {
        print("STATUS_HOVER_PREVIEW target=\(target.debugDescription)")
      }
    #endif
    if !panel.isVisible {
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
        panel.animator().alphaValue = 1
      }
    }
  }

  private static func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: CrewPeekMetrics.size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    return panel
  }
}
