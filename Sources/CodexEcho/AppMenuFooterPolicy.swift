struct AppMenuFooterItem: Equatable {
  let title: String
  let action: AppMenuFooterAction
  let keyEquivalent: String
  let systemSymbolName: String?
  let isAlternate: Bool
  let isEnabled: Bool

  init(
    title: String,
    action: AppMenuFooterAction,
    keyEquivalent: String = "",
    systemSymbolName: String? = nil,
    isAlternate: Bool = false,
    isEnabled: Bool
  ) {
    self.title = title
    self.action = action
    self.keyEquivalent = keyEquivalent
    self.systemSymbolName = systemSymbolName
    self.isAlternate = isAlternate
    self.isEnabled = isEnabled
  }
}

enum AppMenuFooterAction: Equatable {
  case about
  case showDiagnostics
  case checkForUpdates
  case settings
  case quit
}

enum AppMenuFooterElement: Equatable {
  case item(AppMenuFooterItem)
  case separator
}

enum AppMenuFooterPolicy {
  static func elements(
    canCheckForUpdates: Bool,
    canOpenSettings: Bool
  ) -> [AppMenuFooterElement] {
    [
      .item(
        AppMenuFooterItem(
          title: AppPresentationCopy.aboutMenuTitle,
          action: .about,
          isEnabled: true
        )
      ),
      .item(
        AppMenuFooterItem(
          title: AppPresentationCopy.showDiagnosticsMenuTitle,
          action: .showDiagnostics,
          systemSymbolName: "stethoscope",
          isAlternate: true,
          isEnabled: true
        )
      ),
      .item(
        AppMenuFooterItem(
          title: AppPresentationCopy.checkForUpdatesMenuTitle,
          action: .checkForUpdates,
          isEnabled: canCheckForUpdates
        )
      ),
      .separator,
      .item(
        AppMenuFooterItem(
          title: "Settings…",
          action: .settings,
          keyEquivalent: ",",
          isEnabled: canOpenSettings
        )
      ),
      .item(
        AppMenuFooterItem(
          title: AppPresentationCopy.quitMenuTitle,
          action: .quit,
          keyEquivalent: "q",
          isEnabled: true
        )
      ),
    ]
  }
}

extension Array where Element == AppMenuFooterElement {
  func item(for action: AppMenuFooterAction) -> AppMenuFooterItem? {
    for element in self {
      guard case .item(let item) = element, item.action == action else {
        continue
      }
      return item
    }
    return nil
  }
}
