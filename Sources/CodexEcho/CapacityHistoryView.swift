import AppKit
import Accessibility
import Charts
import CodexAppServer
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum CapacityHistoryWindowMetrics {
  static let width: CGFloat = 760
  static let height: CGFloat = 500
  static let minimumWidth: CGFloat = 600
  static let minimumHeight: CGFloat = 380
  static let verticalPadding: CGFloat = 16
  static let sectionSpacing: CGFloat = 12
  static let minimumChartHeight: CGFloat = 140
}

enum CapacityHistoryChartMetrics {
  static let lineWidth: CGFloat = 2.5
  static let summaryLineWidth: CGFloat = 2.25
  static let summaryBandWidth: CGFloat = 8
  static let summaryBandOpacity = 0.12
  static let nowRuleWidth: CGFloat = 1
  static let nowRuleOpacity = 0.38
}

enum CapacityHistoryVisualSamplingPolicy {
  static let minimumHorizontalSpacing: CGFloat = 4
  static let fallbackPlotWidth: CGFloat = 520

  static func segments(
    _ segments: [CapacityHistorySegment],
    rangeStart: Date,
    rangeEnd: Date,
    plotWidth: CGFloat,
    minimumHorizontalSpacing: CGFloat = minimumHorizontalSpacing
  ) -> [CapacityHistorySegment] {
    let duration = rangeEnd.timeIntervalSince(rangeStart)
    guard duration > 0, minimumHorizontalSpacing > 0 else { return segments }
    let effectivePlotWidth = plotWidth > 0 ? plotWidth : fallbackPlotWidth
    let bucketCount = max(
      Int((effectivePlotWidth / minimumHorizontalSpacing).rounded(.down)),
      1
    )

    return segments.map { segment in
      CapacityHistorySegment(
        observations: sampledObservations(
          segment.observations,
          rangeStart: rangeStart,
          duration: duration,
          bucketCount: bucketCount
        )
      )
    }
  }

  private static func sampledObservations(
    _ observations: [CapacityObservation],
    rangeStart: Date,
    duration: TimeInterval,
    bucketCount: Int
  ) -> [CapacityObservation] {
    guard let first = observations.first, let last = observations.last else {
      return []
    }

    var changePoints = [first]
    for observation in observations.dropFirst() where
      observation.remainingPercent != changePoints.last?.remainingPercent
    {
      changePoints.append(observation)
    }

    var sampled: [CapacityObservation]
    if changePoints.count <= 2 {
      sampled = changePoints
    } else {
      sampled = [changePoints[0]]
      var pending: CapacityObservation?
      var pendingBucket: Int?
      for observation in changePoints.dropFirst() {
        let normalized = observation.observedAt.timeIntervalSince(rangeStart)
          / duration
        let bucket = min(
          max(Int(floor(normalized * Double(bucketCount))), 0),
          bucketCount - 1
        )
        if let pendingBucket, bucket != pendingBucket, let pending {
          if pending.id != sampled.last?.id {
            sampled.append(pending)
          }
        }
        pendingBucket = bucket
        pending = observation
      }
      if let pending, pending.id != sampled.last?.id {
        sampled.append(pending)
      }
    }

    // A same-value heartbeat extends the known segment without moving the
    // actual change to the heartbeat's later timestamp.
    if last.id != sampled.last?.id {
      sampled.append(last)
    }
    return sampled
  }
}

enum CapacityHistoryClearCopy {
  static let title = "Clear Capacity History?"
  static let actionTitle = "Clear History"
  static let message =
    "This permanently removes every locally recorded Capacity observation. Capacity display, history recording, and current monitoring continue unchanged."
}

enum CodexCapacityOverviewCopy {
  static let nextReset = "Next Reset"
  static let resetCredits = "Reset Credits"
  static let nextExpiration = "Next Expiration"
  static let showResetExpirations = "Show Reset Expirations"
  static let resetExpirations = "Reset Expirations"
}

enum CodexCapacityExpirationPopoverMetrics {
  static let maximumListHeight: CGFloat = 224
  static let rowHeight: CGFloat = 29
  static let scrollIndicatorClearance: CGFloat = 10

  static func requiresScrolling(rowCount: Int) -> Bool {
    CGFloat(max(rowCount, 0)) * rowHeight > maximumListHeight
  }
}

struct CodexCapacityExpirationPresentation: Equatable {
  let expiresAt: Date
  let text: String
}

struct CodexCapacityLimitResetPresentation: Equatable {
  let resetsAt: Date
  let label: String
  let text: String
}

struct CodexCapacityOverviewPresentation: Equatable {
  let remainingPercent: Int?
  let nextReset: CodexCapacityLimitResetPresentation?
  let availableResetCount: Int?
  let expirations: [CodexCapacityExpirationPresentation]

  var nextExpiration: CodexCapacityExpirationPresentation? {
    expirations.first
  }

  var reportedExpirationCount: Int {
    expirations.count
  }

  var expirationReportingNote: String? {
    guard
      let availableResetCount,
      reportedExpirationCount < availableResetCount
    else { return nil }
    return "\(reportedExpirationCount) of \(availableResetCount) expiration dates reported."
  }

  var showsExpirationDetails: Bool {
    reportedExpirationCount > 1 || expirationReportingNote != nil
  }

  static func make(
    snapshot: CodexUsageSnapshot?,
    windowDurationMinutes: Int? = nil,
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> Self {
    guard let snapshot else {
      return Self(
        remainingPercent: nil,
        nextReset: nil,
        availableResetCount: nil,
        expirations: []
      )
    }

    let availableResetCount = snapshot.rateLimitResetCredits.flatMap {
      $0.availableCount > 0 ? $0.availableCount : nil
    }
    let expirations = availableResetCount == nil
      ? []
      : makeExpirations(
        dates: snapshot.rateLimitResetCredits?.expirationDates ?? [],
        timeZone: timeZone
      )

    let window: CodexRateLimitWindow?
    if let windowDurationMinutes, windowDurationMinutes > 0 {
      window = snapshot.window(durationMinutes: windowDurationMinutes)
    } else {
      window = snapshot.constrainingWindow
    }

    return Self(
      remainingPercent: window?.remainingPercent,
      nextReset: window?.resetsAt.map { resetsAt in
        CodexCapacityLimitResetPresentation(
          resetsAt: resetsAt,
          label: CodexCapacityOverviewCopy.nextReset,
          text: CodexCapacityDateTimeCopy.string(
            resetsAt,
            timeZone: timeZone
          )
        )
      },
      availableResetCount: availableResetCount,
      expirations: expirations
    )
  }

  private static func makeExpirations(
    dates: [Date],
    timeZone: TimeZone
  ) -> [CodexCapacityExpirationPresentation] {
    dates.sorted().map {
      CodexCapacityExpirationPresentation(
        expiresAt: $0,
        text: CodexCapacityDateTimeCopy.string($0, timeZone: timeZone)
      )
    }
  }
}

enum CodexCapacityDateTimeCopy {
  static func string(
    _ date: Date,
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }

  static func accessibilityDescription(_ date: Date) -> String {
    CapacityHistoryDateTimeCopy.long(date)
  }
}

enum CapacityHistoryFreshnessCopy {
  static func label(observedAt: Date, now: Date) -> String {
    let elapsed = max(now.timeIntervalSince(observedAt), 0)
    if elapsed < 60 {
      return "Updated just now"
    }
    if elapsed < 60 * 60 {
      return "Updated \(Int(elapsed / 60)) min ago"
    }
    if elapsed < 24 * 60 * 60 {
      return "Updated \(Int(elapsed / (60 * 60))) hr ago"
    }
    return "Updated \(Int(elapsed / (24 * 60 * 60))) d ago"
  }

