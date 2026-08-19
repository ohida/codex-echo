import CoreGraphics
import Foundation

struct CapacityHistoryCurrentCycleTrendPoint:
  Equatable,
  Identifiable,
  Sendable
{
  let observedAt: Date
  let remainingPercent: Double

  var id: TimeInterval { observedAt.timeIntervalSinceReferenceDate }
}

struct CapacityHistoryCurrentCycleTrend: Equatable, Sendable {
  static let minimumSampleCount = 16
  static let maximumSampleCount = 256
  static let sampleSpacing: CGFloat = 2

  let knots: [CapacityHistoryCurrentCycleTrendPoint]
  let tangents: [Double]

  init?(knots: [CapacityHistoryCurrentCycleTrendPoint]) {
    guard
      knots.count >= 2,
      zip(knots, knots.dropFirst()).allSatisfy({
        $0.observedAt < $1.observedAt
      })
    else { return nil }

    self.knots = knots
    tangents = Self.monotoneTangents(for: knots)
  }

  func remainingPercent(atNormalizedTime normalizedTime: Double) -> Double {
    let progress = min(max(normalizedTime, 0), 1)
    if progress == 0 { return knots[0].remainingPercent }
    if progress == 1 { return knots[knots.count - 1].remainingPercent }

    let segmentCount = knots.count - 1
    let scaledProgress = progress * Double(segmentCount)
    let index = min(Int(floor(scaledProgress)), segmentCount - 1)
    let localProgress = scaledProgress - Double(index)
    let interval = 1 / Double(segmentCount)
    let start = knots[index].remainingPercent
    let end = knots[index + 1].remainingPercent
    let startTangent = tangents[index] * interval
    let endTangent = tangents[index + 1] * interval
    let squared = localProgress * localProgress
    let cubed = squared * localProgress
    let value =
      ((2 * cubed) - (3 * squared) + 1) * start
      + (cubed - (2 * squared) + localProgress) * startTangent
      + ((-2 * cubed) + (3 * squared)) * end
      + (cubed - squared) * endTangent
    return min(max(value, min(start, end)), max(start, end))
  }

  func samples(
    plotWidth: CGFloat,
    rangeEnd: Date
  ) -> [CapacityHistoryCurrentCycleTrendPoint] {
    guard let first = knots.first, let last = knots.last else { return [] }
    let observedDuration = last.observedAt.timeIntervalSince(first.observedAt)
    let rangeDuration = rangeEnd.timeIntervalSince(first.observedAt)
    guard observedDuration > 0, rangeDuration > 0 else { return knots }

    let effectivePlotWidth = plotWidth > 0
      ? plotWidth
      : CapacityHistoryVisualSamplingPolicy.fallbackPlotWidth
    let observedPlotWidth = effectivePlotWidth
      * CGFloat(min(max(observedDuration / rangeDuration, 0), 1))
    let requestedCount = Int(
      ceil(observedPlotWidth / Self.sampleSpacing)
    ) + 1
    let sampleCount = min(
      max(requestedCount, Self.minimumSampleCount),
      Self.maximumSampleCount
    )

    return (0..<sampleCount).map { index in
      let progress = Double(index) / Double(sampleCount - 1)
      return CapacityHistoryCurrentCycleTrendPoint(
        observedAt: first.observedAt.addingTimeInterval(
          observedDuration * progress
        ),
        remainingPercent: remainingPercent(
          atNormalizedTime: progress
        )
      )
    }
  }

