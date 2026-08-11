import AppKit

@MainActor
final class StatusItemAccessibilityController {
  enum MoveDirection: Equatable {
    case left
    case right
  }

  enum Action: Equatable {
    case showContextMenu
    case openTask(String)
    case moveTask(String, direction: MoveDirection)
    case hideTask(String)
    case showOverflowMenu
  }

  struct Task: Equatable {
    let id: String
    let title: String
    let value: String
    let canMoveLeft: Bool
    let canMoveRight: Bool
  }

  struct Snapshot: Equatable {
    let tasks: [Task]
    let overflowCount: Int
    let overflowAttentionCount: Int
    let overflowUnreadCompletionCount: Int
    let capacityRemainingPercent: Int?
    let showsHealth: Bool
    let statusLabel: String
  }

  private var elementsByKey: [String: StatusItemAccessibilityElement] = [:]

  func update(
    parent: NSView,
    coordinateView: NSView,
    snapshot: Snapshot,
    onAction: @escaping (Action) -> Bool
  ) {
    guard let window = coordinateView.window else { return }
    let hasSummary =
      snapshot.overflowCount > 0 || snapshot.capacityRemainingPercent != nil
    var x: CGFloat = 0
    var activeKeys = Set<String>()
    var orderedElements: [StatusItemAccessibilityElement] = []

    func appendElement(
      key: String,
      width: CGFloat,
      trailingSpacing: CGFloat = WorkerCrewLayout.spacing,
      role: NSAccessibility.Role,
      label: String,
      value: String? = nil,
      help: String? = nil,
      customActions: [NSAccessibilityCustomAction] = [],
      onPress: (() -> Void)? = nil
    ) {
      let localRect = NSRect(
        x: x,
        y: 0,
        width: width,
        height: coordinateView.bounds.height
      )
      let windowRect = coordinateView.convert(localRect, to: nil)
      let screenRect = window.convertToScreen(windowRect)
      let element = elementsByKey[key] ?? StatusItemAccessibilityElement()
      element.setAccessibilityIdentifier(key)
      element.setAccessibilityParent(parent)
      element.setAccessibilityRole(role)
      element.setAccessibilityLabel(label)
      element.setAccessibilityValue(value)
      element.setAccessibilityHelp(help)
      element.setAccessibilityCustomActions(customActions)
      element.setAccessibilityFrame(screenRect)
      element.onPress = onPress
      elementsByKey[key] = element
      activeKeys.insert(key)
      orderedElements.append(element)
      x += width + trailingSpacing
    }

    if snapshot.tasks.isEmpty {
      appendElement(
        key: "fallback",
        width: WorkerCrewLayout.cellWidth,
        trailingSpacing:
          hasSummary ? WorkerCrewLayout.summarySpacing : WorkerCrewLayout.spacing,
        role: .button,
        label: snapshot.statusLabel,
        help: "Shows the Codex task menu",
        onPress: { _ = onAction(.showContextMenu) }
      )
    } else {
      for (index, task) in snapshot.tasks.enumerated() {
        var customActions: [NSAccessibilityCustomAction] = []
        if task.canMoveLeft {
          customActions.append(
            NSAccessibilityCustomAction(name: "Move Left") {
              onAction(.moveTask(task.id, direction: .left))
            }
          )
        }
        if task.canMoveRight {
          customActions.append(
            NSAccessibilityCustomAction(name: "Move Right") {
              onAction(.moveTask(task.id, direction: .right))
            }
          )
        }
        customActions.append(
          NSAccessibilityCustomAction(name: "Hide") {
            onAction(.hideTask(task.id))
          }
        )
        let trailingSpacing = if index != snapshot.tasks.indices.last {
          WorkerCrewLayout.taskSpacing
        } else if hasSummary {
          WorkerCrewLayout.summarySpacing
        } else {
          WorkerCrewLayout.spacing
        }
        appendElement(
          key: "task:\(task.id)",
          width: WorkerCrewLayout.cellWidth,
          trailingSpacing: trailingSpacing,
          role: .button,
          label: task.title,
          value: task.value,
          help: "Opens this task in Codex",
          customActions: customActions,
          onPress: { _ = onAction(.openTask(task.id)) }
        )
      }
    }

    if snapshot.overflowCount > 0 {
      appendElement(
        key: "overflow",
        width: WorkerCrewLayout.summaryWidth(
          overflowCount: snapshot.overflowCount,
          capacityRemainingPercent: snapshot.capacityRemainingPercent
        ),
        role: .button,
        label: CrewSummaryAccessibility.label(
          overflowCount: snapshot.overflowCount,
          attentionCount: snapshot.overflowAttentionCount,
          unreadCompletionCount: snapshot.overflowUnreadCompletionCount,
          capacityRemainingPercent: snapshot.capacityRemainingPercent
        ),
        help: "Shows and manages the remaining tasks",
        onPress: { _ = onAction(.showOverflowMenu) }
      )
    } else if let remainingPercent = snapshot.capacityRemainingPercent {
      appendElement(
        key: "codex-capacity",
        width: WorkerCrewLayout.summaryWidth(
          overflowCount: 0,
          capacityRemainingPercent: remainingPercent
        ),
        role: .staticText,
        label: "Codex capacity",
        value: "\(remainingPercent) percent remaining"
      )
    }

    if snapshot.showsHealth {
      appendElement(
        key: "connection-health",
        width: WorkerCrewLayout.healthWidth,
        role: .staticText,
        label: snapshot.statusLabel
      )
    }

    elementsByKey = elementsByKey.filter { activeKeys.contains($0.key) }
    parent.setAccessibilityChildren(orderedElements)
  }
}

final class StatusItemAccessibilityElement: NSAccessibilityElement {
  var onPress: (() -> Void)?

  override func accessibilityPerformPress() -> Bool {
    guard let onPress else { return false }
    onPress()
    return true
  }
}
