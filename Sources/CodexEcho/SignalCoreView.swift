import AppKit
import CodexIPC
import Combine
import Foundation
import SwiftUI

@MainActor
final class StatusItemInteractionModel: ObservableObject {
  @Published var hoveredTaskID: String?
  @Published var ringDrag: CrewRingDragPresentation?
  var openTask: ((TaskPresentation) -> Void)?
  var showOverflowMenu: (() -> Void)?
  var openSettings: (() -> Void)?
}

struct CrewRingDragPresentation: Equatable {
  let taskID: String
  let sourceIndex: Int
  let destinationIndex: Int
  let translationX: CGFloat
}

enum CrewRingDragInputPhase {
  case dragged
  case released
}

enum CrewRingDragActivation {
  static func shouldStart(
    translation: CGSize,
    inputPhase: CrewRingDragInputPhase
  ) -> Bool {
    guard inputPhase == .dragged else { return false }
    return CrewRingDragLayout.hasExitedClickSlop(translation: translation)
  }
}

enum CrewRingDragLayout {
  static let activationDistance: CGFloat = 4

  static func hasExitedClickSlop(translation: CGSize) -> Bool {
    abs(translation.width) >= activationDistance
  }

  static func destinationIndex(
    sourceIndex: Int,
    translationX: CGFloat,
    taskCount: Int
  ) -> Int {
    guard taskCount > 0 else { return sourceIndex }
    let stride = WorkerCrewLayout.taskStride
    let translatedIndex = CGFloat(sourceIndex) + translationX / stride
    let nearestIndex = Int(translatedIndex.rounded())
    return min(max(nearestIndex, 0), taskCount - 1)
  }

  static func offset(
    forIndex index: Int,
    sourceIndex: Int,
    destinationIndex: Int,
    translationX: CGFloat
  ) -> CGFloat {
    if index == sourceIndex { return translationX }

    let stride = WorkerCrewLayout.taskStride
    if sourceIndex < destinationIndex,
      index > sourceIndex,
      index <= destinationIndex
    {
      return -stride
    }
    if destinationIndex < sourceIndex,
      index >= destinationIndex,
      index < sourceIndex
    {
      return stride
    }
    return 0
  }
}

struct SignalCoreLabel: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openSettings) private var openSettings

  @ObservedObject var model: CodexActivityModel
  @ObservedObject var interaction: StatusItemInteractionModel
  @ObservedObject var settings: MenuBarSettings

  var body: some View {
    let crews = displayedCrews
    let overflowTasks = model.overflowCrewTasks
    let overflowCount = overflowTasks.count
    let overflowUnreadCompletionCount = overflowTasks.count(where: \.showsUnreadCompletionSignal)
    let overflowAttentionCount = overflowTasks.count(where: { $0.state.requiresAttention })
    let projectedTasks = model.menuTasks
    let projectedActiveTaskCount = projectedTasks.count(where: { $0.state.isActive })
    let projectedActiveSubagentCount = projectedTasks.reduce(0) {
      $0 + $1.activeSubagentCount
    }
    let capacityRemainingPercent =
      settings.showsCapacityInMenuBar
      ? model.codexUsageSnapshot?.remainingPercent
      : nil
    let healthMode = connectionHealthMode
    let fallbackSymbolName = model.statusPresentation.fallbackSymbolName
    let motionReduced = effectiveReduceMotion
    TimelineView(
      .animation(
        minimumInterval: WorkerCrewMotion.minimumInterval(for: crews),
        paused: !WorkerCrewMotion.shouldAnimate(
          tasks: crews,
          hasUnreadOverflow: overflowUnreadCompletionCount > 0,
          hasAttentionOverflow: overflowAttentionCount > 0,
          reduceMotion: motionReduced
        )
      )
    ) { timeline in
      WorkerCrewRow(
        crews: crews,
        fallbackMode: fallbackMode,
        fallbackSymbolName: fallbackSymbolName,
        hoveredTaskID: interaction.hoveredTaskID,
        overflowCount: overflowCount,
        overflowUnreadCompletionCount: overflowUnreadCompletionCount,
        overflowAttentionCount: overflowAttentionCount,
        capacityRemainingPercent: capacityRemainingPercent,
        healthMode: crews.isEmpty ? nil : healthMode,
        ringDrag: interaction.ringDrag,
        fallbackAccessibilityLabel: fallbackAccessibilityLabel,
        healthAccessibilityLabel: healthAccessibilityLabel,
        phase: WorkerCrewMotion.phase(
          for: timeline.date,
          reduceMotion: motionReduced
        ),
        reduceMotion: motionReduced,
        onOpenTask: { task in interaction.openTask?(task) },
        onOpenOverflow: { interaction.showOverflowMenu?() }
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Codex Tasks")
      .accessibilityValue(
        "\(projectedActiveTaskCount) active tasks, "
          + "\(projectedActiveSubagentCount) active subagents"
      )
    }
    .frame(
      width: WorkerCrewLayout.contentWidth(
        forDisplayedCrewCount: crews.count,
        overflowCount: overflowCount,
        capacityRemainingPercent: capacityRemainingPercent,
        showsHealthBadge: !crews.isEmpty && healthMode != nil
      ),
      height: 22
    )
    .onAppear {
      let openSettings = openSettings
      interaction.openSettings = { openSettings() }
    }
  }

  private var displayedCrews: [TaskPresentation] {
    model.statusBarTasks
  }

  private var effectiveReduceMotion: Bool {
    #if DEBUG
      if ProcessInfo.processInfo.environment[
        "CODEX_ECHO_DEBUG_REDUCE_MOTION"
      ] == "1" {
        return true
      }
    #endif
    return reduceMotion
  }

  private var fallbackMode: WorkerCoreMode {
    guard case .connection(let health) = model.statusPresentation else {
      return .disconnected
    }
    switch health {
    case .offline:
      return .disconnected
    case .incompatible:
      return .incompatible
    case .degraded:
      return .degraded
    case .connecting:
      return .idle
    case .live:
      if model.tasks.contains(where: { $0.state == .needsApproval }) { return .approval }
      if model.tasks.contains(where: { $0.state == .needsInput }) { return .attention }
      if model.tasks.contains(where: { $0.state == .blocked }) { return .blocked }
      if model.tasks.contains(where: { $0.state == .ready }) { return .ready }
      return .idle
    }
  }

  private var connectionHealthMode: WorkerCoreMode? {
    switch model.statusPresentation {
    case .connection(.degraded): .degraded
    case .connection(.incompatible): .incompatible
    case .connection, .desktopAppNotInstalled, .desktopAppNotRunning,
      .desktopAppLaunching, .desktopAppLaunchFailed: nil
    }
  }

  private var fallbackAccessibilityLabel: String {
    model.statusPresentation.accessibilityLabel
  }

  private var healthAccessibilityLabel: String? {
    switch model.statusPresentation {
    case .connection(.degraded), .connection(.incompatible):
      model.statusPresentation.accessibilityLabel
    case .connection, .desktopAppNotInstalled, .desktopAppNotRunning,
      .desktopAppLaunching, .desktopAppLaunchFailed: nil
    }
  }
}