  static func lastRecordedLabel(observedAt: Date, now: Date) -> String {
    label(observedAt: observedAt, now: now)
      .replacingOccurrences(of: "Updated", with: "Last recorded")
  }
}

enum CapacityHistoryRecordingCopy {
  static let offStatus = "Recording Off"
  static let offSystemImage = "circle.slash"
  static let offEmptyTitle = "Capacity history recording is off"
  static let offEmptyDescription =
    "Turn on Record Capacity History in Capacity settings to save new observations locally."
}

enum CapacityHistoryAxisPolicy {
  private static let minimumEndpointLabelSeparation: CGFloat = 80

  static func tickDates(
    period: CapacityHistoryPeriod,
    rangeEnd: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> [Date] {
    tickDates(
      style: period.axisStyle,
      rangeStart: rangeEnd.addingTimeInterval(-period.duration),
      rangeEnd: rangeEnd,
      calendar: calendar
    )
  }

  static func tickDates(
    style: CapacityHistoryAxisStyle,
    rangeStart: Date,
    rangeEnd: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> [Date] {
    let step: Calendar.Component
    let stepCount: Int
    var candidate: Date

    switch style {
    case .hourlyWindow:
      step = .hour
      stepCount = 1
      var components = calendar.dateComponents(
        [.era, .year, .month, .day, .hour],
        from: rangeStart
      )
      components.minute = 0
      components.second = 0
      components.nanosecond = 0
      candidate = calendar.date(from: components) ?? rangeStart
    case .twentyFourHours:
      step = .hour
      stepCount = 6
      var components = calendar.dateComponents(
        [.era, .year, .month, .day, .hour],
        from: rangeStart
      )
      let hour = components.hour ?? 0
      components.hour = hour - (hour % stepCount)
      components.minute = 0
      components.second = 0
      components.nanosecond = 0
      candidate = calendar.date(from: components) ?? rangeStart
    case .sevenDays:
      step = .day
      stepCount = 1
      candidate = calendar.startOfDay(for: rangeStart)
    case .thirtyDays:
      step = .weekOfYear
      stepCount = 1
      candidate =
        calendar.dateInterval(of: .weekOfYear, for: rangeStart)?.start
        ?? calendar.startOfDay(for: rangeStart)
    }

    while candidate <= rangeStart {
      guard
        let next = calendar.date(
          byAdding: step,
          value: stepCount,
          to: candidate
        )
      else { return [rangeEnd] }
      candidate = next
    }

    var ticks: [Date] = []
    while candidate < rangeEnd {
      ticks.append(candidate)
      guard
        let next = calendar.date(
          byAdding: step,
          value: stepCount,
          to: candidate
        )
      else { break }
      candidate = next
    }
    ticks.append(rangeEnd)
    return ticks
  }

  static func displayTickDates(
    style: CapacityHistoryAxisStyle,
    rangeStart: Date,
    rangeEnd: Date,
    plotWidth: CGFloat,
    calendar: Calendar = .autoupdatingCurrent
  ) -> [Date] {
    var ticks = tickDates(
      style: style,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      calendar: calendar
    )
    guard ticks.count > 1 else { return ticks }

    let duration = rangeEnd.timeIntervalSince(rangeStart)
    guard duration > 0 else { return ticks }
    let effectivePlotWidth = plotWidth > 0
      ? plotWidth
      : CapacityHistoryVisualSamplingPolicy.fallbackPlotWidth
    let trailingInterval = rangeEnd.timeIntervalSince(ticks[ticks.count - 2])
    let trailingSeparation =
      CGFloat(max(trailingInterval, 0) / duration) * effectivePlotWidth
    if trailingSeparation < minimumEndpointLabelSeparation {
      ticks.remove(at: ticks.count - 2)
    }
    return ticks
  }
}

enum CapacityHistoryAxisLabelPolicy {
  private static let englishInterfaceLocale = Locale(identifier: "en_US")

  static func label(
    for date: Date,
    style: CapacityHistoryAxisStyle,
    calendar: Calendar = .autoupdatingCurrent
  ) -> String {
    switch style {
    case .hourlyWindow:
      return formattedTime(
        date,
        includesMinutes: true,
        calendar: calendar
      )
    case .twentyFourHours:
      if calendar.component(.hour, from: date) == 0 {
        return formatted(
          date,
          template: "MMMd",
          calendar: calendar
        )
      }
      return formattedTime(
        date,
        includesMinutes: false,
        calendar: calendar
      )
    case .sevenDays:
      return formatted(
        date,
        template: "EEEMMMd",
        calendar: calendar
      )
    case .thirtyDays:
      return formatted(
        date,
        template: "MMMd",
        calendar: calendar
      )
    }
  }

  private static func formatted(
    _ date: Date,
    template: String,
    calendar: Calendar
  ) -> String {
    var presentationCalendar = calendar
    presentationCalendar.locale = englishInterfaceLocale

    let formatter = DateFormatter()
    formatter.locale = englishInterfaceLocale
    formatter.calendar = presentationCalendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
  }

  private static func formattedTime(
    _ date: Date,
    includesMinutes: Bool,
    calendar: Calendar
  ) -> String {
    let locale = calendar.locale ?? .autoupdatingCurrent
    let sourceFormat = DateFormatter.dateFormat(
      fromTemplate: "j",
      options: 0,
      locale: locale
    ) ?? ""
    let usesTwentyFourHourClock =
      sourceFormat.contains("H") || sourceFormat.contains("k")

    var presentationCalendar = calendar
    presentationCalendar.locale = englishInterfaceLocale

    let formatter = DateFormatter()
    formatter.locale = englishInterfaceLocale
    formatter.calendar = presentationCalendar
    formatter.timeZone = calendar.timeZone
    switch (usesTwentyFourHourClock, includesMinutes) {
    case (true, true): formatter.dateFormat = "HH:mm"
    case (true, false): formatter.dateFormat = "HH"
    case (false, true): formatter.dateFormat = "h:mm a"
    case (false, false): formatter.dateFormat = "h a"
    }
    return formatter.string(from: date)
  }
}

enum CapacityHistoryExportDestinationPolicy {
  private static let completedExportKey =
    "CapacityHistory.hasCompletedCSVExport"

  static func initialDirectoryURL(
    userDefaults: UserDefaults,
    downloadsDirectoryURL: URL?
  ) -> URL? {
    guard !userDefaults.bool(forKey: completedExportKey) else { return nil }
    return downloadsDirectoryURL
  }

  static func recordSuccessfulExport(in userDefaults: UserDefaults) {
    userDefaults.set(true, forKey: completedExportKey)
  }
}

struct CapacityHistoryLoadGeneration {
  private(set) var current = 0

  mutating func begin() -> Int {
    current += 1
    return current
  }

  func isCurrent(_ generation: Int) -> Bool {
    generation == current
  }
}

enum CapacityHistorySelectionPolicy {
  static func movedDate(
    from selectedDate: Date?,
    direction: Int,
    availableDates: [Date]
  ) -> Date? {
    let dates = Array(Set(availableDates)).sorted()
    guard !dates.isEmpty else { return nil }
    guard let selectedDate else {
      return direction < 0 ? dates.last : dates.first
    }
    if direction < 0 {
      return dates.last(where: { $0 < selectedDate }) ?? dates.first
    }
    return dates.first(where: { $0 > selectedDate }) ?? dates.last
  }
}

enum CapacityHistoryDateTimeCopy {
  private static let englishInterfaceLocale = Locale(identifier: "en_US")

  static func abbreviated(
    _ date: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> String {
    formatted(
      date,
      twelveHourFormat: "MMM d, yyyy 'at' h:mm a",
      twentyFourHourFormat: "MMM d, yyyy 'at' HH:mm",
      calendar: calendar
    )
  }

  static func long(
    _ date: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> String {
    formatted(
      date,
      twelveHourFormat: "MMMM d, yyyy 'at' h:mm a",
      twentyFourHourFormat: "MMMM d, yyyy 'at' HH:mm",
      calendar: calendar
    )
  }

  private static func formatted(
    _ date: Date,
    twelveHourFormat: String,
    twentyFourHourFormat: String,
    calendar: Calendar
  ) -> String {
    let sourceLocale = calendar.locale ?? .autoupdatingCurrent
    let sourceFormat = DateFormatter.dateFormat(
      fromTemplate: "j",
      options: 0,
      locale: sourceLocale
    ) ?? ""
    let usesTwentyFourHourClock =
      sourceFormat.contains("H") || sourceFormat.contains("k")

    var presentationCalendar = calendar
    presentationCalendar.locale = englishInterfaceLocale

    let formatter = DateFormatter()
    formatter.locale = englishInterfaceLocale
    formatter.calendar = presentationCalendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = usesTwentyFourHourClock
      ? twentyFourHourFormat
      : twelveHourFormat
    return formatter.string(from: date)
  }
}

enum CapacityHistoryInspectionCopy {
  static func description(
    at selectedDate: Date,
    projection: CapacityHistoryProjection,
    liveTail: CapacityHistoryLiveTail?,
    trendLines: [CapacityHistoryTrendLine] = [],
    calendar: Calendar = .autoupdatingCurrent
  ) -> String {
    var parts = [
      CapacityHistoryDateTimeCopy.abbreviated(
        selectedDate,
        calendar: calendar
      ),
    ]
    if let remainingPercent = projection.remainingPercent(
      at: selectedDate,
      liveTail: liveTail
    ) {
      parts.append("\(remainingPercent)% remaining")
    } else {
      parts.append("Capacity not observed")
    }
    for trendLine in trendLines {
      if let percent = trendLine.remainingPercent(at: selectedDate) {
        parts.append(
          "\(trendLine.title) \(Int(percent.rounded()))%"
        )
      }
    }
    return parts.joined(separator: " · ")
  }
}

struct CapacityHistoryChartAccessibilityDescriptor:
  AXChartDescriptorRepresentable
{
  let projection: CapacityHistoryProjection
  let liveTail: CapacityHistoryLiveTail?
  var trendLines: [CapacityHistoryTrendLine] = []
  var calendar: Calendar = .autoupdatingCurrent

  func makeChartDescriptor() -> AXChartDescriptor {
    let dateRange =
      projection.rangeStart.timeIntervalSinceReferenceDate
      ... projection.rangeEnd.timeIntervalSinceReferenceDate
    let xAxis = AXNumericDataAxisDescriptor(
      title: "Time",
      range: dateRange,
      gridlinePositions: CapacityHistoryAxisPolicy.tickDates(
        style: projection.axisStyle,
        rangeStart: projection.rangeStart,
        rangeEnd: projection.rangeEnd
      ).map(\.timeIntervalSinceReferenceDate)
    ) { value in
      CapacityHistoryDateTimeCopy.abbreviated(
        Date(timeIntervalSinceReferenceDate: value),
        calendar: calendar
      )
    }
    let yAxis = AXNumericDataAxisDescriptor(
      title: "Capacity remaining",
      range: 0...100,
      gridlinePositions: [0, 25, 50, 75, 100]
    ) { value in
      "\(Int(value.rounded())) percent remaining"
    }
    let visibleSegments = projection.segments.compactMap { segment in
      let observations = segment.observations.filter {
        $0.observedAt >= projection.rangeStart
          && $0.observedAt <= projection.rangeEnd
      }
      return observations.isEmpty ? nil : observations
    }
    let usesMultipleCapacitySeries = visibleSegments.count > 1
    var series = visibleSegments.enumerated().map { index, observations in
      AXDataSeriesDescriptor(
        name: usesMultipleCapacitySeries
          ? "Capacity remaining, segment \(index + 1)"
          : "Capacity remaining",
        isContinuous: true,
        dataPoints: observations.map { observation in
          AXDataPoint(
            x: observation.observedAt.timeIntervalSinceReferenceDate,
            y: Double(observation.remainingPercent),
            additionalValues: [],
            label: [
              CapacityHistoryDateTimeCopy.abbreviated(
                observation.observedAt,
                calendar: calendar
              ),
              "\(observation.remainingPercent) percent remaining",
            ].joined(separator: ", ")
          )
        }
      )
    }
    if let liveTail {
      let livePoint = AXDataPoint(
        x: liveTail.endsAt.timeIntervalSinceReferenceDate,
        y: Double(liveTail.remainingPercent),
        additionalValues: [],
        label: [
          CapacityHistoryDateTimeCopy.abbreviated(
            liveTail.endsAt,
            calendar: calendar
          ),
          "\(liveTail.remainingPercent) percent remaining",
          "current",
        ].joined(separator: ", ")
      )
      if
        visibleSegments.last?.last?.observedAt == liveTail.startsAt,
        let latestSeries = series.last
      {
        latestSeries.dataPoints.append(livePoint)
      } else {
        series.append(
          AXDataSeriesDescriptor(
            name: "Current Capacity",
            isContinuous: true,
            dataPoints: [livePoint]
          )
        )
      }
    }
    for trendLine in trendLines {
      series.append(
        AXDataSeriesDescriptor(
          name: trendLine.title,
          isContinuous: true,
          dataPoints: [
            AXDataPoint(
              x: trendLine.startsAt.timeIntervalSinceReferenceDate,
              y: trendLine.startRemainingPercent,
              additionalValues: [],
              label: "\(trendLine.title) begins"
            ),
            AXDataPoint(
              x: trendLine.endsAt.timeIntervalSinceReferenceDate,
              y: trendLine.endRemainingPercent,
              additionalValues: [],
              label: "\(trendLine.title) ends"
            ),
          ]
        )
      )
    }

    return AXChartDescriptor(
      title: "Codex Capacity over time",
      summary: "Capacity remaining for \(projection.rangeTitle).",
      xAxis: xAxis,
      yAxis: yAxis,
      additionalAxes: [],
      series: series
    )
  }

  func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
    let updated = makeChartDescriptor()
    descriptor.title = updated.title
    descriptor.summary = updated.summary
    descriptor.xAxis = updated.xAxis
    descriptor.yAxis = updated.yAxis
    descriptor.additionalAxes = updated.additionalAxes
    descriptor.series = updated.series
  }

}

struct CapacityHistoryChartPlotInsets: Equatable {
  var plotWidth: CGFloat = 0
}

private struct CapacityHistoryChartPlotInsetsPreferenceKey: PreferenceKey {
  static let defaultValue = CapacityHistoryChartPlotInsets()

  static func reduce(
    value: inout CapacityHistoryChartPlotInsets,
    nextValue: () -> CapacityHistoryChartPlotInsets
  ) {
    value = nextValue()
  }
}

@MainActor
enum CapacityHistoryWindowFactory {
  static let frameAutosaveName =
    NSWindow.FrameAutosaveName("CodexEcho.CapacityHistory")

  static func make(
    contentView: NSView,
    savesFrame: Bool = true
  ) -> NSWindowController {
    let window = NSWindow(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: CapacityHistoryWindowMetrics.width,
        height: CapacityHistoryWindowMetrics.height
      ),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Codex Capacity"
    window.contentMinSize = NSSize(
      width: CapacityHistoryWindowMetrics.minimumWidth,
      height: CapacityHistoryWindowMetrics.minimumHeight
    )
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.center()
    if savesFrame {
      window.setFrameAutosaveName(frameAutosaveName)
    }
    window.contentView = contentView

    let windowController = NSWindowController(window: window)
    windowController.shouldCascadeWindows = true
    return windowController
  }
}

struct CodexCapacityOverviewDetailsGrid: View {
  let presentation: CodexCapacityOverviewPresentation
  @Binding var showsExpirationDetails: Bool

  var body: some View {
    Grid(
      alignment: .leading,
      horizontalSpacing: 18,
      verticalSpacing: 5
    ) {
      if let nextReset = presentation.nextReset {
        GridRow {
          capacityOverviewLabel(nextReset.label)
          Text(nextReset.text)
            .monospacedDigit()
            .accessibilityLabel(
              CodexCapacityDateTimeCopy.accessibilityDescription(
                nextReset.resetsAt
              )
            )
        }
        .accessibilityElement(children: .combine)
      }

      if let availableResetCount = presentation.availableResetCount {
        GridRow {
          capacityOverviewLabel(
            CodexCapacityOverviewCopy.resetCredits
          )
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(availableResetCount)")
              .monospacedDigit()

            if presentation.showsExpirationDetails {
              Button {
                showsExpirationDetails.toggle()
              } label: {
                Image(systemName: "info.circle")
              }
              .buttonStyle(.borderless)
              .controlSize(.small)
              .help(CodexCapacityOverviewCopy.resetExpirations)
              .accessibilityLabel(
                CodexCapacityOverviewCopy.showResetExpirations
              )
              .popover(
                isPresented: $showsExpirationDetails,
                arrowEdge: .trailing
              ) {
                resetExpirationDetails
              }
            }
          }
        }
      }

      if let nextExpiration = presentation.nextExpiration {
        GridRow {
          capacityOverviewLabel(
            CodexCapacityOverviewCopy.nextExpiration
          )
          Text(nextExpiration.text)
            .monospacedDigit()
            .accessibilityLabel(
              CodexCapacityDateTimeCopy.accessibilityDescription(
                nextExpiration.expiresAt
              )
            )
        }
        .accessibilityElement(children: .combine)
      }
    }
    .font(.callout)
  }

  private func capacityOverviewLabel(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }

  private var resetExpirationDetails: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(CodexCapacityOverviewCopy.resetExpirations)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)

      Divider()

      if CodexCapacityExpirationPopoverMetrics.requiresScrolling(
        rowCount: presentation.expirations.count
      ) {
        ScrollView {
          resetExpirationRows
            .padding(
              .trailing,
              CodexCapacityExpirationPopoverMetrics.scrollIndicatorClearance
            )
        }
        .frame(
          height: CodexCapacityExpirationPopoverMetrics.maximumListHeight
        )
      } else {
        resetExpirationRows
      }

      if let note = presentation.expirationReportingNote {
        Divider()
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .fixedSize(horizontal: true, vertical: false)
  }

  private var resetExpirationRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(presentation.expirations.enumerated()), id: \.offset) {
        index, expiration in
        Text(expiration.text)
          .monospacedDigit()
          .accessibilityLabel(
            CodexCapacityDateTimeCopy.accessibilityDescription(
              expiration.expiresAt
            )
          )
          .frame(
            minHeight: CodexCapacityExpirationPopoverMetrics.rowHeight
          )

        if index < presentation.expirations.count - 1 {
          Divider()
        }
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }
}

@MainActor
final class CapacityHistoryViewModel: ObservableObject {
  static let selectedLimitDurationDefaultsKey =
    "selectedCapacityWindowDurationMinutes"

