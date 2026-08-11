import AppKit
import CodexAppServer
import Foundation
import SwiftUI

enum TaskAccentColor: String, CaseIterable, Codable, Hashable, Identifiable {
  case blue
  case indigo
  case purple
  case pink
  case red
  case orange
  case green
  case teal
  case cyan
  case mint

  var id: Self { self }

  var displayName: String {
    switch self {
    case .blue: "Blue"
    case .indigo: "Indigo"
    case .purple: "Purple"
    case .pink: "Pink"
    case .red: "Red"
    case .orange: "Orange"
    case .green: "Green"
    case .teal: "Teal"
    case .cyan: "Cyan"
    case .mint: "Mint"
    }
  }

  var nsColor: NSColor {
    switch self {
    case .blue: .systemBlue
    case .indigo: .systemIndigo
    case .purple: .systemPurple
    case .pink: .systemPink
    case .red: .systemRed
    case .orange: .systemOrange
    case .green: .systemGreen
    case .teal: .systemTeal
    case .cyan: .systemCyan
    case .mint: .systemMint
    }
  }

  var color: Color { Color(nsColor: nsColor) }
}

@MainActor
enum TaskAccentBadgeContrast {
  static func foregroundColor(
    for accent: TaskAccentColor,
    appearance: NSAppearance
  ) -> NSColor {
    let background = resolvedColor(accent.nsColor, appearance: appearance)
    let black = NSColor.black
    let white = NSColor.white
    return contrastRatio(foreground: black, background: background)
      >= contrastRatio(foreground: white, background: background)
      ? black
      : white
  }

  static func resolvedColor(_ color: NSColor, appearance: NSAppearance) -> NSColor {
    var resolved = color
    appearance.performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB) ?? color
    }
    return resolved
  }

  static func contrastRatio(foreground: NSColor, background: NSColor) -> CGFloat {
    let lighter = max(relativeLuminance(foreground), relativeLuminance(background))
    let darker = min(relativeLuminance(foreground), relativeLuminance(background))
    return (lighter + 0.05) / (darker + 0.05)
  }

  private static func relativeLuminance(_ color: NSColor) -> CGFloat {
    guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
    return 0.2126 * linearComponent(rgb.redComponent)
      + 0.7152 * linearComponent(rgb.greenComponent)
      + 0.0722 * linearComponent(rgb.blueComponent)
  }

  private static func linearComponent(_ component: CGFloat) -> CGFloat {
    component <= 0.04045
      ? component / 12.92
      : pow((component + 0.055) / 1.055, 2.4)
  }
}

enum TaskColorPreference: Equatable {
  case inheritProject
  case system
  case accent(TaskAccentColor)
}

enum TaskColorResolution {
  static func effectiveColor(
    taskColor: TaskAccentColor?,
    projectColor: TaskAccentColor?,
    usesSystemTaskColor: Bool = false
  ) -> TaskAccentColor? {
    guard !usesSystemTaskColor else { return nil }
    return taskColor ?? projectColor
  }
}

enum ProjectColorIdentity {
  static func key(for cwd: String?) -> String? {
    guard let cwd else { return nil }
    let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed).standardizedFileURL.path
  }
}

enum TaskProjectIdentity: Equatable, Hashable {
  case project(String)
  case noProject

  static func resolve(
    projectContext: CodexThreadProjectContext?,
    fallbackCWD: String?
  ) -> Self? {
    switch projectContext {
    case .project(let path):
      return ProjectColorIdentity.key(for: path).map(Self.project)
    case .noProject:
      return .noProject
    case nil:
      return ProjectColorIdentity.key(for: fallbackCWD).map(Self.project)
    }
  }

  var projectID: String? {
    guard case .project(let projectID) = self else { return nil }
    return projectID
  }

  var displayName: String {
    switch self {
    case .project(let projectID):
      let name = URL(fileURLWithPath: projectID).lastPathComponent
      return name.isEmpty ? projectID : name
    case .noProject:
      return "No Project"
    }
  }
}

private struct LossyDecodable<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: Decoder) throws {
    value = try? Value(from: decoder)
  }
}

struct TaskColorPreferences: Codable, Equatable {
  private static let userDefaultsKey = "taskColorPreferencesV1"

  private var taskColorsByID: [String: TaskAccentColor] = [:]
  private var projectColorsByID: [String: TaskAccentColor] = [:]
  private var taskSystemColorIDs: Set<String> = []
  private var authoritativeProjectIDs: Set<String> = []
  private var migrationSourcesByProjectID: [String: String] = [:]
  private(set) var noProjectColor: TaskAccentColor?