  private static func monotoneTangents(
    for knots: [CapacityHistoryCurrentCycleTrendPoint]
  ) -> [Double] {
    let interval = 1 / Double(knots.count - 1)
    let secants = zip(knots, knots.dropFirst()).map {
      ($1.remainingPercent - $0.remainingPercent) / interval
    }
    let globalSlope = knots.last!.remainingPercent
      - knots.first!.remainingPercent
    let maximumMagnitude = 2 * abs(globalSlope)
    guard maximumMagnitude > 0 else {
      return Array(repeating: 0, count: knots.count)
    }

    var result = Array(repeating: 0.0, count: knots.count)
    result[0] = secants[0]
    result[result.count - 1] = secants[secants.count - 1]
    for index in 1..<(result.count - 1) {
      let previous = secants[index - 1]
      let next = secants[index]
      if previous < 0, next < 0 {
        result[index] = (2 * previous * next) / (previous + next)
      }
    }

    for index in result.indices {
      let finite = result[index].isFinite ? result[index] : 0
      result[index] = min(max(finite, -maximumMagnitude), 0)
    }

    // Hyman's monotonicity filter removes overshoot without introducing a
    // tangent that points upward.
    for index in secants.indices {
      let secant = secants[index]
      guard secant != 0 else {
        result[index] = 0
        result[index + 1] = 0
        continue
      }
      let alpha = result[index] / secant
      let beta = result[index + 1] / secant
      let magnitude = (alpha * alpha) + (beta * beta)
      if magnitude > 9 {
        let scale = 3 / sqrt(magnitude)
        result[index] = scale * alpha * secant
        result[index + 1] = scale * beta * secant
      }
    }
    return result
  }
}

enum CapacityHistoryCurrentCycleTrendPolicy {
  private static let knotCount = 5

  private struct WeightedPoint {
    let observedAt: Date
    let remainingPercent: Double
    let weight: Double
  }

  private struct IsotonicBlock {
    let startIndex: Int
    let endIndex: Int
    let totalWeight: Double
    let weightedValue: Double

    var mean: Double { weightedValue / totalWeight }

    func merging(_ other: Self) -> Self {
      Self(
        startIndex: startIndex,
        endIndex: other.endIndex,
        totalWeight: totalWeight + other.totalWeight,
        weightedValue: weightedValue + other.weightedValue
      )
    }
  }

  static func trend(
    _ segments: [CapacityHistorySegment],
    rangeStart: Date,
    rangeEnd: Date,
    activeResetsAt: Date? = nil,
    liveTail: CapacityHistoryLiveTail? = nil,
    summaryEndpoint: CapacityHistoryCurrentCycleEndpoint? = nil
  ) -> CapacityHistoryCurrentCycleTrend? {
    var observations = segments
      .flatMap(\.observations)
      .filter {
        $0.observedAt >= rangeStart && $0.observedAt <= rangeEnd
      }
      .sorted { $0.observedAt < $1.observedAt }

    if let activeResetsAt {
      observations = observations.filter {
        CapacityHistoryResetBoundary.matches(
          $0.resetsAt,
          activeResetsAt
        )
      }
    }

    let endpointDate: Date
    let endpointRemainingPercent: Double
    if
      let liveTail,
      liveTail.endsAt >= rangeStart,
      liveTail.endsAt <= rangeEnd
    {
      endpointDate = liveTail.endsAt
      endpointRemainingPercent = Double(liveTail.remainingPercent)
    } else if
      let summaryEndpoint,
      summaryEndpoint.observedAt >= rangeStart,
      summaryEndpoint.observedAt <= rangeEnd,
      observations.last.map({
        summaryEndpoint.observedAt > $0.observedAt
      }) ?? true
    {
      endpointDate = summaryEndpoint.observedAt
      endpointRemainingPercent = Double(summaryEndpoint.remainingPercent)
    } else if let latest = observations.last {
      endpointDate = latest.observedAt
      endpointRemainingPercent = Double(latest.remainingPercent)
    } else {
      return nil
    }
    guard endpointDate > rangeStart else { return nil }

    if
      activeResetsAt == nil,
      let activeObservation = observations.last(where: {
        $0.observedAt <= endpointDate
      })
    {
      observations = observations.filter {
        CapacityHistoryResetBoundary.matches(
          $0.resetsAt,
          activeObservation.resetsAt
        )
      }
    }

    var source = observations
      .filter { $0.observedAt > rangeStart && $0.observedAt < endpointDate }
      .map {
        CapacityHistoryCurrentCycleTrendPoint(
          observedAt: $0.observedAt,
          remainingPercent: Double($0.remainingPercent)
        )
      }
    source.insert(
      CapacityHistoryCurrentCycleTrendPoint(
        observedAt: rangeStart,
        remainingPercent: 100
      ),
      at: 0
    )
    source.append(
      CapacityHistoryCurrentCycleTrendPoint(
        observedAt: endpointDate,
        remainingPercent: endpointRemainingPercent
      )
    )
    source = pointsCollapsingEqualValueHeartbeats(
      pointsKeepingLastValueAtEachTimestamp(source)
    )

    // Current Cycle presents the latent consumption trend. Isotonic fitting
    // absorbs rounded provider corrections without changing exact history.
    let fitted = isotonicPoints(
      source,
      lowerBound: endpointRemainingPercent,
      upperBound: 100
    )
    let duration = endpointDate.timeIntervalSince(rangeStart)
    // Fixed time-normalized knots keep observation timing and window width
    // from changing the canonical curve.
    let knots = (0..<knotCount).map { index in
      let progress = Double(index) / Double(knotCount - 1)
      let date = rangeStart.addingTimeInterval(duration * progress)
      return CapacityHistoryCurrentCycleTrendPoint(
        observedAt: date,
        remainingPercent: interpolatedValue(in: fitted, at: date)
      )
    }
    return CapacityHistoryCurrentCycleTrend(
      knots: knotsKeepingConsumingEndpointDownward(knots)
    )
  }

