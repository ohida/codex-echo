import AppKit

enum StatusItemDragUpdate: Equatable {
  case unchanged
  case activated(CrewRingDragPresentation)
  case changed(CrewRingDragPresentation)
  case cancelled
}

struct StatusItemGestureState {
  private struct DragSequence {
    let taskID: String
    var hasActivated = false
  }

  private var lastHandledSecondaryActionEvent: StatusItemActionEventIdentity?
  private var dragSequence: DragSequence?
  private(set) var ringDrag: CrewRingDragPresentation?

  mutating func shouldHandleSecondaryAction(
    eventType: NSEvent.EventType,
    identity: StatusItemActionEventIdentity
  ) -> Bool {
    let shouldHandle = StatusItemSecondaryActionPolicy.shouldHandle(
      eventType: eventType,
      identity: identity,
      lastHandledIdentity: lastHandledSecondaryActionEvent
    )
    if shouldHandle { lastHandledSecondaryActionEvent = identity }
    return shouldHandle
  }

  mutating func beginDrag(taskID: String) {
    cancelDrag()
    dragSequence = DragSequence(taskID: taskID)
  }

  mutating func updateDrag(
    translation: CGSize,
    inputPhase: CrewRingDragInputPhase,
    visibleTaskIDs: [String]
  ) -> StatusItemDragUpdate {
    guard var sequence = dragSequence,
      let sourceIndex = visibleTaskIDs.firstIndex(of: sequence.taskID)
    else {
      cancelDrag()
      return .cancelled
    }

    let didActivate: Bool
    if sequence.hasActivated {
      didActivate = false
    } else {
      guard CrewRingDragActivation.shouldStart(
        translation: translation,
        inputPhase: inputPhase
      ) else { return .unchanged }
      sequence.hasActivated = true
      dragSequence = sequence
      didActivate = true
    }

    let presentation = CrewRingDragPresentation(
      taskID: sequence.taskID,
      sourceIndex: sourceIndex,
      destinationIndex: CrewRingDragLayout.destinationIndex(
        sourceIndex: sourceIndex,
        translationX: translation.width,
        taskCount: visibleTaskIDs.count
      ),
      translationX: translation.width
    )
    ringDrag = presentation
    return didActivate ? .activated(presentation) : .changed(presentation)
  }

  mutating func finishDrag() -> CrewRingDragPresentation? {
    defer { cancelDrag() }
    guard dragSequence?.hasActivated == true else { return nil }
    return ringDrag
  }

  mutating func cancelDrag() {
    dragSequence = nil
    ringDrag = nil
  }

  var hasDragSequence: Bool {
    dragSequence != nil
  }

  var debugDragState: String {
    guard let dragSequence else { return "none" }
    return dragSequence.hasActivated ? "active" : "pending"
  }
}

@MainActor
final class StatusItemGestureController: NSObject, NSGestureRecognizerDelegate {
  struct Snapshot: Equatable {
    let taskIDs: [String]
    let overflowCount: Int
    let capacityRemainingPercent: Int?
    let taskOpenMouseButton: TaskOpenMouseButton
  }

  enum Action: Equatable {
    case clearHover
    case openTask(taskID: String)
    case presentOverflowMenu
    case presentContextMenu(taskID: String?)
    case updateDrag(CrewRingDragPresentation?)
    case commitDrag(CrewRingDragPresentation)
  }

  private enum Target {
    case task(String)
    case overflow
  }

  private weak var coordinateView: NSView?
  private let snapshot: @MainActor () -> Snapshot
  private let onAction: @MainActor (Action) -> Void
  private var primaryClickGestureRecognizer: NSClickGestureRecognizer?
  private var primaryPanGestureRecognizer: NSPanGestureRecognizer?
  private var state = StatusItemGestureState()

  init(
    coordinateView: NSView,
    snapshot: @escaping @MainActor () -> Snapshot,
    onAction: @escaping @MainActor (Action) -> Void
  ) {
    self.coordinateView = coordinateView
    self.snapshot = snapshot
    self.onAction = onAction
  }

