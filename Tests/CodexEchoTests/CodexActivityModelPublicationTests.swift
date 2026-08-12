import Combine
import XCTest

@testable import CodexEcho
@testable import CodexIPC
@testable import CodexAppServer

final class CodexActivityModelPublicationTests: XCTestCase {
  @MainActor
  func testEquivalentIPCPatchDoesNotRepublishTaskPresentation() throws {
    let suiteName = "CodexActivityModelPublicationTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let ipcClient = CodexIPCClient()
    let model = CodexActivityModel(
      ipcClient: ipcClient,
      appServerClient: CodexAppServerClient(
        executableURL: URL(fileURLWithPath: "/usr/bin/false")
      ),
      desktopAppController: PublicationTestDesktopAppController(),
      settings: MenuBarSettings(userDefaults: defaults),
      userDefaults: defaults
    )
    var taskPublications: [[TaskPresentation]] = []
    var crewTaskPublications: [[TaskPresentation]] = []
    var cancellables = Set<AnyCancellable>()
    model.$tasks.dropFirst()
      .sink { taskPublications.append($0) }
      .store(in: &cancellables)
    model.$crewTasks.dropFirst()
      .sink { crewTaskPublications.append($0) }
      .store(in: &cancellables)

    ipcClient.eventHandler?(
      .snapshot(
        conversationID: "thread-1",
        revision: 1,
        state: workingConversationState(title: "Initial title")
      )
    )
    XCTAssertEqual(model.tasks.map(\.title), ["Initial title"])
    XCTAssertEqual(model.crewTasks.map(\.title), ["Initial title"])
    XCTAssertEqual(taskPublications.count, 1)
    XCTAssertEqual(crewTaskPublications.count, 1)

    taskPublications.removeAll()
    crewTaskPublications.removeAll()
    ipcClient.eventHandler?(
      .patches(
        conversationID: "thread-1",
        baseRevision: 1,
        revision: 2,
        patches: [
          JSONPatch(
            operation: .replace,
            path: [
              .key("turnHistory"),
              .key("history"),
              .key("entitiesByKey"),
              .key("turn-1"),
              .key("items"),
              .index(0),
              .key("summary"),
            ],
            value: .string("Streaming details changed")
          )
        ]
      )
    )

    XCTAssertTrue(taskPublications.isEmpty)
    XCTAssertTrue(crewTaskPublications.isEmpty)

    ipcClient.eventHandler?(
      .patches(
        conversationID: "thread-1",
        baseRevision: 2,
        revision: 3,
        patches: [
          JSONPatch(
            operation: .replace,
            path: [.key("title")],
            value: .string("Updated title")
          )
        ]
      )
    )

    XCTAssertEqual(model.tasks.map(\.title), ["Updated title"])
    XCTAssertEqual(model.crewTasks.map(\.title), ["Updated title"])
    XCTAssertEqual(taskPublications.count, 1)
    XCTAssertEqual(crewTaskPublications.count, 1)
  }

  @MainActor
  func testAuthoritativeCatalogPrunesAndRejectsUnknownSnapshots() throws {
    let suiteName = "CodexActivityModelPublicationTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let ipcClient = CodexIPCClient()
    let appServerClient = CodexAppServerClient(
      executableURL: URL(fileURLWithPath: "/usr/bin/false")
    )
    let model = CodexActivityModel(
      ipcClient: ipcClient,
      appServerClient: appServerClient,
      desktopAppController: PublicationTestDesktopAppController(),
      settings: MenuBarSettings(userDefaults: defaults),
      userDefaults: defaults
    )

    ipcClient.eventHandler?(
      .snapshot(
        conversationID: "bootstrap",
        revision: 1,
        state: workingConversationState(id: "bootstrap", title: "Bootstrap")
      )
    )
    XCTAssertEqual(model.tasks.map(\.id), ["bootstrap"])

    let known = try XCTUnwrap(
      CodexThreadDescriptor(
        object: [
          "id": "known",
          "name": "Known",
        ]
      )
    )
    appServerClient.eventHandler?(
      .threadsChanged([known], projectPathAliases: [])
    )
    XCTAssertTrue(model.tasks.isEmpty)

    ipcClient.eventHandler?(
      .snapshot(
        conversationID: "unknown",
        revision: 1,
        state: workingConversationState(id: "unknown", title: "Unknown")
      )
    )
    XCTAssertTrue(model.tasks.isEmpty)

    ipcClient.eventHandler?(
      .snapshot(
        conversationID: "known",
        revision: 1,
        state: workingConversationState(id: "known", title: "Known")
      )
    )
    XCTAssertEqual(model.tasks.map(\.id), ["known"])
  }

  @MainActor
  func testUnavailableCatalogDegradesUntilAnAuthoritativeCatalogRecovers() throws {
    let suiteName = "CodexActivityModelPublicationTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let ipcClient = CodexIPCClient()
    let appServerClient = CodexAppServerClient(
      executableURL: URL(fileURLWithPath: "/usr/bin/false")
    )
    let model = CodexActivityModel(
      ipcClient: ipcClient,
      appServerClient: appServerClient,
      desktopAppController: PublicationTestDesktopAppController(),
      settings: MenuBarSettings(userDefaults: defaults),
      userDefaults: defaults,
      startsTransportClients: false
    )
    let known = try XCTUnwrap(
      CodexThreadDescriptor(
        object: [
          "id": "known",
          "name": "Known",
        ]
      )
    )

    ipcClient.eventHandler?(.connectionStateChanged(.connected))
    appServerClient.eventHandler?(.connectionStateChanged(.running))
    appServerClient.eventHandler?(.threadsChanged([known]))
    XCTAssertEqual(model.connectionHealth, .live)
    XCTAssertEqual(model.taskCatalogSnapshot?.taskIDs, ["known"])

    appServerClient.eventHandler?(.taskCatalogUnavailable)
    XCTAssertEqual(model.connectionHealth, .degraded(.taskCatalogUnavailable))
    XCTAssertNil(model.taskCatalogSnapshot)

    appServerClient.eventHandler?(.threadsChanged([known]))
    XCTAssertEqual(model.connectionHealth, .live)
    XCTAssertEqual(model.taskCatalogSnapshot?.taskIDs, ["known"])
  }

  private func workingConversationState(
    id: String = "thread-1",
    title: String
  ) -> JSONValue {
    .object([
      "id": .string(id),
      "title": .string(title),
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
              "items": .array([
                .object([
                  "type": .string("reasoning"),
                  "summary": .string("Initial streaming details"),
                ])
              ]),
            ])
          ])
        ])
      ]),
    ])
  }
}

@MainActor
private final class PublicationTestDesktopAppController: CodexDesktopAppControlling {
  let state: CodexDesktopAppState = .running
  var stateDidChange: ((CodexDesktopAppState) -> Void)?

  func start() {}
  func stop() {}
  func openCodex() {}
}