  private static func knotsKeepingConsumingEndpointDownward(
    _ knots: [CapacityHistoryCurrentCycleTrendPoint]
  ) -> [CapacityHistoryCurrentCycleTrendPoint] {
    guard
      knots.count >= 2,
      let first = knots.first,
      let last = knots.last,
      first.remainingPercent > last.remainingPercent,
      knots[knots.count - 2].remainingPercent <= last.remainingPercent
    else { return knots }

    // A recent plateau would otherwise force a horizontal terminal tangent.
    // Lift only the interior plateau by one average-slope interval so a
    // consuming cycle remains finite and right-down at its exact endpoint.
    let minimumInteriorRemaining = last.remainingPercent
      + ((first.remainingPercent - last.remainingPercent)
        / Double(knots.count - 1))
    var adjusted = knots
    for index in 1..<(adjusted.count - 1) {
      let remainingPercent = min(
        max(
          adjusted[index].remainingPercent,
          minimumInteriorRemaining
        ),
        adjusted[index - 1].remainingPercent
      )
      adjusted[index] = CapacityHistoryCurrentCycleTrendPoint(
        observedAt: adjusted[index].observedAt,
        remainingPercent: remainingPercent
      )
    }
    return adjusted
  }

  private static func pointsKeepingLastValueAtEachTimestamp(
    _ source: [CapacityHistoryCurrentCycleTrendPoint]
  ) -> [CapacityHistoryCurrentCycleTrendPoint] {
    source.reduce(into: []) { result, point in
      if result.last?.observedAt == point.observedAt {
        result[result.count - 1] = point
      } else {
        result.append(point)
      }
    }
  }

  private static func pointsCollapsingEqualValueHeartbeats(
    _ source: [CapacityHistoryCurrentCycleTrendPoint]
  ) -> [CapacityHistoryCurrentCycleTrendPoint] {
    guard let first = source.first else { return [] }
    var result: [CapacityHistoryCurrentCycleTrendPoint] = []
    var runFirst = first
    var runLast = first

    func appendRun() {
      if result.last?.observedAt != runFirst.observedAt {
        result.append(runFirst)
      }
      if result.last?.observedAt != runLast.observedAt {
        result.append(runLast)
      }
    }

    for point in source.dropFirst() {
      if point.remainingPercent == runLast.remainingPercent {
        runLast = point
      } else {
        appendRun()
        runFirst = point
        runLast = point
      }
    }
    appendRun()
    return result
  }

