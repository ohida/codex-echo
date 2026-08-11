import AppKit
import Combine
import SwiftUI

@MainActor
protocol DiagnosticsClipboardWriting: AnyObject {
  @discardableResult
  func write(_ string: String) -> Bool
}

@MainActor
final class SystemDiagnosticsClipboard: DiagnosticsClipboardWriting {
  @discardableResult
  func write(_ string: String) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setString(string, forType: .string)
  }
}

@MainActor
final class SupportDiagnosticsViewModel: ObservableObject {
  @Published private(set) var report: String

  private let makeReport: () -> String
  private let clipboard: any DiagnosticsClipboardWriting

  init(
    makeReport: @escaping () -> String,
    clipboard: any DiagnosticsClipboardWriting = SystemDiagnosticsClipboard()
  ) {
    self.makeReport = makeReport
    self.clipboard = clipboard
    report = makeReport()
  }

  func refresh() {
    report = makeReport()
  }

  func copy() {
    _ = clipboard.write(report)
  }
}

@MainActor
struct SupportDiagnosticsView: View {
  @ObservedObject var viewModel: SupportDiagnosticsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SelectableDiagnosticsReport(text: viewModel.report)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      HStack(spacing: 8) {
        Spacer()
        Button("Refresh") {
          viewModel.refresh()
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Refresh diagnostics")
        Button("Copy") {
          viewModel.copy()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Copy diagnostics")
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 500, minHeight: 340)
  }
}

@MainActor
private struct SelectableDiagnosticsReport: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .bezelBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true

    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.allowsUndo = false
    textView.usesFindBar = true
    textView.font = .monospacedSystemFont(
      ofSize: NSFont.systemFontSize,
      weight: .regular
    )
    textView.textContainerInset = NSSize(width: 10, height: 10)
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.setAccessibilityLabel("Diagnostics report")
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    guard textView.string != text else { return }
    textView.string = text
    textView.scrollToBeginningOfDocument(nil)
  }
}

@MainActor
enum SupportDiagnosticsWindowFactory {
  static let frameAutosaveName =
    NSWindow.FrameAutosaveName("CodexEcho.Diagnostics")
  static let defaultContentSize = NSSize(width: 620, height: 440)

  static func make(
    viewModel: SupportDiagnosticsViewModel,
    savesFrame: Bool = true
  ) -> NSWindowController {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: defaultContentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Codex Echo Diagnostics"
    window.contentMinSize = NSSize(width: 500, height: 340)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.center()
    if savesFrame {
      window.setFrameAutosaveName(frameAutosaveName)
    }
    window.contentView = NSHostingView(
      rootView: SupportDiagnosticsView(viewModel: viewModel)
    )

    let windowController = NSWindowController(window: window)
    windowController.shouldCascadeWindows = true
    return windowController
  }
}
