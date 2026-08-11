import Darwin
import Foundation
@testable import CodexEcho
import XCTest

final class ApplicationInstanceLockTests: XCTestCase {
  func testInstanceLockCreatesTheFileAndReleaseIsAutomatic() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directoryURL.appendingPathComponent("instance.lock")
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    var owner: ApplicationInstanceLock? = try XCTUnwrap(
      ApplicationInstanceLock.acquire(fileURL: fileURL)
    )
    XCTAssertNotNil(owner)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    owner = nil

    XCTAssertNotNil(try ApplicationInstanceLock.acquire(fileURL: fileURL))
  }

  func testInstanceLockDoesNotLeakIntoChildExecutables() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directoryURL.appendingPathComponent("instance.lock")
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let lock = try XCTUnwrap(
      ApplicationInstanceLock.acquire(fileURL: fileURL)
    )

    let descriptorFlags = fcntl(lock.fileDescriptor, F_GETFD)

    XCTAssertNotEqual(descriptorFlags, -1)
    XCTAssertEqual(descriptorFlags & FD_CLOEXEC, FD_CLOEXEC)
  }

  func testDuplicateLaunchCopyPointsToTheExistingMenuBarItem() {
    XCTAssertEqual(
      ApplicationInstanceLaunchCopy.alreadyRunningTitle,
      "Codex Echo is already running."
    )
    XCTAssertEqual(
      ApplicationInstanceLaunchCopy.alreadyRunningMessage,
      "Use the existing menu bar item."
    )
  }
}