  @Published private(set) var selectedLimit: CapacityHistoryLimit
  @Published var selectedRange = CapacityHistoryRangeSelection.currentWindow
  @Published var selectedDate: Date?
  @Published private(set) var observations: [CapacityObservation] = []
  @Published private(set) var isLoading = false
  @Published private(set) var isMutatingHistory = false
  @Published private(set) var errorDescription: String?

  let store: CapacityHistoryStore
  private let userDefaults: UserDefaults?
  private var loadGeneration = CapacityHistoryLoadGeneration()
  private var hasInitializedLimitSelection = false
  private var hasLoadedHistory = false
  private var hasSeenValidCurrentWindow = false
  private var persistedLimitDurationMinutes: Int?

  init(
    store: CapacityHistoryStore,
    userDefaults: UserDefaults? = nil
  ) {
    self.store = store
    self.userDefaults = userDefaults
    let storedDuration = (
      userDefaults?.object(
        forKey: Self.selectedLimitDurationDefaultsKey
      ) as? NSNumber
    )?.intValue
    let validStoredDuration = storedDuration.flatMap { duration in
      duration > 0 ? duration : nil
    }
    persistedLimitDurationMinutes = validStoredDuration
    selectedLimit = validStoredDuration.map {
      CapacityHistoryLimit(windowDurationMinutes: $0)
    } ?? .unresolved
  }