enum WorkerCrewMotion {
  static let reducedMotionPhase: TimeInterval = 0.25

  static func phase(for date: Date, reduceMotion: Bool) -> TimeInterval {
    reduceMotion ? reducedMotionPhase : date.timeIntervalSinceReferenceDate
  }

  static func shouldAnimate(
    tasks: [TaskPresentation],
    hasUnreadOverflow: Bool = false,
    hasAttentionOverflow: Bool = false,
    reduceMotion: Bool
  ) -> Bool {
    !reduceMotion
      && (hasUnreadOverflow || hasAttentionOverflow || tasks.contains(where: isAnimated))
  }

  static func isAnimated(_ task: TaskPresentation) -> Bool {
    task.state == .working || task.state.requiresAttention || task.showsUnreadCompletionSignal
  }

  static func minimumInterval(for tasks: [TaskPresentation]) -> TimeInterval {
    tasks.contains(where: { $0.state == .working }) ? 1.0 / 60.0 : 1.0 / 30.0
  }

  static func breathingOpacity(
    for phase: TimeInterval,
    duration: TimeInterval,
    minimumOpacity: Double,
    reduceMotion: Bool
  ) -> Double {
    guard !reduceMotion else { return 1 }
    let progress = phase.truncatingRemainder(dividingBy: duration) / duration
    let eased = (cos(progress * .pi * 2) + 1) / 2
    return minimumOpacity + (1 - minimumOpacity) * eased
  }
}

enum WorkerCrewLayout {
  static let cellWidth = WorkerCrewRingGeometry.signalCoreDiameter
  static let taskHitTargetWidth: CGFloat = 22
  static let taskSpacing: CGFloat = 15
  static let healthWidth: CGFloat = 16
  static let spacing: CGFloat = 8
  static let summarySpacing = taskSpacing
  static let summaryContentSpacing: CGFloat = 4
  static let summaryHorizontalPadding: CGFloat = 5
  static let summaryDividerWidth: CGFloat = 1
  static let taskStride = cellWidth + taskSpacing

  static func taskGroupWidth(for count: Int) -> CGFloat {
    CGFloat(count) * cellWidth
      + CGFloat(max(count - 1, 0)) * taskSpacing
  }

  static func contentWidth(
    forCrewCount count: Int,
    maximumVisibleCrews: Int = StatusItemTaskPolicy.visibleLimit,
    capacityRemainingPercent: Int? = nil,
    showsHealthBadge: Bool = false
  ) -> CGFloat {
    contentWidth(
      forDisplayedCrewCount: min(count, maximumVisibleCrews),
      overflowCount: max(count - maximumVisibleCrews, 0),
      capacityRemainingPercent: capacityRemainingPercent,
      showsHealthBadge: showsHealthBadge
    )
  }

  static func contentWidth(
    forDisplayedCrewCount visibleCount: Int,
    overflowCount: Int,
    capacityRemainingPercent: Int? = nil,
    showsHealthBadge: Bool = false
  ) -> CGFloat {
    let renderedTaskOrFallbackCount = max(visibleCount, 1)
    let hasOverflow = overflowCount > 0
    let hasSummary = hasOverflow || capacityRemainingPercent != nil
    return taskGroupWidth(for: renderedTaskOrFallbackCount)
      + (hasSummary ? summarySpacing : 0)
      + summaryWidth(
        overflowCount: overflowCount,
        capacityRemainingPercent: capacityRemainingPercent
      )
      + (showsHealthBadge ? spacing + healthWidth : 0)
  }

