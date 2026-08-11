import Foundation

public enum CodexThreadProjectContext: Equatable, Sendable {
  case project(path: String)
  case noProject
}

public struct CodexProjectPathAlias: Equatable, Hashable, Sendable {
  public let assignmentPath: String
  public let canonicalPath: String

  init(assignmentPath: String, canonicalPath: String) {
    self.assignmentPath = assignmentPath
    self.canonicalPath = canonicalPath
  }
}

struct CodexDesktopProjectStateSnapshot: Equatable {
  private let projectPathsByThreadID: [String: String]
  private let projectlessThreadIDs: Set<String>
  let projectPathAliases: [CodexProjectPathAlias]

  static let empty = Self(
    projectPathsByThreadID: [:],
    projectlessThreadIDs: [],
    projectPathAliases: []
  )

  init?(object: [String: Any]) {
    let canonicalProjectPaths = Self.canonicalProjectPaths(
      from: object["local-projects"]
    )

    let rawAssignments: [String: Any]
    if let value = object["thread-project-assignments"] {
      guard let assignments = value as? [String: Any] else { return nil }
      rawAssignments = assignments
    } else {
      rawAssignments = [:]
    }

    var projectPathsByThreadID: [String: String] = [:]
    var projectPathAliases = Set<CodexProjectPathAlias>()
    for (threadID, value) in rawAssignments {
      guard
        let assignment = value as? [String: Any],
        assignment["projectKind"] as? String == "local",
        let assignedPath = Self.nonEmptyPath(assignment["path"] as? String)
          ?? Self.nonEmptyPath(assignment["cwd"] as? String)
      else { continue }
      let projectID = Self.nonEmptyPath(assignment["projectId"] as? String)
      let canonicalPath = projectID
        .flatMap { canonicalProjectPaths[$0] }
        ?? assignedPath
      projectPathsByThreadID[threadID] = canonicalPath
      if assignedPath != canonicalPath {
        projectPathAliases.insert(
          CodexProjectPathAlias(
            assignmentPath: assignedPath,
            canonicalPath: canonicalPath
          )
        )
      }
    }

    let rawProjectlessThreadIDs: [Any]
    if let value = object["projectless-thread-ids"] {
      guard let threadIDs = value as? [Any] else { return nil }
      rawProjectlessThreadIDs = threadIDs
    } else {
      rawProjectlessThreadIDs = []
    }

    self.projectPathsByThreadID = projectPathsByThreadID
    self.projectlessThreadIDs = Set(rawProjectlessThreadIDs.compactMap { $0 as? String })
    self.projectPathAliases = projectPathAliases.sorted {
      if $0.canonicalPath != $1.canonicalPath {
        return $0.canonicalPath < $1.canonicalPath
      }
      return $0.assignmentPath < $1.assignmentPath
    }
  }

  private init(
    projectPathsByThreadID: [String: String],
    projectlessThreadIDs: Set<String>,
    projectPathAliases: [CodexProjectPathAlias]
  ) {
    self.projectPathsByThreadID = projectPathsByThreadID
    self.projectlessThreadIDs = projectlessThreadIDs
    self.projectPathAliases = projectPathAliases
  }

  func projectContext(for threadID: String) -> CodexThreadProjectContext? {
    if let path = projectPathsByThreadID[threadID] {
      return .project(path: path)
    }
    if projectlessThreadIDs.contains(threadID) {
      return .noProject
    }
    return nil
  }

  private static func nonEmptyPath(_ path: String?) -> String? {
    guard let path else { return nil }
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func canonicalProjectPaths(
    from value: Any?
  ) -> [String: String] {
    guard let projects = value as? [String: Any] else { return [:] }

    var pathsByProjectID: [String: String] = [:]
    for (projectID, value) in projects {
      guard
        let project = value as? [String: Any],
        let rootPaths = project["rootPaths"] as? [Any],
        let rootPath = rootPaths.lazy
          .compactMap({ $0 as? String })
          .compactMap(nonEmptyPath)
          .first
      else { continue }
      pathsByProjectID[projectID] = rootPath
    }
    return pathsByProjectID
  }
}

final class CodexDesktopProjectStateReader {
  private struct FileFingerprint: Equatable {
    let modificationDate: Date?
    let size: Int?
  }

  private let stateURL: URL
  private var lastAttemptedFingerprint: FileFingerprint?
  private var lastValidSnapshot = CodexDesktopProjectStateSnapshot.empty

  init(
    stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent(".codex-global-state.json")
  ) {
    self.stateURL = stateURL
  }

  func snapshot() -> CodexDesktopProjectStateSnapshot {
    guard let fingerprint = fingerprint() else {
      return lastValidSnapshot
    }
    guard fingerprint != lastAttemptedFingerprint else {
      return lastValidSnapshot
    }
    lastAttemptedFingerprint = fingerprint

    guard
      let data = try? Data(contentsOf: stateURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let snapshot = CodexDesktopProjectStateSnapshot(object: object)
    else {
      return lastValidSnapshot
    }
    lastValidSnapshot = snapshot
    return snapshot
  }

  private func fingerprint() -> FileFingerprint? {
    guard
      let values = try? stateURL.resourceValues(
        forKeys: [.contentModificationDateKey, .fileSizeKey]
      ),
      values.fileSize != nil
    else { return nil }
    return FileFingerprint(
      modificationDate: values.contentModificationDate,
      size: values.fileSize
    )
  }
}
