import Foundation
import XCTest

final class AppBundleContractTests: XCTestCase {
  func testSourcePlistMatchesTheLocalMenuBarAppContract() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let plistURL = repositoryRoot
      .appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent("Info.plist")
    let data = try Data(contentsOf: plistURL)
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String: Any]
    )

    XCTAssertEqual(plist["CFBundleExecutable"] as? String, "CodexEcho")
    XCTAssertEqual(
      plist["CFBundleIdentifier"] as? String,
      "app.ohida.codex-echo"
    )
    XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
    XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
    XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
    XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
    XCTAssertEqual(plist["LSMultipleInstancesProhibited"] as? Bool, true)
    XCTAssertEqual(plist["CodexEchoUpdatesEnabled"] as? Bool, false)
    XCTAssertNil(plist["SUFeedURL"])
    XCTAssertNil(plist["SUPublicEDKey"])
  }
}