  func install(on button: NSStatusBarButton) {
    button.target = self
    button.action = #selector(handleStatusItemAction(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])

    let primaryClick = NSClickGestureRecognizer(
      target: self,
      action: #selector(handlePrimaryClick(_:))
    )
    primaryClick.delegate = self
    button.addGestureRecognizer(primaryClick)
    primaryClickGestureRecognizer = primaryClick

    let primaryPan = NSPanGestureRecognizer(
      target: self,
      action: #selector(handlePrimaryPan(_:))
    )
    primaryPan.delegate = self
    button.addGestureRecognizer(primaryPan)
    primaryPanGestureRecognizer = primaryPan
  }

  func handleSecondaryAction(
    eventType: NSEvent.EventType,
    identity: StatusItemActionEventIdentity,
    at point: NSPoint
  ) {
    guard state.shouldHandleSecondaryAction(
      eventType: eventType,
      identity: identity
    ) else { return }
    handleClick(at: point, isSecondaryClick: true)
  }

  func handleClick(at point: NSPoint, isSecondaryClick: Bool) {
    cancelDrag()
    #if DEBUG
      debugGesture(
        kind: isSecondaryClick ? "secondary-click" : "primary-click",
        state: .recognized,
        point: point,
        translation: .zero
      )
    #endif
    guard let coordinateView, coordinateView.bounds.contains(point) else { return }
    let snapshot = snapshot()
    let target = target(at: point, snapshot: snapshot)
    let clickedTaskID: String? = target.flatMap { target in
      guard case .task(let taskID) = target else { return nil }
      return taskID
    }
    let intent = StatusItemClickPolicy.intent(
      isSecondaryClick: isSecondaryClick,
      target: clickTarget(for: target),
      taskOpenMouseButton: snapshot.taskOpenMouseButton
    )
    if intent == .openTask, let clickedTaskID {
      onAction(.clearHover)
      #if DEBUG
        if ProcessInfo.processInfo.environment["CODEX_ECHO_DEBUG_EVENTS"] == "1" {
          print(
            "STATUS_TASK_OPEN task=\(clickedTaskID) "
              + "source=\(snapshot.taskOpenMouseButton.rawValue)-click"
          )
        }
      #endif
      onAction(.openTask(taskID: clickedTaskID))
      return
    }

    if intent == .showOverflowMenu {
      onAction(.presentOverflowMenu)
      return
    }

    onAction(.presentContextMenu(taskID: clickedTaskID))
  }

  func beginDrag(at mouseDownPoint: NSPoint) {
    cancelDrag()
    guard let coordinateView, coordinateView.bounds.contains(mouseDownPoint),
      case .task(let taskID) = target(at: mouseDownPoint, snapshot: snapshot())
    else { return }
    state.beginDrag(taskID: taskID)
  }

  func updateDrag(
    translation: CGSize,
    inputPhase: CrewRingDragInputPhase
  ) {
    switch state.updateDrag(
      translation: translation,
      inputPhase: inputPhase,
      visibleTaskIDs: snapshot().taskIDs
    ) {
    case .unchanged:
      break
    case .activated(let presentation):
      onAction(.clearHover)
      onAction(.updateDrag(presentation))
      #if DEBUG
        if ProcessInfo.processInfo.environment["CODEX_ECHO_DEBUG_EVENTS"] == "1" {
          print(
            "STATUS_RING_DRAG_BEGIN task=\(presentation.taskID) "
              + "source=\(presentation.sourceIndex)"
          )
        }
      #endif
    case .changed(let presentation):
      onAction(.updateDrag(presentation))
    case .cancelled:
      onAction(.updateDrag(nil))
    }
  }

  @discardableResult
  func finishDrag() -> Bool {
    let hadDragSequence = state.hasDragSequence
    guard let presentation = state.finishDrag() else {
      if hadDragSequence { onAction(.updateDrag(nil)) }
      return false
    }
    onAction(.commitDrag(presentation))
    #if DEBUG
      if ProcessInfo.processInfo.environment["CODEX_ECHO_DEBUG_EVENTS"] == "1" {
        print(
          "STATUS_RING_DRAG_END task=\(presentation.taskID) "
            + "source=\(presentation.sourceIndex) "
            + "destination=\(presentation.destinationIndex)"
        )
      }
    #endif
    return true
  }

  func cancelDrag() {
    state.cancelDrag()
    onAction(.updateDrag(nil))
  }

