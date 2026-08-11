import AppKit

enum AppPresentationCopy {
  static let displayName = "Codex Echo"
  static let aboutMenuTitle = "About \(displayName)"
  static let showDiagnosticsMenuTitle = "Show Diagnostics…"
  static let checkForUpdatesMenuTitle = "Check for Updates…"
  static let sendFeedbackMenuTitle = "Send Feedback…"
  static let feedbackFormURL = URL(
    string:
      "https://docs.google.com/forms/d/e/1FAIpQLSdCoMOXOOVO86CY6wVNDVP1vMmCudkLGQbxxAVAqvnBiny5Jw/viewform"
  )!
  static var aboutPanelFeedbackLinkTextAttributes: [NSAttributedString.Key: Any] {
    [
      .cursor: NSCursor.pointingHand,
      .foregroundColor: NSColor.labelColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
  }
  static var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    var attributes = aboutPanelFeedbackLinkTextAttributes
    attributes[.font] = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    attributes[.link] = feedbackFormURL
    attributes[.paragraphStyle] = paragraphStyle
    return [
      .credits: NSAttributedString(
        string: sendFeedbackMenuTitle,
        attributes: attributes
      )
    ]
  }
  static let settingsWindowTitle = "\(displayName) Settings"
  static let quitMenuTitle = "Quit \(displayName)"
  static let startupAnnouncement = "\(displayName) online."
  static let launchAtLoginApprovalHint =
    "Opens System Settings so \(displayName) can be approved to launch at login."
  static let launchAtLoginDescription =
    "Open \(displayName) automatically when you log in."
}
