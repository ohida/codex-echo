import Foundation

struct SpokenUpdateVoice: Codable, Hashable, Identifiable {
  let identifier: String
  let displayName: String
  let language: String

  static let eddy = eloquenceVoice(named: "Eddy")
  static let flo = eloquenceVoice(named: "Flo")
  static let grandma = eloquenceVoice(named: "Grandma")
  static let grandpa = eloquenceVoice(named: "Grandpa")
  static let reed = eloquenceVoice(named: "Reed")
  static let rocko = eloquenceVoice(named: "Rocko")
  static let sandy = eloquenceVoice(named: "Sandy")
  static let shelley = eloquenceVoice(named: "Shelley")
  static let zarvox = Self(
    identifier: "com.apple.speech.synthesis.voice.Zarvox",
    displayName: "Zarvox",
    language: "en-US"
  )
  static let defaultVoice = zarvox

  var id: String { identifier }

  private static func eloquenceVoice(named name: String) -> Self {
    Self(
      identifier: "com.apple.eloquence.en-US.\(name)",
      displayName: name,
      language: "en-US"
    )
  }
}

enum TaskVoicePreference: Equatable {
  case inheritProject
  case defaultVoice
  case voice(SpokenUpdateVoice)
}

enum TaskVoiceResolution {
  static func effectiveVoice(
    taskVoice: SpokenUpdateVoice?,
    projectVoice: SpokenUpdateVoice?,
    usesDefaultTaskVoice: Bool = false,
    defaultVoice: SpokenUpdateVoice = .defaultVoice
  ) -> SpokenUpdateVoice {
    guard !usesDefaultTaskVoice else { return defaultVoice }
    return taskVoice ?? projectVoice ?? defaultVoice
  }
}

private struct LossyVoiceDecodable<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: Decoder) throws {
    value = try? Value(from: decoder)
  }
}

struct TaskVoicePreferences: Codable, Equatable {
  private static let userDefaultsKey = "taskVoicePreferencesV1"

  private var taskVoicesByID: [String: SpokenUpdateVoice] = [:]
  private var projectVoicesByID: [String: SpokenUpdateVoice] = [:]
  private var taskDefaultVoiceIDs: Set<String> = []
  private var authoritativeProjectIDs: Set<String> = []
  private var migrationSourcesByProjectID: [String: String] = [:]
  private(set) var noProjectVoice: SpokenUpdateVoice?

  private enum CodingKeys: String, CodingKey {
    case taskVoicesByID
    case projectVoicesByID
    case taskDefaultVoiceIDs
    case authoritativeProjectIDs
    case migrationSourcesByProjectID
    case noProjectVoice
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let taskVoices =
      (try? container.decode(
        [String: LossyVoiceDecodable<SpokenUpdateVoice>].self,
        forKey: .taskVoicesByID
      )) ?? [:]
    taskVoicesByID = taskVoices.compactMapValues(\.value)

    let projectVoices =
      (try? container.decode(
        [String: LossyVoiceDecodable<SpokenUpdateVoice>].self,
        forKey: .projectVoicesByID
      )) ?? [:]
    projectVoicesByID = projectVoices.compactMapValues(\.value)

    let defaultVoiceIDs =
      (try? container.decode(
        [LossyVoiceDecodable<String>].self,
        forKey: .taskDefaultVoiceIDs
      )) ?? []
    taskDefaultVoiceIDs = Set(defaultVoiceIDs.compactMap(\.value))
    let authoritativeIDs =
      (try? container.decode(
        [LossyVoiceDecodable<String>].self,
        forKey: .authoritativeProjectIDs
      )) ?? []
    authoritativeProjectIDs = Set(authoritativeIDs.compactMap(\.value))
    let migrationSources =
      (try? container.decode(
        [String: LossyVoiceDecodable<String>].self,
        forKey: .migrationSourcesByProjectID
      )) ?? [:]
    migrationSourcesByProjectID = migrationSources.compactMapValues(\.value)
    noProjectVoice = try? container.decodeIfPresent(
      SpokenUpdateVoice.self,
      forKey: .noProjectVoice
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(taskVoicesByID, forKey: .taskVoicesByID)
    try container.encode(projectVoicesByID, forKey: .projectVoicesByID)
    try container.encode(taskDefaultVoiceIDs.sorted(), forKey: .taskDefaultVoiceIDs)
    try container.encode(
      authoritativeProjectIDs.sorted(),
      forKey: .authoritativeProjectIDs
    )
    try container.encode(
      migrationSourcesByProjectID,
      forKey: .migrationSourcesByProjectID
    )
    try container.encodeIfPresent(noProjectVoice, forKey: .noProjectVoice)
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

  func taskVoice(for taskID: String) -> SpokenUpdateVoice? {
    taskVoicesByID[taskID]
  }

  func taskVoicePreference(for taskID: String) -> TaskVoicePreference {
    if taskDefaultVoiceIDs.contains(taskID) { return .defaultVoice }
    if let voice = taskVoicesByID[taskID] { return .voice(voice) }
    return .inheritProject
  }

  func projectVoice(for projectID: String?) -> SpokenUpdateVoice? {
    guard let projectID else { return nil }
    return projectVoicesByID[projectID]
  }

  func parentVoice(for identity: TaskProjectIdentity?) -> SpokenUpdateVoice? {
    switch identity {
    case .project(let projectID): projectVoice(for: projectID)
    case .noProject: noProjectVoice
    case nil: nil
    }
  }

  var customizedProjectIDs: Set<String> {
    Set(projectVoicesByID.keys)
  }

  mutating func setTaskVoicePreference(
    _ preference: TaskVoicePreference,
    for taskID: String
  ) {
    switch preference {
    case .inheritProject:
      taskVoicesByID.removeValue(forKey: taskID)
      taskDefaultVoiceIDs.remove(taskID)
    case .defaultVoice:
      taskVoicesByID.removeValue(forKey: taskID)
      taskDefaultVoiceIDs.insert(taskID)
    case .voice(let voice):
      taskVoicesByID[taskID] = voice
      taskDefaultVoiceIDs.remove(taskID)
    }
  }

  mutating func setProjectVoice(
    _ voice: SpokenUpdateVoice?,
    for projectID: String
  ) {
    projectVoicesByID[projectID] = voice
    authoritativeProjectIDs.insert(projectID)
    migrationSourcesByProjectID.removeValue(forKey: projectID)
  }

  @discardableResult
  mutating func migrateProjectVoices(
    from legacyProjectIDs: [String],
    to canonicalProjectID: String
  ) -> Bool {
    ProjectPreferenceMigration.migrate(
      valuesByProjectID: &projectVoicesByID,
      authoritativeProjectIDs: &authoritativeProjectIDs,
      migrationSourcesByProjectID: &migrationSourcesByProjectID,
      from: legacyProjectIDs,
      to: canonicalProjectID
    )
  }

  mutating func setNoProjectVoice(_ voice: SpokenUpdateVoice?) {
    noProjectVoice = voice
  }
}
