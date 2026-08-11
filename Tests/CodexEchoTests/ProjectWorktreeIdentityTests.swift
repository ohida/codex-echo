import Foundation
import XCTest

@testable import CodexAppServer
@testable import CodexEcho
@testable import CodexIPC

final class ProjectWorktreeIdentityTests: XCTestCase {
  @MainActor
  func testRepositoryFallbackKeepsDistinctClonesAndExplicitNoProjectSeparate() throws {
    let firstRepository = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-echo-clone-a-\(UUID().uuidString)", isDirectory: true)
    let secondRepository = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-echo-clone-b-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: firstRepository)
      try? FileManager.default.removeItem(at: secondRepository)
    }
    for repository in [firstRepository, secondRepository] {
      try FileManager.default.createDirectory(
        at: repository.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
      )
    }

    let resolver = TaskProjectIdentityResolver()
    XCTAssertEqual(
      resolver.resolve(projectContext: nil, fallbackCWD: firstRepository.path),
      .project(firstRepository.path)
    )
    XCTAssertEqual(
      resolver.resolve(projectContext: nil, fallbackCWD: secondRepository.path),
      .project(secondRepository.path)
    )
    XCTAssertEqual(
      resolver.resolve(
        projectContext: .noProject,
        fallbackCWD: firstRepository.path
      ),
      .noProject
    )
    XCTAssertEqual(
      resolver.resolve(projectContext: nil, fallbackCWD: "/"),
      .project("/")
    )
  }

  @MainActor
  func testWorktreeInheritsProjectColorBeforeDesktopAssignmentArrives() throws {
    let repositoryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-echo-repository-\(UUID().uuidString)", isDirectory: true)
    let worktreeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-echo-worktree-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: repositoryDirectory)
      try? FileManager.default.removeItem(at: worktreeDirectory)
    }
    let worktreeGitDirectory = repositoryDirectory
      .appendingPathComponent(".git/worktrees/live", isDirectory: true)
    try FileManager.default.createDirectory(
      at: worktreeGitDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: worktreeDirectory,
      withIntermediateDirectories: true
    )
    try "../..\n".write(
      to: worktreeGitDirectory.appendingPathComponent("commondir"),
      atomically: true,
      encoding: .utf8
    )
    try "gitdir: \(worktreeGitDirectory.path)\n".write(
      to: worktreeDirectory.appendingPathComponent(".git"),
      atomically: true,
      encoding: .utf8
    )

    let suiteName = "ProjectWorktreeIdentityTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var colors = TaskColorPreferences()
    colors.setProjectColor(.orange, for: repositoryDirectory.path)
    colors.save(to: defaults)
    var voices = TaskVoicePreferences()
    voices.setProjectVoice(.reed, for: repositoryDirectory.path)
    voices.save(to: defaults)

    let ipcClient = CodexIPCClient()
    let model = CodexActivityModel(
      ipcClient: ipcClient,
      appServerClient: CodexAppServerClient(
        executableURL: URL(fileURLWithPath: "/usr/bin/false")
      ),
      desktopAppController: WorktreeIdentityTestDesktopAppController(),
      settings: MenuBarSettings(userDefaults: defaults),
      userDefaults: defaults,
      startsTransportClients: false
    )

    for (threadID, cwd) in [
      ("main-thread", repositoryDirectory.path),
      ("worktree-thread", worktreeDirectory.path),
    ] {
      ipcClient.eventHandler?(
        .snapshot(
          conversationID: threadID,
          revision: 1,
          state: workingConversationState(threadID: threadID, cwd: cwd)
        )
      )
    }

    XCTAssertEqual(model.tasks.count, 2)
    XCTAssertTrue(model.tasks.allSatisfy { $0.projectID == repositoryDirectory.path })
    XCTAssertTrue(model.tasks.allSatisfy { $0.effectiveColor == .orange })
    XCTAssertTrue(model.tasks.allSatisfy { $0.effectiveVoice == .reed })
  }

  @MainActor
  func testMainAndWorktreeTasksShareCanonicalColorAndVoice() throws {
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-echo-project-aliases-\(UUID().uuidString)", isDirectory: true)
    let canonicalProject = fixtureRoot
      .appendingPathComponent("canonical/medianoche", isDirectory: true)
    let worktreeProject = fixtureRoot
      .appendingPathComponent("worktrees/ff9f/medianoche", isDirectory: true)
    let dormantWorktreeProject = fixtureRoot
      .appendingPathComponent("worktrees/aaaa/medianoche", isDirectory: true)
    for project in [canonicalProject, worktreeProject, dormantWorktreeProject] {
      try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }

    let suiteName = "ProjectWorktreeIdentityTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let canonicalProjectID = canonicalProject.path
    let worktreeProjectID = worktreeProject.path
    let dormantWorktreeProjectID = dormantWorktreeProject.path

    var colors = TaskColorPreferences()
    colors.setProjectColor(.orange, for: canonicalProjectID)
    colors.setProjectColor(.green, for: worktreeProjectID)
    colors.setProjectColor(.purple, for: dormantWorktreeProjectID)
    colors.save(to: defaults)

    var voices = TaskVoicePreferences()
    voices.setProjectVoice(.reed, for: canonicalProjectID)
    voices.setProjectVoice(.flo, for: worktreeProjectID)
    voices.setProjectVoice(.sandy, for: dormantWorktreeProjectID)
    voices.save(to: defaults)

    let ipcClient = CodexIPCClient()
    let appServerClient = CodexAppServerClient(
      executableURL: URL(fileURLWithPath: "/usr/bin/false")
    )
    let model = CodexActivityModel(
      ipcClient: ipcClient,
      appServerClient: appServerClient,
      desktopAppController: WorktreeIdentityTestDesktopAppController(),
      settings: MenuBarSettings(userDefaults: defaults),
      userDefaults: defaults,
      startsTransportClients: false
    )

    for (threadID, cwd) in [
      ("main-thread", canonicalProjectID),
      ("worktree-thread", worktreeProjectID),
    ] {
      ipcClient.eventHandler?(
        .snapshot(
          conversationID: threadID,
          revision: 1,
          state: workingConversationState(threadID: threadID, cwd: cwd)
        )
      )
    }

    let mainThread = try XCTUnwrap(
      CodexThreadDescriptor(
        object: [
          "id": "main-thread",
          "name": "Medianoche",
          "cwd": canonicalProjectID,
        ],
        projectContext: .project(path: canonicalProjectID)
      )
    )
    let worktreeThread = try XCTUnwrap(
      CodexThreadDescriptor(
        object: [
          "id": "worktree-thread",
          "name": "Medianoche worktree",
          "cwd": worktreeProjectID,
        ],
        projectContext: .project(path: canonicalProjectID)
      )
    )
    appServerClient.eventHandler?(
      .threadsChanged(
        [mainThread, worktreeThread],
        projectPathAliases: [
          CodexProjectPathAlias(
            assignmentPath: worktreeProjectID,
            canonicalPath: canonicalProjectID
          ),
          CodexProjectPathAlias(
            assignmentPath: dormantWorktreeProjectID,
            canonicalPath: canonicalProjectID
          )
        ]
      )
    )

    XCTAssertEqual(model.tasks.count, 2)
    XCTAssertTrue(model.tasks.allSatisfy { $0.projectID == canonicalProjectID })
    XCTAssertTrue(model.tasks.allSatisfy { $0.projectColor == .orange })
    XCTAssertTrue(model.tasks.allSatisfy { $0.effectiveColor == .orange })
    XCTAssertTrue(model.tasks.allSatisfy { $0.projectVoice == .reed })
    XCTAssertTrue(model.tasks.allSatisfy { $0.effectiveVoice == .reed })

    let restoredColors = TaskColorPreferences.load(from: defaults)
    let restoredVoices = TaskVoicePreferences.load(from: defaults)
    XCTAssertEqual(restoredColors.projectColor(for: canonicalProjectID), .orange)
    XCTAssertEqual(restoredVoices.projectVoice(for: canonicalProjectID), .reed)
    XCTAssertNil(restoredColors.projectColor(for: worktreeProjectID))
    XCTAssertNil(restoredVoices.projectVoice(for: worktreeProjectID))
    XCTAssertNil(restoredColors.projectColor(for: dormantWorktreeProjectID))
    XCTAssertNil(restoredVoices.projectVoice(for: dormantWorktreeProjectID))
  }

  private func workingConversationState(threadID: String, cwd: String) -> JSONValue {
    .object([
      "id": .string(threadID),
      "title": .string(threadID),
      "cwd": .string(cwd),
      "threadRuntimeStatus": .object([
        "type": .string("active"),
        "activeFlags": .array([]),
      ]),
      "turnHistory": .object([
        "history": .object([
          "entitiesByKey": .object([
            "turn-1": .object([
              "turnStartedAtMs": .number(1_700_000_000_000),
              "status": .string("inProgress"),
              "items": .array([]),
            ])
          ])
        ])
      ]),
    ])
  }
}

@MainActor
private final class WorktreeIdentityTestDesktopAppController: CodexDesktopAppControlling {
  let state: CodexDesktopAppState = .running
  var stateDidChange: ((CodexDesktopAppState) -> Void)?

  func start() {}
  func stop() {}
  func openCodex() {}
}