  static func summaryWidth(
    overflowCount: Int,
    capacityRemainingPercent: Int?
  ) -> CGFloat {
    let hasOverflow = overflowCount > 0
    guard hasOverflow || capacityRemainingPercent != nil else { return 0 }

    var width = summaryHorizontalPadding * 2
    if hasOverflow {
      width += summaryTextWidth(
        "+\(max(overflowCount, 0))",
        weight: .black
      )
    }
    if let capacityRemainingPercent {
      if hasOverflow {
        width += summaryContentSpacing * 2 + summaryDividerWidth
      }
      width += summaryTextWidth(
        "\(min(max(capacityRemainingPercent, 0), 100))%",
        weight: .semibold
      )
    }
    return width.rounded(.up)
  }

  static func summaryRange(
    displayedCrewCount: Int,
    overflowCount: Int,
    capacityRemainingPercent: Int?
  ) -> ClosedRange<CGFloat>? {
    guard overflowCount > 0 || capacityRemainingPercent != nil else { return nil }
    let renderedTaskOrFallbackCount = max(displayedCrewCount, 1)
    let start = taskGroupWidth(for: renderedTaskOrFallbackCount) + summarySpacing
    let width = summaryWidth(
      overflowCount: overflowCount,
      capacityRemainingPercent: capacityRemainingPercent
    )
    return start...(start + width)
  }

  static func hitTarget(
    at x: CGFloat,
    displayedCrewCount: Int,
    overflowCount: Int,
    capacityRemainingPercent: Int? = nil
  ) -> WorkerCrewHitTarget? {
    guard x >= 0 else { return nil }
    let stride = taskStride
    if displayedCrewCount > 0 {
      let crewIndex = Int(x / stride)
      let offsetWithinCrewCell = x - CGFloat(crewIndex) * stride
      if crewIndex >= 0,
        crewIndex < displayedCrewCount,
        offsetWithinCrewCell <= taskHitTargetWidth
      {
        return .crew(crewIndex)
      }
    }

    guard overflowCount > 0,
      let summaryRange = summaryRange(
        displayedCrewCount: displayedCrewCount,
        overflowCount: overflowCount,
        capacityRemainingPercent: capacityRemainingPercent
      )
    else { return nil }
    if summaryRange.contains(x) {
      return .overflow
    }
    return nil
  }

  private static func summaryTextWidth(
    _ text: String,
    weight: NSFont.Weight
  ) -> CGFloat {
    let baseFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: weight)
    let font = baseFont.fontDescriptor.withDesign(.rounded)
      .flatMap { NSFont(descriptor: $0, size: 9) }
      ?? baseFont
    return (text as NSString)
      .size(withAttributes: [.font: font])
      .width
      .rounded(.up)
  }
}

enum WorkerCrewHitTarget: Equatable {
  case crew(Int)
  case overflow
}

enum StatusItemHoverTarget: Equatable {
  case task(Int)
  case summary
}

enum StatusItemHoverPolicy {
  static func target(
    at x: CGFloat,
    displayedCrewCount: Int,
    overflowCount: Int,
    capacityRemainingPercent: Int?
  ) -> StatusItemHoverTarget? {
    switch WorkerCrewLayout.hitTarget(
      at: x,
      displayedCrewCount: displayedCrewCount,
      overflowCount: overflowCount,
      capacityRemainingPercent: capacityRemainingPercent
    ) {
    case .crew(let index):
      return .task(index)
    case .overflow:
      return .summary
    case nil:
      guard
        let summaryRange = WorkerCrewLayout.summaryRange(
          displayedCrewCount: displayedCrewCount,
          overflowCount: overflowCount,
          capacityRemainingPercent: capacityRemainingPercent
        ),
        summaryRange.contains(x)
      else { return nil }
      return .summary
    }
  }
}

extension CodexTaskActivityState {
  var showsCrewRing: Bool { self != .idle }
}

enum WorkerCoreMode: String {
  case idle
  case working
  case approval
  case attention
  case blocked
  case ready
  case degraded
  case incompatible
  case disconnected

  var accent: Color { .primary }

  var usesFilledBadge: Bool {
    self == .approval || self == .attention || self == .blocked || self == .incompatible
  }

  var requiresAttention: Bool {
    self == .approval || self == .attention || self == .blocked
  }
}

enum WorkerRingContour: Equatable {
  case circular
  case smoothWave
  case facetedWave
}

enum WorkerCrewRingGeometry {
  static let animationDuration: TimeInterval = 1.2
  static let signalPulseDuration: TimeInterval = 2.0
  static let signalHaloMinimumOpacity = 0.35
  static let signalHaloDiameter: CGFloat = 20
  static let signalHaloLineWidth: CGFloat = 1.1
  static let reducedMotionSignalHaloLineWidth: CGFloat = 1.7
  static let signalCoreDiameter: CGFloat = 16
  static let lineWidth: CGFloat = 3
  static let diameter = signalCoreDiameter - lineWidth
  static let smoothWaveAmplitude: CGFloat = 1.4
  static let facetedWaveAmplitude: CGFloat = 2.0
  static let maximumWaveAmplitude = Swift.max(
    smoothWaveAmplitude,
    facetedWaveAmplitude
  )
  static let smoothWaveCount: CGFloat = 7
  static let facetedWaveCount: CGFloat = 6
  static let contourSampleCount = 96