  var hasStoredHistory: Bool {
    !observations.isEmpty
  }

  var canClearHistory: Bool {
    hasStoredHistory && !isLoading && !isMutatingHistory
  }

  func availableLimits(snapshot: CodexUsageSnapshot?) -> [CapacityHistoryLimit] {
    var durations = Set(
      snapshot?.windows.compactMap(\.windowDurationMinutes) ?? []
    )
    for observation in observations {
      durations.insert(observation.windowDurationMinutes)
    }
    return durations
      .filter { $0 > 0 }
      .sorted()
      .map(CapacityHistoryLimit.init(windowDurationMinutes:))
  }

  func reconcileLimitSelection(
    snapshot: CodexUsageSnapshot?,
    usageAvailability: CodexUsageAvailability = .pending
  ) {
    let available = availableLimits(snapshot: snapshot)
    if !available.isEmpty {
      let fallback = snapshot?.constrainingWindow?.windowDurationMinutes
        .flatMap { duration in
          available.first { $0.windowDurationMinutes == duration }
        }
        ?? available[0]

      if let persistedLimitDurationMinutes {
        if let preferred = available.first(where: {
          $0.windowDurationMinutes == persistedLimitDurationMinutes
        }) {
          applyAutomaticLimitSelection(preferred)
          hasInitializedLimitSelection = true
        } else if snapshot != nil && hasLoadedHistory {
          clearPersistedLimitSelection()
          applyAutomaticLimitSelection(fallback)
          hasInitializedLimitSelection = true
        } else {
          applyAutomaticLimitSelection(fallback)
        }
      } else if
        !hasInitializedLimitSelection || !available.contains(selectedLimit)
      {
        applyAutomaticLimitSelection(fallback)
        hasInitializedLimitSelection = true
      }
    }

    let currentWindow = snapshot?.window(
      durationMinutes: selectedLimit.windowDurationMinutes
    )
    let hasValidCurrentWindow = CapacityHistoryViewport.make(
      selection: .currentWindow,
      window: currentWindow,
      now: .now
    ) != nil
    if hasValidCurrentWindow {
      hasSeenValidCurrentWindow = true
    } else if
      selectedRange == .currentWindow
        && (
          snapshot != nil
            || hasSeenValidCurrentWindow
            || usageAvailability == .unavailable
        )
    {
      selectedRange = .twentyFourHours
    }
  }