  private static func isotonicPoints(
    _ points: [CapacityHistoryCurrentCycleTrendPoint],
    lowerBound: Double,
    upperBound: Double
  ) -> [CapacityHistoryCurrentCycleTrendPoint] {
    guard points.count > 2 else { return points }
    let weighted = points.indices.map { index in
      let weight: Double
      if index == points.startIndex || index == points.index(before: points.endIndex) {
        weight = 1
      } else {
        weight = max(
          points[index + 1].observedAt.timeIntervalSince(
            points[index - 1].observedAt
          ) / 2,
          1
        )
      }
      return WeightedPoint(
        observedAt: points[index].observedAt,
        remainingPercent: min(
          max(points[index].remainingPercent, lowerBound),
          upperBound
        ),
        weight: weight
      )
    }

    var blocks: [IsotonicBlock] = []
    for (index, point) in weighted.enumerated() {
      blocks.append(
        IsotonicBlock(
          startIndex: index,
          endIndex: index,
          totalWeight: point.weight,
          weightedValue: point.remainingPercent * point.weight
        )
      )
      while
        blocks.count >= 2,
        blocks[blocks.count - 2].mean < blocks[blocks.count - 1].mean
      {
        let last = blocks.removeLast()
        let previous = blocks.removeLast()
        blocks.append(previous.merging(last))
      }
    }

    var fitted = weighted.map(\.remainingPercent)
    for block in blocks {
      for index in block.startIndex...block.endIndex {
        fitted[index] = block.mean
      }
    }
    fitted[0] = upperBound
    fitted[fitted.count - 1] = lowerBound
    return zip(weighted, fitted).map { point, value in
      CapacityHistoryCurrentCycleTrendPoint(
        observedAt: point.observedAt,
        remainingPercent: value
      )
    }
  }

  private static func interpolatedValue(
    in points: [CapacityHistoryCurrentCycleTrendPoint],
    at date: Date
  ) -> Double {
    guard let first = points.first, let last = points.last else { return 100 }
    if date <= first.observedAt { return first.remainingPercent }
    if date >= last.observedAt { return last.remainingPercent }

    let nextIndex = points.firstIndex(where: { $0.observedAt >= date })!
    let previous = points[nextIndex - 1]
    let next = points[nextIndex]
    let duration = next.observedAt.timeIntervalSince(previous.observedAt)
    guard duration > 0 else { return next.remainingPercent }
    let progress = date.timeIntervalSince(previous.observedAt) / duration
    return previous.remainingPercent
      + ((next.remainingPercent - previous.remainingPercent) * progress)
  }
}


struct CapacityHistoryCurrentCycleRenderSeries: Equatable, Sendable {
  let trend: CapacityHistoryCurrentCycleTrend
  let samples: [CapacityHistoryCurrentCycleTrendPoint]

  var lineSamples: [CapacityHistoryCurrentCycleTrendPoint] { samples }
  var bandSamples: [CapacityHistoryCurrentCycleTrendPoint] { samples }
}

enum CapacityHistoryCurrentCycleRenderPolicy {
  static func series(
    _ segments: [CapacityHistorySegment],
    rangeStart: Date,
    rangeEnd: Date,
    activeResetsAt: Date? = nil,
    liveTail: CapacityHistoryLiveTail? = nil,
    summaryEndpoint: CapacityHistoryCurrentCycleEndpoint? = nil,
    plotWidth: CGFloat
  ) -> CapacityHistoryCurrentCycleRenderSeries? {
    guard
      let trend = CapacityHistoryCurrentCycleTrendPolicy.trend(
        segments,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        activeResetsAt: activeResetsAt,
        liveTail: liveTail,
        summaryEndpoint: summaryEndpoint
      )
    else { return nil }

    return CapacityHistoryCurrentCycleRenderSeries(
      trend: trend,
      samples: trend.samples(
        plotWidth: plotWidth,
        rangeEnd: rangeEnd
      )
    )
  }
}