  static func contour(
    for _: CodexTaskCurrentActivity?
  ) -> WorkerRingContour {
    .circular
  }

  static func renderedLineWidth(for _: WorkerRingContour) -> CGFloat {
    lineWidth
  }

  static func renderedDiameter(for _: WorkerRingContour) -> CGFloat {
    diameter
  }

  static func waveCount(for contour: WorkerRingContour) -> CGFloat {
    switch contour {
    case .circular: return 0
    case .smoothWave: return smoothWaveCount
    case .facetedWave: return facetedWaveCount
    }
  }

  static func waveAmplitude(for contour: WorkerRingContour) -> CGFloat {
    switch contour {
    case .circular: return 0
    case .smoothWave: return smoothWaveAmplitude
    case .facetedWave: return facetedWaveAmplitude
    }
  }

  static func lineJoin(for contour: WorkerRingContour) -> CGLineJoin {
    contour == .facetedWave ? .miter : .round
  }

  static func radialInset(
    for contour: WorkerRingContour,
    fraction: CGFloat
  ) -> CGFloat {
    guard contour != .circular else { return 0 }
    let wrappedFraction = fraction - floor(fraction)
    let wavePosition = wrappedFraction * waveCount(for: contour)
    let localWaveFraction = wavePosition - floor(wavePosition)
    let outerFraction: CGFloat
    switch contour {
    case .circular:
      return 0
    case .smoothWave:
      outerFraction = (cos(localWaveFraction * .pi * 2) + 1) / 2
    case .facetedWave:
      outerFraction = abs(localWaveFraction * 2 - 1)
    }
    return waveAmplitude(for: contour) * (1 - outerFraction)
  }

  static func usesStationaryContourMask(
    for contour: WorkerRingContour
  ) -> Bool {
    contour != .circular
  }

  static func contourMaskLineWidth(ringLineWidth: CGFloat) -> CGFloat {
    ringLineWidth + maximumWaveAmplitude * 2
  }

  static func contourPath(
    for contour: WorkerRingContour,
    in rect: CGRect
  ) -> Path {
    guard contour != .circular else { return Path(ellipseIn: rect) }
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let outerRadius = min(rect.width, rect.height) / 2
    var path = Path()
    let sampleCount = contour == .facetedWave
      ? Int(waveCount(for: contour) * 2)
      : contourSampleCount
    for index in 0...sampleCount {
      let fraction = CGFloat(index) / CGFloat(sampleCount)
      let angle = fraction * .pi * 2
      let radius = outerRadius - radialInset(for: contour, fraction: fraction)
      let point = CGPoint(
        x: center.x + cos(angle) * radius,
        y: center.y + sin(angle) * radius
      )
      if index == 0 {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }
    path.closeSubpath()
    return path
  }

  static func rotationDegrees(for phase: TimeInterval) -> Double {
    phase.truncatingRemainder(dividingBy: animationDuration)
      / animationDuration * 360
  }

  static func signalHaloOpacity(
    for mode: WorkerCoreMode,
    isUnreadCompletion: Bool,
    phase: TimeInterval,
    reduceMotion: Bool
  ) -> Double? {
    guard mode.requiresAttention || (mode == .ready && isUnreadCompletion) else {
      return nil
    }
    return WorkerCrewMotion.breathingOpacity(
      for: phase,
      duration: signalPulseDuration,
      minimumOpacity: signalHaloMinimumOpacity,
      reduceMotion: reduceMotion
    )
  }

  static func signalHaloLineWidth(reduceMotion: Bool) -> CGFloat {
    reduceMotion ? reducedMotionSignalHaloLineWidth : signalHaloLineWidth
  }

  static func activeSegmentCount(subagentCount: Int) -> Int {
    min(max(subagentCount, 0), 8) + 1
  }

  static func activeSegmentLength(subagentCount: Int) -> CGFloat {
    let count = activeSegmentCount(subagentCount: subagentCount)
    let activeCoverage: CGFloat = subagentCount == 0 ? 0.68 : 0.60
    return activeCoverage / CGFloat(count)
  }

  static func activeSegmentStart(index: Int, subagentCount: Int) -> CGFloat {
    CGFloat(index) / CGFloat(activeSegmentCount(subagentCount: subagentCount))
  }

  static func trackOpacity(for mode: WorkerCoreMode) -> Double {
    switch mode {
    case .working: 0.20
    case .approval, .attention: 1.0
    case .blocked: 0.52
    case .ready: 1.0
    case .degraded: 0.64
    case .incompatible: 1.0
    case .idle: 0.62
    case .disconnected: 0.26
    }
  }

  static func trackDash(for mode: WorkerCoreMode) -> [CGFloat] {
    switch mode {
    case .approval, .attention, .blocked: [3, 2]
    case .degraded: [2, 2]
    case .incompatible: []
    case .disconnected: [1.5, 2]
    case .idle: [6.2, 4]
    case .working, .ready: []
    }
  }
}

private struct WorkerRingContourShape: Shape {
  let contour: WorkerRingContour