  func selectLimit(
    _ limit: CapacityHistoryLimit,
    snapshot: CodexUsageSnapshot?,
    usageAvailability: CodexUsageAvailability = .pending
  ) {
    selectedLimit = limit
    selectedDate = nil
    hasInitializedLimitSelection = true
    persistedLimitDurationMinutes = limit.windowDurationMinutes
    userDefaults?.set(
      limit.windowDurationMinutes,
      forKey: Self.selectedLimitDurationDefaultsKey
    )
    reconcileLimitSelection(
      snapshot: snapshot,
      usageAvailability: usageAvailability
    )
  }

  var selectedObservations: [CapacityObservation] {
    observations.filter(selectedLimit.matches)
  }

  func refresh() async {
    let generation = loadGeneration.begin()
    isLoading = true
    do {
      let loadedObservations = try await store.readAll()
      guard loadGeneration.isCurrent(generation) else { return }
      hasLoadedHistory = true
      observations = loadedObservations
      errorDescription = nil
    } catch {
      guard loadGeneration.isCurrent(generation) else { return }
      errorDescription = error.localizedDescription
    }
    guard loadGeneration.isCurrent(generation) else { return }
    isLoading = false
  }

  func refreshAndReconcile(
    currentState: () -> (
      snapshot: CodexUsageSnapshot?,
      usageAvailability: CodexUsageAvailability
    )
  ) async {
    await refresh()
    let currentState = currentState()
    reconcileLimitSelection(
      snapshot: currentState.snapshot,
      usageAvailability: currentState.usageAvailability
    )
  }

  private func clearPersistedLimitSelection() {
    persistedLimitDurationMinutes = nil
    userDefaults?.removeObject(
      forKey: Self.selectedLimitDurationDefaultsKey
    )
  }

  private func applyAutomaticLimitSelection(
    _ limit: CapacityHistoryLimit
  ) {
    guard selectedLimit != limit else { return }
    selectedLimit = limit
    selectedDate = nil
  }

  func clear(
    using clearHistory: () async throws -> Void
  ) async throws {
    guard !isMutatingHistory else { return }
    isMutatingHistory = true
    defer { isMutatingHistory = false }
    do {
      try await clearHistory()
      await refresh()
      selectedDate = nil
    } catch {
      errorDescription = error.localizedDescription
      throw error
    }
  }

  func exportCSV() {
    guard !selectedObservations.isEmpty else { return }
    let panel = NSSavePanel()
    panel.title = "Export Capacity History"
    let date = Date.now.formatted(
      .iso8601.year().month().day()
    )
    let limitName = selectedLimit.title
      .lowercased()
      .replacingOccurrences(of: "-", with: "")
    panel.nameFieldStringValue =
      "codex-capacity-\(limitName)-history-\(date).csv"
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.directoryURL =
      CapacityHistoryExportDestinationPolicy.initialDirectoryURL(
        userDefaults: .standard,
        downloadsDirectoryURL: FileManager.default.urls(
          for: .downloadsDirectory,
          in: .userDomainMask
        ).first
      )
    panel.begin { [weak self] response in
      guard response == .OK, let self, let url = panel.url else { return }
      Task {
        do {
          let csv = try await csvForSelectedLimitExport()
          try csv.write(to: url, atomically: true, encoding: .utf8)
          CapacityHistoryExportDestinationPolicy.recordSuccessfulExport(
            in: .standard
          )
          errorDescription = nil
        } catch {
          errorDescription = error.localizedDescription
        }
      }
    }
  }

  func csvForExport() async throws -> String {
    try await store.csv()
  }

  func csvForSelectedLimitExport() async throws -> String {
    try await store.csv(for: selectedLimit)
  }
}

struct CapacityHistoryView: View {
  @ObservedObject var model: CodexActivityModel
  @ObservedObject var recorder: CapacityHistoryRecorder
  @ObservedObject var viewModel: CapacityHistoryViewModel
  let clearCapacityHistory: () async throws -> Void
  @State private var confirmsClear = false
  @State private var showsExpirationDetails = false
  @State private var chartPlotInsets = CapacityHistoryChartPlotInsets()

