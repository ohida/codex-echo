import CodexAppServer
import Foundation

@MainActor
final class TaskProjectIdentityResolver {
  private var repositoryProjectIDsByCWD: [String: String] = [:]

  func resolve(
    projectContext: CodexThreadProjectContext?,
    fallbackCWD: String?
  ) -> TaskProjectIdentity? {
    switch projectContext {
    case .project(let path):
      return ProjectColorIdentity.key(for: path).map(TaskProjectIdentity.project)
    case .noProject:
      return .noProject
    case nil:
      guard let cwd = ProjectColorIdentity.key(for: fallbackCWD) else { return nil }
      if let cachedProjectID = repositoryProjectIDsByCWD[cwd] {
        return .project(cachedProjectID)
      }
      let projectID = repositoryProjectID(containing: cwd) ?? cwd
      repositoryProjectIDsByCWD[cwd] = projectID
      return .project(projectID)
    }
  }

  private func repositoryProjectID(containing cwd: String) -> String? {
    var directoryPath = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path

    while true {
      let dotGit = URL(fileURLWithPath: directoryPath, isDirectory: true)
        .appendingPathComponent(".git")
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
        if isDirectory.boolValue {
          return directoryPath
        }
        return linkedWorktreeProjectID(dotGit: dotGit) ?? directoryPath
      }

      let parentPath = (directoryPath as NSString).deletingLastPathComponent
      guard !parentPath.isEmpty, parentPath != directoryPath else { return nil }
      directoryPath = parentPath
    }
  }

  private func linkedWorktreeProjectID(dotGit: URL) -> String? {
    guard
      let marker = try? String(contentsOf: dotGit, encoding: .utf8),
      let firstLine = marker.split(whereSeparator: \Character.isNewline).first
    else { return nil }
    let prefix = "gitdir:"
    guard firstLine.hasPrefix(prefix) else { return nil }
    let rawGitDirectory = firstLine.dropFirst(prefix.count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawGitDirectory.isEmpty else { return nil }

    let gitDirectory = resolvedFileURL(
      rawGitDirectory,
      relativeTo: dotGit.deletingLastPathComponent()
    )
    let commonDirectoryFile = gitDirectory.appendingPathComponent("commondir")
    guard
      let rawCommonDirectory = try? String(
        contentsOf: commonDirectoryFile,
        encoding: .utf8
      ).trimmingCharacters(in: .whitespacesAndNewlines),
      !rawCommonDirectory.isEmpty
    else { return nil }

    let commonDirectory = resolvedFileURL(
      rawCommonDirectory,
      relativeTo: gitDirectory
    )
    guard commonDirectory.lastPathComponent == ".git" else { return nil }
    return commonDirectory.deletingLastPathComponent().path
  }

  private func resolvedFileURL(_ path: String, relativeTo base: URL) -> URL {
    let url = path.hasPrefix("/")
      ? URL(fileURLWithPath: path)
      : base.appendingPathComponent(path)
    return url.standardizedFileURL
  }
}
