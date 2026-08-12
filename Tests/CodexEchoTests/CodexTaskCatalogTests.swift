import XCTest

@testable import CodexAppServer
@testable import CodexEcho

final class CodexTaskCatalogTests: XCTestCase {
  func testBootstrapAdmissionBecomesAuthoritativeAfterFirstReplacement() throws {
    var catalog = CodexTaskCatalog()

    XCTAssertTrue(catalog.admits("unknown"))
    XCTAssertNil(catalog.authoritativeIDs)
    XCTAssertNil(catalog.descriptor(for: "unknown"))

    let known = try descriptor(id: "known", title: "Known")
    XCTAssertEqual(catalog.replace(with: [known]), ["known"])

    XCTAssertEqual(catalog.authoritativeIDs, ["known"])
    XCTAssertTrue(catalog.admits("known"))
    XCTAssertFalse(catalog.admits("unknown"))
    XCTAssertEqual(catalog.descriptor(for: "known"), known)
  }

  func testReplacementDropsPreviousDescriptorsAndUsesLatestValues() throws {
    var catalog = CodexTaskCatalog()
    let old = try descriptor(id: "old", title: "Old")
    let original = try descriptor(id: "current", title: "Original")
    let updated = try descriptor(id: "current", title: "Updated")

    _ = catalog.replace(with: [old, original])
    XCTAssertEqual(catalog.replace(with: [updated]), ["current"])

    XCTAssertNil(catalog.descriptor(for: "old"))
    XCTAssertEqual(catalog.descriptor(for: "current")?.title, "Updated")
    XCTAssertFalse(catalog.admits("old"))
  }

  func testRemovalKeepsAnEmptyCatalogAuthoritative() throws {
    var catalog = CodexTaskCatalog()
    _ = catalog.replace(with: [try descriptor(id: "known", title: "Known")])

    catalog.remove("known")

    XCTAssertEqual(catalog.authoritativeIDs, [])
    XCTAssertFalse(catalog.admits("known"))
    XCTAssertFalse(catalog.admits("another"))
  }

  func testReplacementKeepsTheFirstDescriptorForADuplicateExternalID() throws {
    var catalog = CodexTaskCatalog()
    let newest = try descriptor(id: "duplicate", title: "Newest")
    let older = try descriptor(id: "duplicate", title: "Older")

    XCTAssertEqual(catalog.replace(with: [newest, older]), ["duplicate"])

    XCTAssertEqual(catalog.authoritativeIDs, ["duplicate"])
    XCTAssertEqual(catalog.descriptor(for: "duplicate"), newest)
    XCTAssertTrue(catalog.admits("duplicate"))
  }

  private func descriptor(id: String, title: String) throws -> CodexThreadDescriptor {
    try XCTUnwrap(
      CodexThreadDescriptor(
        object: [
          "id": id,
          "name": title,
          "cwd": "/tmp/\(id)",
        ]
      )
    )
  }
}