  init(
    model: CodexActivityModel,
    recorder: CapacityHistoryRecorder,
    viewModel: CapacityHistoryViewModel,
    clearCapacityHistory: @escaping () async throws -> Void
  ) {
    self.model = model
    self.recorder = recorder
    self.viewModel = viewModel
    self.clearCapacityHistory = clearCapacityHistory
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { _ in
      let now = Date.now
      let selectedWindow = model.codexUsageSnapshot?.window(
        durationMinutes: viewModel.selectedLimit.windowDurationMinutes
      )
      let viewport = CapacityHistoryViewport.make(
        selection: viewModel.selectedRange,
        window: selectedWindow,
        now: now
      ) ?? CapacityHistoryViewport.make(
        selection: .twentyFourHours,
        window: nil,
        now: now
      )!
      let selectedObservations = viewModel.selectedObservations
      let projection = CapacityHistoryProjection(
        observations: selectedObservations,
        period: viewport.axisStyle.projectionPeriod,
        viewport: viewport,
        observedThrough: now
      )
      let liveValue = recorder.liveValue(for: viewModel.selectedLimit)
      let monitoringState = CapacityHistoryMonitoringState.resolve(
        isRecordingEnabled: recorder.isRecordingEnabled,
        isConnected: recorder.isConnected,
        liveObservedAt: liveValue?.observedAt,
        latestStoredObservedAt: selectedObservations.last?.observedAt,
        now: now
      )
      let liveTail = CapacityHistoryLiveTail(
        latestObservation: projection.latestObservation,
        liveRemainingPercent: liveValue?.remainingPercent,
        liveSessionID: liveValue?.sessionID,
        monitoringState: monitoringState,
        now: min(now, viewport.rangeEnd)
      )
      let trendLines = viewModel.selectedRange == .currentWindow
        ? currentCycleTrendLines(
          liveValue: liveValue,
          window: selectedWindow,
          now: now
        )
        : []
      let capacityOverview = CodexCapacityOverviewPresentation.make(
        snapshot: model.codexUsageSnapshot,
        windowDurationMinutes: viewModel.selectedLimit.windowDurationMinutes
      )

      VStack(
        alignment: .leading,
        spacing: CapacityHistoryWindowMetrics.sectionSpacing
      ) {
        capacityOverviewView(
          presentation: capacityOverview,
          availableLimits: viewModel.availableLimits(
            snapshot: model.codexUsageSnapshot
          ),
          selectedObservations: selectedObservations,
          liveValue: liveValue
        )
        Divider()
        historyRangeControl(
          canShowCurrentWindow: selectedWindow.flatMap {
            CapacityHistoryViewport.make(
              selection: .currentWindow,
              window: $0,
              now: now
            )
          } != nil
        )
        if !monitoringState.isRecording {
          historyMonitoringStatus(
            monitoringState: monitoringState,
            now: now
          )
        }
        chartContent(
          projection: projection,
          liveTail: liveTail,
          trendLines: trendLines,
          selectedObservations: selectedObservations,
          now: now
        )
      }
      .padding(.horizontal, 24)
      .padding(
        .vertical,
        CapacityHistoryWindowMetrics.verticalPadding
      )
      .frame(
        minWidth: CapacityHistoryWindowMetrics.minimumWidth,
        minHeight: CapacityHistoryWindowMetrics.minimumHeight
      )
    }
    .onAppear {
      viewModel.reconcileLimitSelection(
        snapshot: model.codexUsageSnapshot,
        usageAvailability: model.codexUsageAvailability
      )
      #if DEBUG
        if ProcessInfo.processInfo.environment[
          "CODEX_ECHO_DEBUG_CAPACITY_HISTORY_RANGE"
        ] == "24-hours" {
          viewModel.selectedRange = .twentyFourHours
        }
        if ProcessInfo.processInfo.environment[
          "CODEX_ECHO_DEBUG_CAPACITY_HISTORY_SELECTION"
        ] == "recent" {
          viewModel.selectedDate = Date.now.addingTimeInterval(-2 * 60 * 60)
        }
      #endif
    }
    .task {
      await viewModel.refreshAndReconcile {
        (
          snapshot: model.codexUsageSnapshot,
          usageAvailability: model.codexUsageAvailability
        )
      }
    }
    .onReceive(recorder.$revision.dropFirst()) { _ in
      Task { @MainActor in
        await viewModel.refreshAndReconcile {
          (
            snapshot: model.codexUsageSnapshot,
            usageAvailability: model.codexUsageAvailability
          )
        }
      }
    }
    .onReceive(model.$codexUsageSnapshot.dropFirst()) { snapshot in
      viewModel.reconcileLimitSelection(
        snapshot: snapshot,
        usageAvailability: model.codexUsageAvailability
      )
      viewModel.selectedDate = nil
    }
    .onReceive(model.$codexUsageAvailability.dropFirst()) { availability in
      viewModel.reconcileLimitSelection(
        snapshot: model.codexUsageSnapshot,
        usageAvailability: availability
      )
      viewModel.selectedDate = nil
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .alert(
      CapacityHistoryClearCopy.title,
      isPresented: $confirmsClear
    ) {
      Button("Cancel", role: .cancel) {}
      Button(CapacityHistoryClearCopy.actionTitle, role: .destructive) {
        Task {
          try? await viewModel.clear(using: clearCapacityHistory)
        }
      }
    } message: {
      Text(CapacityHistoryClearCopy.message)
    }
  }

  @ViewBuilder
  private func capacityWindowControl(
    availableLimits: [CapacityHistoryLimit]
  ) -> some View {
    if availableLimits.isEmpty {
      Text("Unavailable")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Capacity Window unavailable")
    } else {
      Picker(
        "Capacity Window",
        selection: Binding(
          get: { viewModel.selectedLimit },
          set: { limit in
            viewModel.selectLimit(
              limit,
              snapshot: model.codexUsageSnapshot,
              usageAvailability: model.codexUsageAvailability
            )
          }
        )
      ) {
        ForEach(availableLimits) { limit in
          Text(limit.pickerTitle).tag(limit)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .fixedSize()
      .accessibilityHint(
        "Changes the Capacity summary and history shown below."
      )
      .onChange(of: viewModel.selectedLimit) {
        viewModel.selectedDate = nil
      }
    }
  }

  private func historyRangeControl(
    canShowCurrentWindow: Bool
  ) -> some View {
    Picker("Time Range", selection: $viewModel.selectedRange) {
      ForEach(CapacityHistoryRangeSelection.allCases) { range in
        Text(range.title)
          .tag(range)
          .disabled(range == .currentWindow && !canShowCurrentWindow)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .frame(width: 300)
    .frame(maxWidth: .infinity)
    .font(.callout)
    .onChange(of: viewModel.selectedRange) {
      viewModel.selectedDate = nil
    }
  }

  @ViewBuilder
  private func capacityOverviewView(
    presentation: CodexCapacityOverviewPresentation,
    availableLimits: [CapacityHistoryLimit],
    selectedObservations: [CapacityObservation],
    liveValue: CapacityHistoryLiveValue?
  ) -> some View {
    HStack(alignment: .lastTextBaseline, spacing: 24) {
      VStack(
        alignment: .leading,
        spacing: CapacityHistoryWindowMetrics.sectionSpacing
      ) {
        capacityWindowControl(availableLimits: availableLimits)
        capacityRemainingView(
          presentation: presentation,
          selectedObservations: selectedObservations,
          liveValue: liveValue
        )
      }

      Spacer(minLength: 20)

      if
        presentation.nextReset != nil
          || presentation.availableResetCount != nil
      {
        CodexCapacityOverviewDetailsGrid(
          presentation: presentation,
          showsExpirationDetails: $showsExpirationDetails
        )
      }
    }
  }

  @ViewBuilder
  private func capacityRemainingView(
    presentation: CodexCapacityOverviewPresentation,
    selectedObservations: [CapacityObservation],
    liveValue: CapacityHistoryLiveValue?
  ) -> some View {
    if let remainingPercent = presentation.remainingPercent {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("\(remainingPercent)%")
          .font(.system(size: 34, weight: .semibold, design: .rounded))
          .contentTransition(.numericText())
        Text("remaining")
          .font(.headline)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    } else if let lastObservedPercent = lastObservedPercent(
      selectedObservations: selectedObservations,
      liveValue: liveValue
    ) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("\(lastObservedPercent)%")
          .font(.system(size: 30, weight: .semibold, design: .rounded))
        Text("last observed")
          .font(.headline)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    } else if !recorder.isRecordingEnabled {
      Text("No recorded history")
        .font(.headline)
        .foregroundStyle(.secondary)
    } else {
      Text("Waiting for the first observation")
        .font(.headline)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func historyMonitoringStatus(
    monitoringState: CapacityHistoryMonitoringState,
    now: Date
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 20) {
      if case .disabled(let lastRecordedAt) = monitoringState {
        HStack(spacing: 6) {
          Image(systemName: CapacityHistoryRecordingCopy.offSystemImage)
            .font(.system(size: 10, weight: .semibold))
          Text(CapacityHistoryRecordingCopy.offStatus)
        }
        .foregroundStyle(.secondary)
        if let lastRecordedAt {
          Text(
            CapacityHistoryFreshnessCopy.lastRecordedLabel(
              observedAt: lastRecordedAt,
              now: now
            )
          )
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .help(
            "Last recorded \(CapacityHistoryDateTimeCopy.abbreviated(lastRecordedAt))"
          )
        }
      }

      if case .notRecording(let lastObservedAt) = monitoringState {
        HStack(spacing: 6) {
          Image(systemName: "circle")
            .font(.system(size: 8, weight: .semibold))
          Text("Not recording")
        }
        .foregroundStyle(.secondary)
        if let lastObservedAt {
          Text(
            CapacityHistoryFreshnessCopy.label(
              observedAt: lastObservedAt,
              now: now
            )
          )
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .help(
            "Last observed \(CapacityHistoryDateTimeCopy.abbreviated(lastObservedAt))"
          )
        }
      }
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func chartContent(
    projection: CapacityHistoryProjection,
    liveTail: CapacityHistoryLiveTail?,
    trendLines: [CapacityHistoryTrendLine],
    selectedObservations: [CapacityObservation],
    now: Date
  ) -> some View {
    let isLoadingWithoutObservations =
      viewModel.isLoading && selectedObservations.isEmpty
    let errorDescription =
      viewModel.errorDescription ?? recorder.recordingErrorDescription
    let hasChartSeries =
      !selectedObservations.isEmpty || liveTail != nil || !trendLines.isEmpty
    let hasSeriesInViewport =
      !projection.observationsInRange.isEmpty
        || liveTail != nil
        || !trendLines.isEmpty
    let canInspectChart =
      !isLoadingWithoutObservations
        && errorDescription == nil
        && hasChartSeries
        && hasSeriesInViewport

    VStack(
      alignment: .leading,
      spacing: CapacityHistoryWindowMetrics.sectionSpacing
    ) {
      if isLoadingWithoutObservations {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let errorDescription {
        ContentUnavailableView(
          "Capacity History Unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text(errorDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if !hasChartSeries {
        if recorder.isRecordingEnabled {
          ContentUnavailableView(
            "No Capacity history yet",
            systemImage: "chart.xyaxis.line",
            description: Text(
              "Codex Echo records Capacity locally while it is running."
            )
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView(
            CapacityHistoryRecordingCopy.offEmptyTitle,
            systemImage: CapacityHistoryRecordingCopy.offSystemImage,
            description: Text(CapacityHistoryRecordingCopy.offEmptyDescription)
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else if !hasSeriesInViewport {
        ContentUnavailableView(
          "No observations in \(projection.rangeTitle.lowercased())",
          systemImage: "clock",
          description: Text("Choose a longer range or another usage limit.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        capacityChart(
          projection: projection,
          liveTail: liveTail,
          trendLines: trendLines,
          now: now
        )
          .frame(
            minHeight: CapacityHistoryWindowMetrics.minimumChartHeight
          )
      }

      if canInspectChart || viewModel.hasStoredHistory {
        historyStatusLine(
          projection: projection,
          liveTail: liveTail,
          trendLines: trendLines,
          canInspectChart: canInspectChart
        )
      }
    }
    .padding(.top, 2)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func historyStatusLine(
    projection: CapacityHistoryProjection,
    liveTail: CapacityHistoryLiveTail?,
    trendLines: [CapacityHistoryTrendLine],
    canInspectChart: Bool
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      historyActionsMenu

      if canInspectChart {
        Group {
          if let selectedDate = viewModel.selectedDate {
            Text(
              CapacityHistoryInspectionCopy.description(
                at: selectedDate,
                projection: projection,
                liveTail: liveTail,
                trendLines: trendLines
              )
            )
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .transition(.opacity)
          } else {
            Text("Move across the chart to inspect Capacity.")
              .foregroundStyle(.tertiary)
          }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Spacer(minLength: 0)
      }
    }
  }

  private func capacityChart(
    projection: CapacityHistoryProjection,
    liveTail: CapacityHistoryLiveTail?,
    trendLines: [CapacityHistoryTrendLine],
    now: Date
  ) -> some View {
    let currentCycleRenderSeries = projection.includesFuture
      ? CapacityHistoryCurrentCycleRenderPolicy.series(
        projection.segments,
        rangeStart: projection.rangeStart,
        rangeEnd: projection.rangeEnd,
        liveTail: liveTail,
        plotWidth: chartPlotInsets.plotWidth
      )
      : nil
    let visualSegments = projection.includesFuture
      ? []
      : CapacityHistoryVisualSamplingPolicy.segments(
        projection.segments,
        rangeStart: projection.rangeStart,
        rangeEnd: projection.rangeEnd,
        plotWidth: chartPlotInsets.plotWidth
      )
    let renderedTrendLines = trendLines.sorted {
      trendRenderPriority($0.kind) < trendRenderPriority($1.kind)
    }
    return Chart {
      if projection.includesFuture {
        RuleMark(x: .value("Now", now))
          .lineStyle(
            StrokeStyle(
              lineWidth: CapacityHistoryChartMetrics.nowRuleWidth
            )
          )
          .foregroundStyle(
            Color.accentColor.opacity(
              CapacityHistoryChartMetrics.nowRuleOpacity
            )
          )
          .accessibilityLabel("Now")
          .accessibilityValue(
            CapacityHistoryDateTimeCopy.abbreviated(now)
          )
      }

      ForEach(renderedTrendLines) { trendLine in
        LineMark(
          x: .value("Trend starts", trendLine.startsAt),
          y: .value("Trend remaining", trendLine.startRemainingPercent),
          series: .value("Trend", trendLine.kind.rawValue)
        )
        .interpolationMethod(.linear)
        .lineStyle(trendStrokeStyle(trendLine.kind))
        .foregroundStyle(trendColor(trendLine.kind))
        .accessibilityLabel(trendLine.title)
        .accessibilityValue(
          "\(Int(trendLine.startRemainingPercent.rounded()))% remaining"
        )
        LineMark(
          x: .value("Trend ends", trendLine.endsAt),
          y: .value("Trend remaining", trendLine.endRemainingPercent),
          series: .value("Trend", trendLine.kind.rawValue)
        )
        .interpolationMethod(.linear)
        .lineStyle(trendStrokeStyle(trendLine.kind))
        .foregroundStyle(trendColor(trendLine.kind))
        .accessibilityLabel(trendLine.title)
        .accessibilityValue(
          "\(Int(trendLine.endRemainingPercent.rounded()))% remaining"
        )
      }

      if projection.includesFuture {
        ForEach(currentCycleRenderSeries?.bandSamples ?? []) { point in
          LineMark(
            x: .value("Summary", point.observedAt),
            y: .value("Summary remaining", point.remainingPercent),
            series: .value("Summary band", "current-cycle-band")
          )
          .interpolationMethod(.linear)
          .lineStyle(
            StrokeStyle(
              lineWidth: CapacityHistoryChartMetrics.summaryBandWidth,
              lineCap: .round,
              lineJoin: .round
            )
          )
          .foregroundStyle(
            Color.accentColor.opacity(
              CapacityHistoryChartMetrics.summaryBandOpacity
            )
          )
          .accessibilityHidden(true)
        }

        ForEach(currentCycleRenderSeries?.lineSamples ?? []) { point in
          LineMark(
            x: .value("Summary", point.observedAt),
            y: .value("Summary remaining", point.remainingPercent),
            series: .value("Summary", "current-cycle")
          )
          .interpolationMethod(.linear)
          .lineStyle(
            StrokeStyle(
              lineWidth: CapacityHistoryChartMetrics.summaryLineWidth,
              lineCap: .round,
              lineJoin: .round
            )
          )
          .foregroundStyle(Color.accentColor)
          .accessibilityHidden(true)
        }
      } else {
        ForEach(visualSegments) { segment in
          ForEach(segment.observations) { observation in
            LineMark(
              x: .value("Observed", observation.observedAt),
              y: .value("Remaining", observation.remainingPercent),
              series: .value("Segment", segment.id)
            )
            .interpolationMethod(.stepEnd)
            .lineStyle(
              StrokeStyle(
                lineWidth: CapacityHistoryChartMetrics.lineWidth,
                lineCap: .round,
                lineJoin: .miter
              )
            )
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(
              CapacityHistoryDateTimeCopy.abbreviated(
                observation.observedAt
              )
            )
            .accessibilityValue("\(observation.remainingPercent)% remaining")
          }
        }
      }

      if !projection.includesFuture, let liveTail {
        RuleMark(
          xStart: .value("Live start", liveTail.startsAt),
          xEnd: .value("Now", liveTail.endsAt),
          y: .value("Remaining", liveTail.remainingPercent)
        )
        .lineStyle(
          StrokeStyle(
            lineWidth: CapacityHistoryChartMetrics.lineWidth,
            lineCap: .round
          )
        )
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel("Current Capacity")
        .accessibilityValue("\(liveTail.remainingPercent)% remaining")
      }

      ForEach(
        projection.gaps.filter {
          $0.duration
            > projection.rangeEnd.timeIntervalSince(projection.rangeStart)
              * 0.08
        }
      ) { gap in
        RuleMark(
          x: .value(
            "Gap",
            gap.startsAt.addingTimeInterval(gap.duration / 2)
          )
        )
        .opacity(0)
        .accessibilityLabel("Not observed")
        .accessibilityValue(
          "Between \(CapacityHistoryDateTimeCopy.abbreviated(gap.startsAt)) and \(CapacityHistoryDateTimeCopy.abbreviated(gap.endsAt))"
        )
      }

      if let selectedDate = viewModel.selectedDate {
        RuleMark(x: .value("Selected", selectedDate))
          .foregroundStyle(.secondary.opacity(0.6))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
    }
    .chartXScale(domain: projection.rangeStart...projection.rangeEnd)
    .chartYScale(domain: 0...100)
    .chartYAxis {
      AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
        AxisGridLine()
        AxisValueLabel {
          if let percent = value.as(Int.self) {
            Text("\(percent)%")
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks(
        values: CapacityHistoryAxisPolicy.tickDates(
          style: projection.axisStyle,
          rangeStart: projection.rangeStart,
          rangeEnd: projection.rangeEnd
        )
      ) { _ in
        AxisGridLine()
      }
      AxisMarks(
        values: CapacityHistoryAxisPolicy.displayTickDates(
          style: projection.axisStyle,
          rangeStart: projection.rangeStart,
          rangeEnd: projection.rangeEnd,
          plotWidth: chartPlotInsets.plotWidth
        )
      ) { value in
        if let date = value.as(Date.self) {
          let isNow =
            abs(date.timeIntervalSince(projection.rangeEnd)) < 0.5
          if isNow {
            AxisTick()
            AxisValueLabel(anchor: .topTrailing) {
              Text(projection.includesFuture ? "Reset" : "Now")
            }
          } else {
            AxisTick()
            AxisValueLabel {
              Text(
                CapacityHistoryAxisLabelPolicy.label(
                  for: date,
                  style: projection.axisStyle
                )
              )
            }
          }
        }
      }
    }
    .chartXSelection(value: $viewModel.selectedDate)
    .focusable()
    .onMoveCommand { direction in
      switch direction {
      case .left:
        moveSelection(
          direction: -1,
          projection: projection,
          liveTail: liveTail,
          trendLines: trendLines
        )
      case .right:
        moveSelection(
          direction: 1,
          projection: projection,
          liveTail: liveTail,
          trendLines: trendLines
        )
      default:
        break
      }
    }
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .decrement:
        moveSelection(
          direction: -1,
          projection: projection,
          liveTail: liveTail,
          trendLines: trendLines
        )
      case .increment:
        moveSelection(
          direction: 1,
          projection: projection,
          liveTail: liveTail,
          trendLines: trendLines
        )
      @unknown default:
        break
      }
    }
    .chartOverlay { proxy in
      GeometryReader { geometry in
        if let plotFrameAnchor = proxy.plotFrame {
          let plotFrame = geometry[plotFrameAnchor]
          Color.clear
            .preference(
              key: CapacityHistoryChartPlotInsetsPreferenceKey.self,
              value: CapacityHistoryChartPlotInsets(
                plotWidth: plotFrame.width
              )
            )
            .contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                guard plotFrame.contains(location) else {
                  viewModel.selectedDate = nil
                  return
                }
                let plotX = location.x - plotFrame.origin.x
                viewModel.selectedDate = proxy.value(
                  atX: plotX,
                  as: Date.self
                )
              case .ended:
                viewModel.selectedDate = nil
              }
            }
        }
      }
    }
    .onPreferenceChange(
      CapacityHistoryChartPlotInsetsPreferenceKey.self
    ) { insets in
      chartPlotInsets = insets
    }
    .accessibilityLabel("Codex Capacity over time")
    .accessibilityValue(
      viewModel.selectedDate.map {
        CapacityHistoryInspectionCopy.description(
          at: $0,
          projection: projection,
          liveTail: liveTail,
          trendLines: trendLines
        )
      } ?? accessibilitySummary(for: projection)
    )
    .accessibilityHint(
      "Use left and right arrows to inspect Capacity."
    )
    .accessibilityChartDescriptor(
      CapacityHistoryChartAccessibilityDescriptor(
        projection: projection,
        liveTail: liveTail,
        trendLines: trendLines
      )
    )
  }

  private func moveSelection(
    direction: Int,
    projection: CapacityHistoryProjection,
    liveTail: CapacityHistoryLiveTail?,
    trendLines: [CapacityHistoryTrendLine]
  ) {
    var dates = projection.observationsInRange.map(\.observedAt)
    if let liveTail {
      dates.append(liveTail.endsAt)
    }
    for trendLine in trendLines {
      dates.append(trendLine.startsAt)
      dates.append(trendLine.endsAt)
    }
    viewModel.selectedDate = CapacityHistorySelectionPolicy.movedDate(
      from: viewModel.selectedDate,
      direction: direction,
      availableDates: dates
    )
  }

  private var historyActionsMenu: some View {
    Menu {
      Button("Export CSV…") {
        viewModel.exportCSV()
      }
      .disabled(
        viewModel.selectedObservations.isEmpty
          || viewModel.isMutatingHistory
      )

      Divider()

      Button("Clear History…", role: .destructive) {
        confirmsClear = true
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .layoutPriority(1)
    .help("History Actions")
    .accessibilityLabel("History Actions")
    .disabled(!viewModel.canClearHistory)
  }

  private func lastObservedPercent(
    selectedObservations: [CapacityObservation],
    liveValue: CapacityHistoryLiveValue?
  ) -> Int? {
    guard recorder.isRecordingEnabled else {
      return selectedObservations.last?.remainingPercent
    }
    guard
      let liveObservedAt = liveValue?.observedAt,
      let liveRemainingPercent = liveValue?.remainingPercent
    else {
      return selectedObservations.last?.remainingPercent
    }
    guard let latestStored = selectedObservations.last else {
      return liveRemainingPercent
    }
    return liveObservedAt >= latestStored.observedAt
      ? liveRemainingPercent
      : latestStored.remainingPercent
  }

  private func currentCycleTrendLines(
    liveValue: CapacityHistoryLiveValue?,
    window: CodexRateLimitWindow?,
    now: Date
  ) -> [CapacityHistoryTrendLine] {
    [
      CapacityHistoryTrendLine.makeSinceReset(
        liveValue: liveValue,
        window: window,
        isConnected: recorder.isConnected,
        now: now
      ),
      CapacityHistoryTrendLine.makeEvenPace(
        window: window,
        now: now
      ),
    ]
    .compactMap { $0 }
  }

  private func trendRenderPriority(
    _ kind: CapacityHistoryTrendKind
  ) -> Int {
    switch kind {
    case .evenPace: 0
    case .sinceReset: 1
    }
  }

  private func trendStrokeStyle(
    _ kind: CapacityHistoryTrendKind
  ) -> StrokeStyle {
    switch kind {
    case .sinceReset:
      StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [7, 5])
    case .evenPace:
      StrokeStyle(lineWidth: 1, lineCap: .round, dash: [10, 5])
    }
  }

  private func trendColor(_ kind: CapacityHistoryTrendKind) -> Color {
    switch kind {
    case .sinceReset:
      Color.accentColor.opacity(0.42)
    case .evenPace:
      Color.secondary.opacity(0.42)
    }
  }

  private func accessibilitySummary(
    for projection: CapacityHistoryProjection
  ) -> String {
    let latest =
      projection.latestObservation.map {
        "\($0.remainingPercent)% last observed"
      } ?? "No observations"
    return [
      "Fixed range from 0 to 100%.",
      latest + ".",
      "\(projection.observedDecrease) points of observed decrease.",
      "\(projection.observedIncrease) points of observed increase.",
      "\(projection.gaps.count) observation gaps.",
    ].joined(separator: " ")
  }

}
