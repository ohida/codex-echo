import AppKit

@MainActor
enum MenuTaskRingImage {
  private static let glyphSize = NSSize(width: 18, height: 18)
  private static let trailingTextSpacing: CGFloat = 4
  @MainActor
  struct Geometry {
    static let scale = glyphSize.height
      / (
        WorkerCrewRingGeometry.signalHaloDiameter
          + WorkerCrewRingGeometry.reducedMotionSignalHaloLineWidth
      )
    static let signalHaloDiameter =
      WorkerCrewRingGeometry.signalHaloDiameter * scale
    static let ringPathDiameter =
      WorkerCrewRingGeometry.diameter * scale
    static let ringLineWidth =
      WorkerCrewRingGeometry.lineWidth * scale
    static let signalCoreDiameter =
      WorkerCrewRingGeometry.signalCoreDiameter * scale
  }
  static let size = NSSize(
    width: glyphSize.width + trailingTextSpacing,
    height: glyphSize.height
  )

  static func render(
    task: TaskPresentation,
    phase: TimeInterval,
    reduceMotion: Bool = false
  ) -> NSImage {
    render(
      mode: task.state.workerCoreMode,
      subagentCount: task.activeSubagentCount,
      phase: phase,
      reduceMotion: reduceMotion,
      showsUnreadCompletionSignal: task.showsUnreadCompletionSignal,
      accentColor: task.effectiveColor
    )
  }

  static func render(
    mode: WorkerCoreMode,
    subagentCount: Int,
    phase: TimeInterval,
    reduceMotion: Bool = false,
    showsUnreadCompletionSignal: Bool = false,
    accentColor: TaskAccentColor? = nil
  ) -> NSImage {
    let drawingColor = accentColor?.nsColor ?? .black
    let image = NSImage(size: size, flipped: false) { bounds in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.saveGState()
      defer { context.restoreGState() }

      context.setAllowsAntialiasing(true)
      context.setShouldAntialias(true)
      // Keep the ring in its original 18 pt drawing area. The transparent
      // trailing width gives the native menu title a little more breathing
      // room without changing the glyph, row height, or leading alignment.
      let center = CGPoint(x: glyphSize.width / 2, y: bounds.midY)
      let isUnreadCompletion = mode == .ready && showsUnreadCompletionSignal

      if let signalHaloOpacity = WorkerCrewRingGeometry.signalHaloOpacity(
        for: mode,
        isUnreadCompletion: isUnreadCompletion,
        phase: phase,
        reduceMotion: reduceMotion
      ) {
        drawSignalHalo(
          opacity: signalHaloOpacity,
          lineWidth: WorkerCrewRingGeometry.signalHaloLineWidth(
            reduceMotion: reduceMotion
          ) * Geometry.scale,
          center: center,
          in: context
        )
      }

      if mode.usesFilledBadge {
        drawFilledBadge(
          mode: mode,
          color: drawingColor,
          foregroundColor: accentColor.map {
            TaskAccentBadgeContrast.foregroundColor(
              for: $0,
              appearance: NSAppearance.currentDrawing()
            )
          },
          center: center,
          in: context
        )
      } else {
        drawTrack(
          mode: mode,
          opacity: WorkerCrewRingGeometry.trackOpacity(for: mode),
          lineWidth: Geometry.ringLineWidth,
          color: drawingColor,
          center: center,
          in: context
        )
      }

      if mode == .working {
        drawActiveSegments(
          subagentCount: subagentCount,
          phase: phase,
          color: drawingColor,
          center: center,
          in: context
        )
      }
      return true
    }
    image.isTemplate = accentColor == nil
    image.accessibilityDescription = nil
    return image
  }

  private static func drawTrack(
    mode: WorkerCoreMode,
    opacity: Double,
    lineWidth: CGFloat,
    color: NSColor,
    center: CGPoint,
    in context: CGContext
  ) {
    context.setStrokeColor(
      resolvedColor(color).withAlphaComponent(opacity).cgColor
    )
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.setLineDash(
      phase: 0,
      lengths: WorkerCrewRingGeometry.trackDash(for: mode).map { $0 * Geometry.scale }
    )
    context.addEllipse(in: ringRect(center: center, diameter: Geometry.ringPathDiameter))
    context.strokePath()
  }

