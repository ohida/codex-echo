import Foundation
@testable import CodexAppServer
import XCTest

final class CodexDesktopProjectStateTests: XCTestCase {
  func testLocalProjectRootUnifiesMainAndWorktreeAssignments() throws {
    let snapshot = try XCTUnwrap(
      CodexDesktopProjectStateSnapshot(
        object: [
          "local-projects": [
            "project-1": [
              "id": "project-1",
              "name": "Medianoche",
              "rootPaths": ["/Users/example/Codes/medianoche"],
            ]
          ],
          "thread-project-assignments": [
            "main-thread": [
              "projectKind": "local",
              "projectId": "project-1",
              "cwd": "/Users/example/Codes/medianoche",
            ],
            "worktree-thread": [
              "projectKind": "local",
              "projectId": "project-1",
              "cwd": "/Users/example/.codex/worktrees/ff9f/medianoche",
            ],
            "dormant-worktree-thread": [
              "projectKind": "local",
              "projectId": "project-1",
              "cwd": "/Users/example/.codex/worktrees/aaaa/medianoche",
            ],
          ],
        ]
      )
    )

    let canonicalContext = CodexThreadProjectContext.project(
      path: "/Users/example/Codes/medianoche"
    )
    XCTAssertEqual(
      snapshot.projectContext(for: "main-thread"),
      canonicalContext
    )
    XCTAssertEqual(
      snapshot.projectContext(for: "worktree-thread"),
      canonicalContext
    )
    XCTAssertEqual(
      snapshot.projectPathAliases,
      [
        CodexProjectPathAlias(
          assignmentPath: "/Users/example/.codex/worktrees/aaaa/medianoche",
          canonicalPath: "/Users/example/Codes/medianoche"
        ),
        CodexProjectPathAlias(
          assignmentPath: "/Users/example/.codex/worktrees/ff9f/medianoche",
          canonicalPath: "/Users/example/Codes/medianoche"
        )
      ]
    )
  }

  func testExplicitLocalAssignmentWinsOverProjectlessAndStaleThreadCWD() throws {
    let threadID = "thread-moved-by-dnd"
    let snapshot = try XCTUnwrap(
      CodexDesktopProjectStateSnapshot(
        object: [
          "thread-project-assignments": [
            threadID: [
              "projectKind": "local",
              "projectId": "project-1",
              "path": "/Users/example/Codes/destination",
              "cwd": "/Users/example/Codes/destination",
              "pendingCoreUpdate": true,
            ]
          ],
          "projectless-thread-ids": [threadID],
        ]
      )
    )

    XCTAssertEqual(
      snapshot.projectContext(for: threadID),
      .project(path: "/Users/example/Codes/destination")
    )

    let descriptor = try XCTUnwrap(
      CodexThreadDescriptor(
        object: [
          "id": threadID,
          "name": "Moved task",
          "cwd": "/Users/example/Documents/Codex/generated-workspace",
        ],
        projectContext: snapshot.projectContext(for: threadID)
      )
    )
    XCTAssertEqual(descriptor.cwd, "/Users/example/Documents/Codex/generated-workspace")
    XCTAssertEqual(
      descriptor.projectContext,
      .project(path: "/Users/example/Codes/destination")
    )
  }

  func testProjectlessThreadIsAFirstClassContext() throws {
    let snapshot = try XCTUnwrap(
      CodexDesktopProjectStateSnapshot(
        object: ["projectless-thread-ids": ["one", "two"]]
      )
    )

    XCTAssertEqual(snapshot.projectContext(for: "one"), .noProject)
    XCTAssertEqual(snapshot.projectContext(for: "two"), .noProject)
    XCTAssertNil(snapshot.projectContext(for: "unknown"))
  }

  func testLocalAssignmentFallsBackFromAnEmptyPathToCWD() throws {
    let snapshot = try XCTUnwrap(
      CodexDesktopProjectStateSnapshot(
        object: [
          "thread-project-assignments": [
            "thread-1": [
              "projectKind": "local",
              "path": "   ",
              "cwd": "/tmp/project",
            ]
          ]
        ]
      )
    )

    XCTAssertEqual(
      snapshot.projectContext(for: "thread-1"),
      .project(path: "/tmp/project")
    )
  }

  func testReaderKeepsLastValidSnapshotAcrossMalformedOrMissingState() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let stateURL = temporaryDirectory.appendingPathComponent(".codex-global-state.json")
    try Data(#"{"projectless-thread-ids":["thread-1"]}"#.utf8).write(to: stateURL)
    let reader = CodexDesktopProjectStateReader(stateURL: stateURL)

    XCTAssertEqual(reader.snapshot().projectContext(for: "thread-1"), .noProject)

    try Data(#"{"projectless-thread-ids":42}"#.utf8).write(to: stateURL)
    XCTAssertEqual(reader.snapshot().projectContext(for: "thread-1"), .noProject)

    try FileManager.default.removeItem(at: stateURL)
    XCTAssertEqual(reader.snapshot().projectContext(for: "thread-1"), .noProject)
  }

  func testColdReaderUsesEmptySnapshotWhenGlobalStateIsMissing() {
    let stateURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent(".codex-global-state.json")
    let reader = CodexDesktopProjectStateReader(stateURL: stateURL)

    XCTAssertNil(reader.snapshot().projectContext(for: "thread-1"))
  }
}
