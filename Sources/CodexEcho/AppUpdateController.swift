import Combine
import Foundation
import Sparkle

enum AppUpdateConfiguration {
  static let enabledInfoKey = "CodexEchoUpdatesEnabled"

  static func isEnabled(infoDictionary: [String: Any]?) -> Bool {
    infoDictionary?[enabledInfoKey] as? Bool == true
  }

  static func displayVersion(infoDictionary: [String: Any]?) -> String {
    guard
      let version = infoDictionary?["CFBundleShortVersionString"] as? String,
      !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return "Development"
    }
    return version
  }
}

@MainActor
protocol AppUpdateChecking: AnyObject {
  var canCheckForUpdates: Bool { get }
  func checkForUpdates()
}

@MainActor
final class SparkleAppUpdateController: ObservableObject, AppUpdateChecking {
  @Published private(set) var canCheckForUpdates: Bool
  @Published private(set) var automaticallyChecksForUpdates: Bool

  let displayVersion: String
  let isAvailable: Bool

  private let standardUpdaterController: SPUStandardUpdaterController?
  private let checkForUpdatesAction: (() -> Void)?
  private let setAutomaticallyChecksForUpdatesAction: ((Bool) -> Void)?
  private var updaterStateObservations = Set<AnyCancellable>()

  init(bundle: Bundle = .main) {
    let standardUpdaterController: SPUStandardUpdaterController?
    if AppUpdateConfiguration.isEnabled(
      infoDictionary: bundle.infoDictionary
    ) {
      standardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
      )
    } else {
      standardUpdaterController = nil
    }
    self.standardUpdaterController = standardUpdaterController
    displayVersion = AppUpdateConfiguration.displayVersion(
      infoDictionary: bundle.infoDictionary
    )
    isAvailable = standardUpdaterController != nil
    canCheckForUpdates =
      standardUpdaterController?.updater.canCheckForUpdates ?? false
    automaticallyChecksForUpdates =
      standardUpdaterController?.updater.automaticallyChecksForUpdates ?? false
    checkForUpdatesAction = nil
    setAutomaticallyChecksForUpdatesAction = nil
    if let updater = standardUpdaterController?.updater {
      observeUpdaterState(
        canCheckForUpdatesPublisher: updater.publisher(
          for: \.canCheckForUpdates,
          options: [.new]
        ).eraseToAnyPublisher(),
        automaticallyChecksForUpdatesPublisher: updater.publisher(
          for: \.automaticallyChecksForUpdates,
          options: [.new]
        ).eraseToAnyPublisher()
      )
      // Sparkle starts its scheduled cycle on the next main run loop. Keep the
      // launch check in this synchronous startup window so the two cannot race.
      Self.checkForUpdatesInBackgroundAtLaunchIfNeeded(
        isAvailable: true,
        canCheckForUpdates: canCheckForUpdates,
        automaticallyChecksForUpdates: automaticallyChecksForUpdates,
        action: updater.checkForUpdatesInBackground
      )
    }
  }

  init(
    displayVersion: String,
    isAvailable: Bool,
    canCheckForUpdates: Bool,
    automaticallyChecksForUpdates: Bool,
    canCheckForUpdatesPublisher: AnyPublisher<Bool, Never>? = nil,
    automaticallyChecksForUpdatesPublisher: AnyPublisher<Bool, Never>? = nil,
    checkForUpdatesAction: @escaping () -> Void = {},
    setAutomaticallyChecksForUpdatesAction: @escaping (Bool) -> Void = { _ in },
    checkForUpdatesInBackgroundAtLaunchAction: @escaping () -> Void = {}
  ) {
    standardUpdaterController = nil
    self.displayVersion = displayVersion
    self.isAvailable = isAvailable
    self.canCheckForUpdates = canCheckForUpdates
    self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    self.checkForUpdatesAction = checkForUpdatesAction
    self.setAutomaticallyChecksForUpdatesAction =
      setAutomaticallyChecksForUpdatesAction
    observeUpdaterState(
      canCheckForUpdatesPublisher: canCheckForUpdatesPublisher,
      automaticallyChecksForUpdatesPublisher:
        automaticallyChecksForUpdatesPublisher
    )
    Self.checkForUpdatesInBackgroundAtLaunchIfNeeded(
      isAvailable: isAvailable,
      canCheckForUpdates: canCheckForUpdates,
      automaticallyChecksForUpdates: automaticallyChecksForUpdates,
      action: checkForUpdatesInBackgroundAtLaunchAction
    )
  }

  func checkForUpdates() {
    guard isAvailable, canCheckForUpdates else { return }
    if let standardUpdaterController {
      standardUpdaterController.checkForUpdates(nil)
    } else {
      checkForUpdatesAction?()
    }
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    guard isAvailable else { return }
    if let standardUpdaterController {
      standardUpdaterController.updater.automaticallyChecksForUpdates = enabled
      automaticallyChecksForUpdates =
        standardUpdaterController.updater.automaticallyChecksForUpdates
    } else {
      setAutomaticallyChecksForUpdatesAction?(enabled)
      automaticallyChecksForUpdates = enabled
    }
  }

  func refresh() {
    if let standardUpdaterController {
      canCheckForUpdates =
        standardUpdaterController.updater.canCheckForUpdates
      automaticallyChecksForUpdates =
        standardUpdaterController.updater.automaticallyChecksForUpdates
    }
  }

  private func observeUpdaterState(
    canCheckForUpdatesPublisher: AnyPublisher<Bool, Never>?,
    automaticallyChecksForUpdatesPublisher: AnyPublisher<Bool, Never>?
  ) {
    canCheckForUpdatesPublisher?
      .removeDuplicates()
      .sink { [weak self] canCheckForUpdates in
        self?.canCheckForUpdates = canCheckForUpdates
      }
      .store(in: &updaterStateObservations)
    automaticallyChecksForUpdatesPublisher?
      .removeDuplicates()
      .sink { [weak self] automaticallyChecksForUpdates in
        self?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
      }
      .store(in: &updaterStateObservations)
  }

  private static func checkForUpdatesInBackgroundAtLaunchIfNeeded(
    isAvailable: Bool,
    canCheckForUpdates: Bool,
    automaticallyChecksForUpdates: Bool,
    action: () -> Void
  ) {
    guard
      isAvailable,
      canCheckForUpdates,
      automaticallyChecksForUpdates
    else { return }
    action()
  }
}