  private static func drawActiveSegments(
    subagentCount: Int,
    phase: TimeInterval,
    color: NSColor,
    center: CGPoint,
    in context: CGContext
  ) {
    let segmentCount = WorkerCrewRingGeometry.activeSegmentCount(
      subagentCount: subagentCount
    )
    let segmentLength = WorkerCrewRingGeometry.activeSegmentLength(
      subagentCount: subagentCount
    )
    let fullCircle = Double.pi * 2
    let phaseFraction =
      phase.truncatingRemainder(
        dividingBy: WorkerCrewRingGeometry.animationDuration
      ) / WorkerCrewRingGeometry.animationDuration
    let phaseAngle = fullCircle * phaseFraction

    context.setStrokeColor(resolvedColor(color).cgColor)
    context.setLineWidth(Geometry.ringLineWidth)
    context.setLineCap(.butt)
    context.setLineDash(phase: 0, lengths: [])

    for index in 0..<segmentCount {
      let startFraction = WorkerCrewRingGeometry.activeSegmentStart(
        index: index,
        subagentCount: subagentCount
      )
      let startAngle = Double.pi / 2 - phaseAngle - fullCircle * Double(startFraction)
      let endAngle = startAngle - fullCircle * Double(segmentLength)
      context.addArc(
        center: center,
        radius: Geometry.ringPathDiameter / 2,
        startAngle: startAngle,
        endAngle: endAngle,
        clockwise: true
      )
      context.strokePath()
    }
  }

  private static func drawFilledBadge(
    mode: WorkerCoreMode,
    color: NSColor,
    foregroundColor: NSColor?,
    center: CGPoint,
    in context: CGContext
  ) {
    context.setFillColor(resolvedColor(color).cgColor)
    context.fillEllipse(
      in: ringRect(
        center: center,
        diameter: Geometry.signalCoreDiameter
      )
    )

    guard let symbol = badgeSymbol(for: mode, foregroundColor: foregroundColor) else {
      return
    }
    let symbolRect = CGRect(
      x: center.x - symbol.size.width / 2,
      y: center.y - symbol.size.height / 2,
      width: symbol.size.width,
      height: symbol.size.height
    )
    if foregroundColor == nil {
      symbol.draw(
        in: symbolRect,
        from: .zero,
        operation: .destinationOut,
        fraction: 1,
        respectFlipped: false,
        hints: nil
      )
    } else {
      symbol.draw(in: symbolRect)
    }
  }

  private static func drawSignalHalo(
    opacity: Double,
    lineWidth: CGFloat,
    center: CGPoint,
    in context: CGContext
  ) {
    context.setStrokeColor(
      resolvedColor(.labelColor).withAlphaComponent(opacity).cgColor
    )
    context.setLineWidth(lineWidth)
    context.addEllipse(
      in: ringRect(center: center, diameter: Geometry.signalHaloDiameter)
    )
    context.strokePath()
  }

  private static func badgeSymbol(
    for mode: WorkerCoreMode,
    foregroundColor: NSColor?
  ) -> NSImage? {
    let symbolName: String
    let pointSize: CGFloat
    switch mode {
    case .approval, .incompatible:
      symbolName = "exclamationmark"
      pointSize = 10
    case .attention:
      symbolName = "questionmark"
      pointSize = 9
    case .blocked:
      symbolName = "xmark"
      pointSize = 7
    case .idle, .working, .ready, .degraded, .disconnected:
      return nil
    }

    var configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .black)
    if let foregroundColor {
      configuration = configuration.applying(
        NSImage.SymbolConfiguration(paletteColors: [foregroundColor])
      )
    }
    return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)
  }

  private static func ringRect(center: CGPoint, diameter: CGFloat) -> CGRect {
    CGRect(
      x: center.x - diameter / 2,
      y: center.y - diameter / 2,
      width: diameter,
      height: diameter
    )
  }

  private static func resolvedColor(_ color: NSColor) -> NSColor {
    color.usingColorSpace(.deviceRGB) ?? color
  }
}

#if DEBUG
  @MainActor
  final class MenuTaskRingDebugStripView: NSView {
    static let preferredSize = NSSize(width: 288, height: 38)

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      NSColor.white.setFill()
      NSBezierPath(rect: bounds).fill()

      let samples: [(WorkerCoreMode, Int, TimeInterval, Bool)] = [
        (.working, 0, 0, false),
        (.working, 0, 0.30, false),
        (.working, 2, 0, false),
        (.working, 2, 0.30, false),
        (.ready, 0, 0, false),
        (.ready, 0, 0, true),
        (.approval, 0, 0, false),
        (.attention, 0, 0, false),
        (.blocked, 0, 0, false),
      ]
      let spacing: CGFloat = 8
      var x: CGFloat = 8
      for sample in samples {
        let image = MenuTaskRingImage.render(
          mode: sample.0,
          subagentCount: sample.1,
          phase: sample.2,
          showsUnreadCompletionSignal: sample.3
        )
        image.draw(
          in: NSRect(
            x: x,
            y: (bounds.height - MenuTaskRingImage.size.height) / 2,
            width: MenuTaskRingImage.size.width,
            height: MenuTaskRingImage.size.height
          )
        )
        x += MenuTaskRingImage.size.width + spacing
      }
    }
  }
#endif