  func path(in rect: CGRect) -> Path {
    WorkerCrewRingGeometry.contourPath(for: contour, in: rect)
  }
}

enum CrewOverflowBadgeGeometry {
  static let normalOutlineOpacity = 0.65
  static let unreadOutlineMinimumOpacity = 0.30
  static let unreadTextMinimumOpacity = 0.55
  static let normalLineWidth: CGFloat = 1.2
  static let unreadLineWidth: CGFloat = 1.6
  static let reducedMotionUnreadLineWidth: CGFloat = 2.2

  static func outlineOpacity(
    for phase: TimeInterval,
    hasUnreadCompletion: Bool,
    hasAttention: Bool = false,
    reduceMotion: Bool
  ) -> Double {
    guard hasUnreadCompletion || hasAttention else { return normalOutlineOpacity }
    return WorkerCrewMotion.breathingOpacity(
      for: phase,
      duration: WorkerCrewRingGeometry.signalPulseDuration,
      minimumOpacity: unreadOutlineMinimumOpacity,
      reduceMotion: reduceMotion
    )
  }

  static func textOpacity(
    for phase: TimeInterval,
    hasUnreadCompletion: Bool,
    hasAttention: Bool = false,
    reduceMotion: Bool
  ) -> Double {
    guard hasUnreadCompletion || hasAttention else { return 1 }
    return WorkerCrewMotion.breathingOpacity(
      for: phase,
      duration: WorkerCrewRingGeometry.signalPulseDuration,
      minimumOpacity: unreadTextMinimumOpacity,
      reduceMotion: reduceMotion
    )
  }

  static func lineWidth(
    hasUnreadCompletion: Bool,
    hasAttention: Bool = false,
    reduceMotion: Bool
  ) -> CGFloat {
    guard hasUnreadCompletion || hasAttention else { return normalLineWidth }
    return reduceMotion ? reducedMotionUnreadLineWidth : unreadLineWidth
  }
}

enum CrewOverflowAccessibility {
  static func detail(attentionCount: Int, unreadCompletionCount: Int) -> String? {
    var parts: [String] = []
    if attentionCount > 0 {
      parts.append(
        attentionCount == 1 ? "1 needs attention" : "\(attentionCount) need attention"
      )
    }
    if unreadCompletionCount > 0 {
      parts.append("\(unreadCompletionCount) completed unread")
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  static func label(
    overflowCount: Int,
    attentionCount: Int,
    unreadCompletionCount: Int
  ) -> String {
    let base = "\(overflowCount) more tasks"
    guard let detail = detail(
      attentionCount: attentionCount,
      unreadCompletionCount: unreadCompletionCount
    ) else { return base }
    return "\(base), \(detail)"
  }
}

enum CrewSummaryAccessibility {
  static func label(
    overflowCount: Int,
    attentionCount: Int,
    unreadCompletionCount: Int,
    capacityRemainingPercent: Int?
  ) -> String {
    var parts: [String] = []
    if overflowCount > 0 {
      parts.append(
        CrewOverflowAccessibility.label(
          overflowCount: overflowCount,
          attentionCount: attentionCount,
          unreadCompletionCount: unreadCompletionCount
        )
      )
    }
    if let capacityRemainingPercent {
      parts.append("Codex capacity \(capacityRemainingPercent) percent remaining")
    }
    return parts.joined(separator: ", ")
  }
}

private struct WorkerCrewRow: View {
  let crews: [TaskPresentation]
  let fallbackMode: WorkerCoreMode
  let fallbackSymbolName: String?
  let hoveredTaskID: String?
  let overflowCount: Int
  let overflowUnreadCompletionCount: Int
  let overflowAttentionCount: Int
  let capacityRemainingPercent: Int?
  let healthMode: WorkerCoreMode?
  let ringDrag: CrewRingDragPresentation?
  let fallbackAccessibilityLabel: String
  let healthAccessibilityLabel: String?
  let phase: TimeInterval
  let reduceMotion: Bool
  let onOpenTask: (TaskPresentation) -> Void
  let onOpenOverflow: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: WorkerCrewLayout.taskSpacing) {
        if crews.isEmpty {
          Group {
            if let fallbackSymbolName {
              WorkerFallbackSystemGlyph(systemName: fallbackSymbolName)
            } else {
              WorkerCrewGlyph(
                subagentCount: 0,
                mode: fallbackMode,
                phase: phase,
                reduceMotionOverride: reduceMotion
              )
            }
          }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(fallbackAccessibilityLabel)
        } else {
          ForEach(
            Array(crews.enumerated()),
            id: \.element.id
          ) { index, crew in
            let contour = WorkerCrewRingGeometry.contour(for: crew.currentActivity)
            let isDraggedRing = ringDrag?.taskID == crew.id
            WorkerCrewGlyph(
              subagentCount: crew.activeSubagentCount,
              mode: crew.state.workerCoreMode,
              phase: phase,
              contour: contour,
              accentColor: crew.effectiveColor,
              showsUnreadCompletionSignal: crew.showsUnreadCompletionSignal,
              isHovered: crew.id == hoveredTaskID,
              reduceMotionOverride: reduceMotion
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(crew.title)
            .accessibilityValue(crew.accessibilityValue)
            .accessibilityHint("Opens this task in Codex")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpenTask(crew) }
            .offset(x: dragOffset(for: crew, at: index))
            .zIndex(isDraggedRing ? 1 : 0)
            .animation(
              isDraggedRing ? nil : .easeOut(duration: 0.1),
              value: ringDrag?.destinationIndex
            )
          }
        }
      }

      if overflowCount > 0 || capacityRemainingPercent != nil {
        if overflowCount > 0 {
          CrewSummaryBadge(
            overflowCount: overflowCount,
            unreadCompletionCount: overflowUnreadCompletionCount,
            attentionCount: overflowAttentionCount,
            capacityRemainingPercent: capacityRemainingPercent,
            phase: phase,
            reduceMotion: reduceMotion
          )
          .padding(.leading, WorkerCrewLayout.summarySpacing)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(
            CrewSummaryAccessibility.label(
              overflowCount: overflowCount,
              attentionCount: overflowAttentionCount,
              unreadCompletionCount: overflowUnreadCompletionCount,
              capacityRemainingPercent: capacityRemainingPercent
            )
          )
          .accessibilityHint("Shows the remaining tasks")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { onOpenOverflow() }
        } else if let capacityRemainingPercent {
          CrewSummaryBadge(
            overflowCount: 0,
            unreadCompletionCount: 0,
            attentionCount: 0,
            capacityRemainingPercent: capacityRemainingPercent,
            phase: phase,
            reduceMotion: reduceMotion
          )
          .padding(.leading, WorkerCrewLayout.summarySpacing)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Codex capacity")
          .accessibilityValue("\(capacityRemainingPercent) percent remaining")
        }
      }

      if let healthMode {
        WorkerConnectionGlyph(mode: healthMode)
          .padding(.leading, WorkerCrewLayout.spacing)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(healthAccessibilityLabel ?? "Codex connection problem")
      }
    }
    .frame(
      width: WorkerCrewLayout.contentWidth(
        forDisplayedCrewCount: crews.count,
        overflowCount: overflowCount,
        capacityRemainingPercent: capacityRemainingPercent,
        showsHealthBadge: healthMode != nil
      ),
      height: 22
    )
  }

