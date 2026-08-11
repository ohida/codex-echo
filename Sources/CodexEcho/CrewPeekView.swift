import AppKit
import CodexIPC
import SwiftUI

enum CrewPeekMetrics {
  static let size = NSSize(width: 288, height: 72)
  static let gap: CGFloat = 6
  static let screenInset: CGFloat = 8
}

struct CrewPeekView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let task: TaskPresentation

  var body: some View {
    let motionReduced = effectiveReduceMotion
    let contour = WorkerCrewRingGeometry.contour(for: task.currentActivity)
    let secondaryTextFont = Font.callout
    HStack(spacing: 12) {
      TimelineView(
        .animation(
          minimumInterval: WorkerCrewMotion.minimumInterval(for: [task]),
          paused: !WorkerCrewMotion.shouldAnimate(
            tasks: [task],
            reduceMotion: motionReduced
          )
        )
      ) { timeline in
        WorkerCrewGlyph(
          subagentCount: task.activeSubagentCount,
          mode: task.state.workerCoreMode,
          phase: WorkerCrewMotion.phase(
            for: timeline.date,
            reduceMotion: motionReduced
          ),
          contour: contour,
          accentColor: task.effectiveColor,
          showsUnreadCompletionSignal: task.showsUnreadCompletionSignal,
          reduceMotionOverride: motionReduced
        )
      }
      .frame(width: 25, height: 25)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          if let projectColor = task.projectColor {
            Circle()
              .fill(projectColor.color)
              .frame(width: 6, height: 6)
              .accessibilityHidden(true)
          }
          Text(task.project ?? "Codex")
            .font(secondaryTextFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Text(task.title)
          .font(.body.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)

        TimelineView(
          .periodic(
            from: .now,
            by: TaskActivityPresentationTiming.elapsedRefreshInterval
          )
        ) { timeline in
          Text(task.hoverActivitySummary(relativeTo: timeline.date))
            .font(secondaryTextFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .frame(width: CrewPeekMetrics.size.width, height: CrewPeekMetrics.size.height)
    .crewPeekSurface()
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

}

struct CrewSummaryPeekPresentation: Equatable {
  let overflowCount: Int
  let unreadCompletionCount: Int
  let attentionCount: Int
  let capacityRemainingPercent: Int?
  let title: String
  let detailLines: [String]
  let systemImageName: String

  static func make(
    overflowCount: Int,
    attentionCount: Int,
    unreadCompletionCount: Int,
    capacityRemainingPercent: Int?,
    resetDescription: String?
  ) -> Self? {
    guard overflowCount > 0 || capacityRemainingPercent != nil else { return nil }

    var detailLines: [String] = []
    if let overflowDetail = compactOverflowDetail(
      attentionCount: attentionCount,
      unreadCompletionCount: unreadCompletionCount
    ) {
      detailLines.append(overflowDetail)
    }
    if let capacityRemainingPercent {
      let remainingDescription = "\(capacityRemainingPercent)% remaining"
      detailLines.append(
        overflowCount > 0
          ? "Codex Capacity · \(remainingDescription)"
          : remainingDescription
      )
      if let resetDescription {
        detailLines.append(resetDescription)
      }
    }

    return Self(
      overflowCount: overflowCount,
      unreadCompletionCount: unreadCompletionCount,
      attentionCount: attentionCount,
      capacityRemainingPercent: capacityRemainingPercent,
      title: overflowCount > 0 ? "\(overflowCount) More Tasks" : "Codex Capacity",
      detailLines: detailLines,
      systemImageName: overflowCount > 0 ? "ellipsis.circle" : "chart.pie"
    )
  }

  private static func compactOverflowDetail(
    attentionCount: Int,
    unreadCompletionCount: Int
  ) -> String? {
    var parts: [String] = []
    if attentionCount > 0 {
      parts.append(
        attentionCount == 1 ? "1 needs attention" : "\(attentionCount) need attention"
      )
    }
    if unreadCompletionCount > 0 {
      parts.append("\(unreadCompletionCount) unread")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  var hasAnimatedSignal: Bool {
    attentionCount > 0 || unreadCompletionCount > 0
  }
}

struct CrewSummaryPeekView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let presentation: CrewSummaryPeekPresentation

  var body: some View {
    HStack(spacing: 12) {
      TimelineView(
        .animation(
          minimumInterval: 1.0 / 30.0,
          paused: reduceMotion || !presentation.hasAnimatedSignal
        )
      ) { timeline in
        CrewSummaryBadge(
          overflowCount: presentation.overflowCount,
          unreadCompletionCount: presentation.unreadCompletionCount,
          attentionCount: presentation.attentionCount,
          capacityRemainingPercent: presentation.capacityRemainingPercent,
          phase: WorkerCrewMotion.phase(
            for: timeline.date,
            reduceMotion: reduceMotion
          ),
          reduceMotion: reduceMotion
        )
      }
      .frame(
        width: WorkerCrewLayout.summaryWidth(
          overflowCount: presentation.overflowCount,
          capacityRemainingPercent: presentation.capacityRemainingPercent
        ),
        height: 22
      )
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text(presentation.title)
          .font(.body.weight(.semibold))
          .lineLimit(1)

        ForEach(presentation.detailLines, id: \.self) { line in
          Text(line)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .frame(width: CrewPeekMetrics.size.width, height: CrewPeekMetrics.size.height)
    .crewPeekSurface()
  }
}

private struct CrewPeekSurfaceModifier: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    content
      .background {
        if reduceTransparency {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
        } else {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.regularMaterial)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      }
  }
}

private extension View {
  func crewPeekSurface() -> some View {
    modifier(CrewPeekSurfaceModifier())
  }
}
