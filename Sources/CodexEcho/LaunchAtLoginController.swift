import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
  case notRegistered
  case enabled
  case requiresApproval
  case unavailable
}

@MainActor
protocol LaunchAtLoginService {
  var status: LaunchAtLoginStatus { get }

  func register() throws
  func unregister() throws
  func openSystemSettings()
}

@MainActor
struct SystemLaunchAtLoginService: LaunchAtLoginService {
  private let service: SMAppService
  private let isMainApplicationBundle: Bool

  init(service: SMAppService = .mainApp) {
    self.service = service
    let bundle = Bundle.main
    isMainApplicationBundle = Self.isSupportedMainApplicationBundle(
      bundleURL: bundle.bundleURL,
      bundleIdentifier: bundle.bundleIdentifier,
      packageType: bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String
    )
  }

  var status: LaunchAtLoginStatus {
    Self.projectedStatus(
      for: service.status,
      isMainApplicationBundle: isMainApplicationBundle
    )
  }

  static func projectedStatus(
    for status: SMAppService.Status,
    isMainApplicationBundle: Bool
  ) -> LaunchAtLoginStatus {
    guard isMainApplicationBundle else { return .unavailable }

    return switch status {
    case .notRegistered, .notFound:
      .notRegistered
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    @unknown default:
      .unavailable
    }
  }

  static func isSupportedMainApplicationBundle(
    bundleURL: URL,
    bundleIdentifier: String?,
    packageType: String?
  ) -> Bool {
    bundleURL.pathExtension.lowercased() == "app"
      && bundleIdentifier == AppIdentity.bundleIdentifier
      && packageType == "APPL"
  }

  func register() throws {
    try service.register()
  }

  func unregister() throws {
    try service.unregister()
  }

  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
  @Published private(set) var status: LaunchAtLoginStatus
  @Published private(set) var errorMessage: String?

  private let service: any LaunchAtLoginService

  init(service: any LaunchAtLoginService = SystemLaunchAtLoginService()) {
    self.service = service
    status = service.status
  }

  var isEnabled: Bool {
    status == .enabled || status == .requiresApproval
  }

  var requiresApproval: Bool {
    status == .requiresApproval
  }

  var isAvailable: Bool {
    status != .unavailable
  }

  func setEnabled(_ shouldEnable: Bool) {
    guard isAvailable, shouldEnable != isEnabled else { return }
    errorMessage = nil

    do {
      if shouldEnable {
        try service.register()
      } else {
        try service.unregister()
      }
      refresh()
    } catch {
      status = service.status
      if requiresApproval {
        errorMessage = nil
      } else {
        errorMessage = "Couldn’t update Launch at Login. \(error.localizedDescription)"
      }
    }
  }

  func refresh() {
    let refreshedStatus = service.status
    if refreshedStatus != status {
      errorMessage = nil
    }
    status = refreshedStatus
  }

  func openSystemSettings() {
    service.openSystemSettings()
  }
}