  @objc
  private func handleStatusItemAction(_ sender: NSStatusBarButton) {
    guard let coordinateView, let event = NSApp.currentEvent,
      StatusItemSecondaryActionPolicy.canReadIdentity(for: event.type)
    else { return }
    handleSecondaryAction(
      eventType: event.type,
      identity: StatusItemActionEventIdentity(
        eventNumber: event.eventNumber,
        timestamp: event.timestamp
      ),
      at: coordinateView.convert(event.locationInWindow, from: nil)
    )
  }

  func gestureRecognizer(
    _ gestureRecognizer: NSGestureRecognizer,
    shouldAttemptToRecognizeWith event: NSEvent
  ) -> Bool {
    guard gestureRecognizer === primaryClickGestureRecognizer
      || gestureRecognizer === primaryPanGestureRecognizer
    else { return true }
    let isCommandModified = event.modifierFlags.contains(.command)
    guard !isCommandModified else { return false }
    guard gestureRecognizer === primaryPanGestureRecognizer else { return true }
    guard let coordinateView,
      event.windowNumber == coordinateView.window?.windowNumber
    else { return false }
    let point = coordinateView.convert(event.locationInWindow, from: nil)
    guard coordinateView.bounds.contains(point) else { return false }
    return StatusItemPrimaryGesturePolicy.shouldAttemptPan(
      isCommandModified: isCommandModified,
      target: clickTarget(for: target(at: point, snapshot: snapshot()))
    )
  }

  func gestureRecognizer(
    _ gestureRecognizer: NSGestureRecognizer,
    shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer
  ) -> Bool {
    gestureRecognizer === primaryClickGestureRecognizer
      && otherGestureRecognizer === primaryPanGestureRecognizer
  }

  @objc
  private func handlePrimaryClick(_ gestureRecognizer: NSClickGestureRecognizer) {
    guard let coordinateView else { return }
    let point = gestureRecognizer.location(in: coordinateView)
    handleClick(at: point, isSecondaryClick: false)
  }

  @objc
  private func handlePrimaryPan(_ gestureRecognizer: NSPanGestureRecognizer) {
    guard let coordinateView else { return }
    let panTranslation = gestureRecognizer.translation(in: coordinateView)
    let translation = CGSize(width: panTranslation.x, height: panTranslation.y)
    switch gestureRecognizer.state {
    case .began:
      let location = gestureRecognizer.location(in: coordinateView)
      beginDrag(
        at: NSPoint(x: location.x - translation.width, y: location.y - translation.height)
      )
      updateDrag(translation: translation, inputPhase: .dragged)
    case .changed:
      updateDrag(translation: translation, inputPhase: .dragged)
    case .ended:
      updateDrag(translation: translation, inputPhase: .released)
      _ = finishDrag()
    case .cancelled, .failed:
      cancelDrag()
    case .possible:
      break
    @unknown default:
      cancelDrag()
    }

    #if DEBUG
      debugGesture(
        kind: "primary-pan",
        state: gestureRecognizer.state,
        point: gestureRecognizer.location(in: coordinateView),
        translation: translation
      )
    #endif
  }

  private func target(at point: NSPoint, snapshot: Snapshot) -> Target? {
    switch WorkerCrewLayout.hitTarget(
      at: point.x,
      displayedCrewCount: snapshot.taskIDs.count,
      overflowCount: snapshot.overflowCount,
      capacityRemainingPercent: snapshot.capacityRemainingPercent
    ) {
    case .crew(let index):
      return .task(snapshot.taskIDs[index])
    case .overflow:
      return .overflow
    case nil:
      return nil
    }
  }

  private func clickTarget(for target: Target?) -> StatusItemClickTarget {
    switch target {
    case .task:
      return .task
    case .overflow:
      return .overflow
    case nil:
      return .background
    }
  }

  #if DEBUG
    private func debugGesture(
      kind: String,
      state: NSGestureRecognizer.State,
      point: NSPoint,
      translation: CGSize
    ) {
      guard ProcessInfo.processInfo.environment["CODEX_ECHO_DEBUG_EVENTS"] == "1" else {
        return
      }
      let x = String(format: "%.1f", point.x)
      let y = String(format: "%.1f", point.y)
      let translationX = String(format: "%.1f", translation.width)
      let translationY = String(format: "%.1f", translation.height)
      print(
        "STATUS_POINTER_GESTURE kind=\(kind) state=\(state.rawValue) "
          + "x=\(x) y=\(y) tx=\(translationX) ty=\(translationY) "
          + "drag=\(self.state.debugDragState)"
      )
    }
  #endif
}