  private enum CodingKeys: String, CodingKey {
    case taskColorsByID
    case projectColorsByID
    case taskSystemColorIDs
    case authoritativeProjectIDs
    case migrationSourcesByProjectID
    case noProjectColor
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let taskColors =
      (try? container.decode(
        [String: LossyDecodable<TaskAccentColor>].self,
        forKey: .taskColorsByID
      )) ?? [:]
    taskColorsByID = taskColors.compactMapValues { $0.value }

    let projectColors =
      (try? container.decode(
        [String: LossyDecodable<TaskAccentColor>].self,
        forKey: .projectColorsByID
      )) ?? [:]
    projectColorsByID = projectColors.compactMapValues { $0.value }

    let systemColorIDs =
      (try? container.decode(
        [LossyDecodable<String>].self,
        forKey: .taskSystemColorIDs
      )) ?? []
    taskSystemColorIDs = Set(systemColorIDs.compactMap { $0.value })
    let authoritativeIDs =
      (try? container.decode(
        [LossyDecodable<String>].self,
        forKey: .authoritativeProjectIDs
      )) ?? []
    authoritativeProjectIDs = Set(authoritativeIDs.compactMap { $0.value })
    let migrationSources =
      (try? container.decode(
        [String: LossyDecodable<String>].self,
        forKey: .migrationSourcesByProjectID
      )) ?? [:]
    migrationSourcesByProjectID = migrationSources.compactMapValues { $0.value }
    noProjectColor = try? container.decodeIfPresent(
      TaskAccentColor.self,
      forKey: .noProjectColor
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(taskColorsByID, forKey: .taskColorsByID)
    try container.encode(projectColorsByID, forKey: .projectColorsByID)
    try container.encode(taskSystemColorIDs.sorted(), forKey: .taskSystemColorIDs)
    try container.encode(
      authoritativeProjectIDs.sorted(),
      forKey: .authoritativeProjectIDs
    )
    try container.encode(
      migrationSourcesByProjectID,
      forKey: .migrationSourcesByProjectID
    )
    try container.encodeIfPresent(noProjectColor, forKey: .noProjectColor)
  }

  static func load(from userDefaults: UserDefaults) -> Self {
    guard let data = userDefaults.data(forKey: userDefaultsKey),
      let preferences = try? JSONDecoder().decode(Self.self, from: data)
    else {
      return Self()
    }
    return preferences
  }

  func save(to userDefaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    userDefaults.set(data, forKey: Self.userDefaultsKey)
  }

  func taskColor(for taskID: String) -> TaskAccentColor? {
    taskColorsByID[taskID]
  }

  func taskColorPreference(for taskID: String) -> TaskColorPreference {
    if taskSystemColorIDs.contains(taskID) { return .system }
    if let color = taskColorsByID[taskID] { return .accent(color) }
    return .inheritProject
  }

  func projectColor(for projectID: String?) -> TaskAccentColor? {
    guard let projectID else { return nil }
    return projectColorsByID[projectID]
  }

  func parentColor(for identity: TaskProjectIdentity?) -> TaskAccentColor? {
    switch identity {
    case .project(let projectID): projectColor(for: projectID)
    case .noProject: noProjectColor
    case nil: nil
    }
  }

  var customizedProjectIDs: Set<String> {
    Set(projectColorsByID.keys)
  }

  mutating func setTaskColor(_ color: TaskAccentColor?, for taskID: String) {
    setTaskColorPreference(
      color.map(TaskColorPreference.accent) ?? .inheritProject,
      for: taskID
    )
  }

  mutating func setTaskColorPreference(
    _ preference: TaskColorPreference,
    for taskID: String
  ) {
    switch preference {
    case .inheritProject:
      taskColorsByID.removeValue(forKey: taskID)
      taskSystemColorIDs.remove(taskID)
    case .system:
      taskColorsByID.removeValue(forKey: taskID)
      taskSystemColorIDs.insert(taskID)
    case .accent(let color):
      taskColorsByID[taskID] = color
      taskSystemColorIDs.remove(taskID)
    }
  }

  mutating func setProjectColor(_ color: TaskAccentColor?, for projectID: String) {
    projectColorsByID[projectID] = color
    authoritativeProjectIDs.insert(projectID)
    migrationSourcesByProjectID.removeValue(forKey: projectID)
  }

  @discardableResult
  mutating func migrateProjectColors(
    from legacyProjectIDs: [String],
    to canonicalProjectID: String
  ) -> Bool {
    ProjectPreferenceMigration.migrate(
      valuesByProjectID: &projectColorsByID,
      authoritativeProjectIDs: &authoritativeProjectIDs,
      migrationSourcesByProjectID: &migrationSourcesByProjectID,
      from: legacyProjectIDs,
      to: canonicalProjectID
    )
  }

  mutating func setNoProjectColor(_ color: TaskAccentColor?) {
    noProjectColor = color
  }
}