  private func dragOffset(for crew: TaskPresentation, at index: Int) -> CGFloat {
    guard let ringDrag,
      crews.indices.contains(ringDrag.sourceIndex),
      crews[ringDrag.sourceIndex].id == ringDrag.taskID
    else { return 0 }

    return CrewRingDragLayout.offset(
      forIndex: index,
      sourceIndex: ringDrag.sourceIndex,
      destinationIndex: ringDrag.destinationIndex,
      translationX: ringDrag.translationX
    )
  }

}

struct CrewSummaryBadge: View {
  let overflowCount: Int
  let unreadCompletionCount: Int
  let attentionCount: Int
  let capacityRemainingPercent: Int?
  let phase: TimeInterval
  let reduceMotion: Bool

  var body: some View {
    HStack(spacing: 4) {
      if overflowCount > 0 {
        Text("+\(overflowCount)")
          .font(.system(size: 9, weight: .black, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(Color.primary.opacity(overflowTextOpacity))
      }
      if overflowCount > 0, capacityRemainingPercent != nil {
        Rectangle()
          .fill(Color.primary.opacity(0.35))
          .frame(width: 1, height: 8)
      }
      if let capacityRemainingPercent {
        Text("\(capacityRemainingPercent)%")
          .font(.system(size: 9, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.primary)
      }
    }
    .padding(.horizontal, 5)
    .frame(height: 16)
    .background(
      Capsule().stroke(
        Color.primary.opacity(outlineOpacity),
        lineWidth: outlineLineWidth
      )
    )
    .frame(height: 22)
  }

  private var outlineOpacity: Double {
    CrewOverflowBadgeGeometry.outlineOpacity(
      for: phase,
      hasUnreadCompletion: unreadCompletionCount > 0,
      hasAttention: attentionCount > 0,
      reduceMotion: reduceMotion
    )
  }

  private var overflowTextOpacity: Double {
    CrewOverflowBadgeGeometry.textOpacity(
      for: phase,
      hasUnreadCompletion: unreadCompletionCount > 0,
      hasAttention: attentionCount > 0,
      reduceMotion: reduceMotion
    )
  }

  private var outlineLineWidth: CGFloat {
    CrewOverflowBadgeGeometry.lineWidth(
      hasUnreadCompletion: unreadCompletionCount > 0,
      hasAttention: attentionCount > 0,
      reduceMotion: reduceMotion
    )
  }
}

private struct WorkerFallbackSystemGlyph: View {
  let systemName: String

  var body: some View {
    Image(systemName: systemName)
      .symbolRenderingMode(.monochrome)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(.primary)
      .frame(width: WorkerCrewLayout.cellWidth, height: 22)
  }
}

struct WorkerCrewGlyph: View {
  let subagentCount: Int
  let mode: WorkerCoreMode
  let phase: TimeInterval
  var contour: WorkerRingContour = .circular
  var accentColor: TaskAccentColor? = nil
  var showsUnreadCompletionSignal = false
  var isHovered = false
  var reduceMotionOverride: Bool?

  var body: some View {
    WorkerCrewRing(
      subagentCount: subagentCount,
      mode: mode,
      phase: phase,
      contour: contour,
      accentColor: accentColor,
      showsUnreadCompletionSignal: showsUnreadCompletionSignal,
      isHovered: isHovered,
      reduceMotionOverride: reduceMotionOverride
    )
    .frame(width: WorkerCrewLayout.cellWidth, height: 22)
  }
}

extension CodexTaskActivityState {
  var workerCoreMode: WorkerCoreMode {
    switch self {
    case .working: .working
    case .needsApproval: .approval
    case .needsInput: .attention
    case .blocked: .blocked
    case .ready: .ready
    case .idle: .idle
    }
  }
}

private struct WorkerCrewRing: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion

  let subagentCount: Int
  let mode: WorkerCoreMode
  let phase: TimeInterval
  let contour: WorkerRingContour
  let accentColor: TaskAccentColor?
  let showsUnreadCompletionSignal: Bool
  let isHovered: Bool
  let reduceMotionOverride: Bool?

  var body: some View {
    ZStack {
      if let signalHaloOpacity {
        Circle()
          .stroke(
            Color.primary.opacity(signalHaloOpacity),
            lineWidth: WorkerCrewRingGeometry.signalHaloLineWidth(
              reduceMotion: motionReduced
            )
          )
          .frame(
            width: WorkerCrewRingGeometry.signalHaloDiameter,
            height: WorkerCrewRingGeometry.signalHaloDiameter
          )
      }

      if mode.usesFilledBadge {
        Circle()
          .fill(accent)
          .frame(
            width: WorkerCrewRingGeometry.signalCoreDiameter,
            height: WorkerCrewRingGeometry.signalCoreDiameter
          )
      } else if mode == .ready {
        Circle()
          .strokeBorder(
            accent.opacity(WorkerCrewRingGeometry.trackOpacity(for: mode)),
            style: StrokeStyle(
              lineWidth: ringLineWidth,
              lineCap: .round
            )
          )
          .frame(
            width: WorkerCrewRingGeometry.signalCoreDiameter,
            height: WorkerCrewRingGeometry.signalCoreDiameter
          )
      } else {
        Circle()
          .stroke(
            accent.opacity(WorkerCrewRingGeometry.trackOpacity(for: mode)),
            style: StrokeStyle(
              lineWidth: ringLineWidth,
              lineCap: .round,
              dash: trackDash
            )
          )
          .frame(width: ringDiameter, height: ringDiameter)
      }

      if mode == .working {
        ForEach(0..<activeSegmentCount, id: \.self) { index in
          activeSegment(for: index)
        }
      }

      centerContent
    }
    .frame(width: 22, height: 22)
  }

  @ViewBuilder
  private func activeSegment(for index: Int) -> some View {
    if WorkerCrewRingGeometry.usesStationaryContourMask(for: contour) {
      WorkerRingContourShape(contour: contour)
        .stroke(
          accent,
          style: StrokeStyle(
            lineWidth: ringLineWidth,
            lineCap: .butt,
            lineJoin: WorkerCrewRingGeometry.lineJoin(for: contour)
          )
        )
        .frame(width: ringDiameter, height: ringDiameter)
        .mask {
          Circle()
            .trim(
              from: activeSegmentStart(for: index),
              to: activeSegmentStart(for: index) + activeSegmentLength
            )
            .stroke(
              style: StrokeStyle(
                lineWidth: WorkerCrewRingGeometry.contourMaskLineWidth(
                  ringLineWidth: ringLineWidth
                ),
                lineCap: .butt
              )
            )
            .frame(width: ringDiameter, height: ringDiameter)
            .rotationEffect(.degrees(rotationDegrees - 90))
        }
    } else {
      WorkerRingContourShape(contour: contour)
        .trim(
          from: activeSegmentStart(for: index),
          to: activeSegmentStart(for: index) + activeSegmentLength
        )
        .stroke(
          accent,
          style: StrokeStyle(
            lineWidth: ringLineWidth,
            lineCap: .butt,
            lineJoin: WorkerCrewRingGeometry.lineJoin(for: contour)
          )
        )
        .frame(width: ringDiameter, height: ringDiameter)
        .rotationEffect(.degrees(rotationDegrees - 90))
    }
  }

  @ViewBuilder
  private var centerContent: some View {
    switch mode {
    case .approval:
      Text("!")
        .font(.system(size: 10, weight: .black, design: .rounded))
        .foregroundStyle(badgeForeground)
    case .attention:
      Text("?")
        .font(.system(size: 9, weight: .black, design: .rounded))
        .foregroundStyle(badgeForeground)
    case .blocked:
      Image(systemName: "xmark")
        .font(.system(size: 7, weight: .black))
        .foregroundStyle(badgeForeground)
    case .degraded:
      Text("!")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(accent)
    case .incompatible:
      Text("!")
        .font(.system(size: 9, weight: .black))
        .foregroundStyle(badgeForeground)
    case .disconnected:
      Circle()
        .stroke(accent.opacity(0.6), lineWidth: 1)
        .frame(width: 3.5, height: 3.5)
    case .idle, .working, .ready:
      EmptyView()
    }
  }

  private var rotationDegrees: Double {
    WorkerCrewRingGeometry.rotationDegrees(for: phase)
  }

  private var activeSegmentCount: Int {
    WorkerCrewRingGeometry.activeSegmentCount(subagentCount: subagentCount)
  }

  private var activeSegmentLength: CGFloat {
    WorkerCrewRingGeometry.activeSegmentLength(subagentCount: subagentCount)
  }

  private func activeSegmentStart(for index: Int) -> CGFloat {
    WorkerCrewRingGeometry.activeSegmentStart(index: index, subagentCount: subagentCount)
  }

  private var ringLineWidth: CGFloat {
    WorkerCrewRingGeometry.renderedLineWidth(for: contour)
  }

  private var ringDiameter: CGFloat {
    WorkerCrewRingGeometry.renderedDiameter(for: contour)
  }

  private var badgeForeground: Color {
    if let accentColor,
      let appearance = NSAppearance(named: badgeAppearanceName)
    {
      return Color(
        nsColor: TaskAccentBadgeContrast.foregroundColor(
          for: accentColor,
          appearance: appearance
        )
      )
    }
    return colorScheme == .dark ? .black : .white
  }

  private var badgeAppearanceName: NSAppearance.Name {
    switch (colorScheme, colorSchemeContrast) {
    case (.dark, .increased): .accessibilityHighContrastDarkAqua
    case (.dark, _): .darkAqua
    case (_, .increased): .accessibilityHighContrastAqua
    case (_, _): .aqua
    }
  }

  private var accent: Color {
    accentColor?.color ?? mode.accent
  }

  private var signalHaloOpacity: Double? {
    WorkerCrewRingGeometry.signalHaloOpacity(
      for: mode,
      isUnreadCompletion: isUnreadCompletion,
      phase: phase,
      reduceMotion: motionReduced
    )
  }

  private var motionReduced: Bool {
    reduceMotionOverride ?? environmentReduceMotion
  }

  private var isUnreadCompletion: Bool {
    mode == .ready && showsUnreadCompletionSignal
  }

  private var trackDash: [CGFloat] {
    WorkerCrewRingGeometry.trackDash(for: mode)
  }
}

private struct WorkerConnectionGlyph: View {
  let mode: WorkerCoreMode

  var body: some View {
    Image(
      systemName: mode == .incompatible
        ? "exclamationmark.triangle.fill"
        : "exclamationmark.triangle"
    )
    .symbolRenderingMode(.monochrome)
    .font(.system(size: 10, weight: .semibold))
    .foregroundStyle(.primary)
    .frame(width: WorkerCrewLayout.healthWidth, height: 22)
  }
}

#if DEBUG
  struct WorkerCoreVariantStrip: View {
    var body: some View {
      HStack(spacing: 12) {
        variant("1 CHAT", crews: [.init(subagents: 0, mode: .working)], phase: 0.75)
        variant(
          "HOVER",
          crews: [.init(subagents: 0, mode: .working, isHovered: true)],
          phase: 0.75
        )
        variant(
          "2 CHATS",
          crews: [.init(subagents: 0, mode: .working), .init(subagents: 3, mode: .working)],
          phase: 1.35
        )
        variant(
          "4 CHATS",
          crews: [
            .init(subagents: 0, mode: .working),
            .init(subagents: 1, mode: .working),
            .init(subagents: 2, mode: .working),
            .init(subagents: 4, mode: .working),
          ],
          phase: 0.95
        )
        variant("DONE", crews: [.init(subagents: 0, mode: .ready)], phase: 0)
        variant(
          "UNREAD",
          crews: [.init(subagents: 0, mode: .ready, showsUnreadCompletionSignal: true)],
          phase: 0
        )
        variant("APPROVAL", crews: [.init(subagents: 0, mode: .approval)], phase: 0)
        variant("INPUT", crews: [.init(subagents: 0, mode: .attention)], phase: 0)
        variant("ERROR", crews: [.init(subagents: 0, mode: .blocked)], phase: 0)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .background(Color.white)
      .environment(\.colorScheme, .light)
    }

    private func variant(
      _ label: String,
      crews: [WorkerCrewVariant],
      phase: TimeInterval
    ) -> some View {
      VStack(spacing: 3) {
        HStack(spacing: WorkerCrewLayout.taskSpacing) {
          ForEach(Array(crews.enumerated()), id: \.offset) { _, crew in
            WorkerCrewGlyph(
              subagentCount: crew.subagents,
              mode: crew.mode,
              phase: phase,
              showsUnreadCompletionSignal: crew.showsUnreadCompletionSignal,
              isHovered: crew.isHovered
            )
          }
        }
        .frame(height: 22)
        Text(label)
          .font(.system(size: 8, weight: .bold, design: .monospaced))
          .tracking(0.55)
          .foregroundStyle(.primary)
      }
    }
  }

  private struct WorkerCrewVariant {
    let subagents: Int
    let mode: WorkerCoreMode
    var showsUnreadCompletionSignal = false
    var isHovered = false
  }
#endif
