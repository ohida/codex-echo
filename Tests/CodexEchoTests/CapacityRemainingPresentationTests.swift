import CodexAppServer
import XCTest

@testable import CodexEcho

final class CapacityRemainingPresentationTests: XCTestCase {
  func testRoundedZeroIsQualifiedWithoutChangingTheSourceSnapshot() {
    let snapshot = CodexUsageSnapshot(usedPercent: 100)
    let presentation = CapacityRemainingPresentation(snapshot.remainingPercent!)

    XCTAssertEqual(presentation.percentText, "<1%")
    XCTAssertEqual(presentation.accessibilityValue, "less than 1 percent remaining")
    XCTAssertEqual(snapshot.usedPercent, 100)
    XCTAssertEqual(snapshot.remainingPercent, 0)
  }

  func testPositiveCapacityAndUnavailableCapacityKeepTheirMeaning() {
    for remainingPercent in [1, 10, 99, 100] {
      let presentation = CapacityRemainingPresentation(remainingPercent)
      XCTAssertEqual(presentation.percentText, "\(remainingPercent)%")
      XCTAssertEqual(
        presentation.accessibilityValue,
        "\(remainingPercent) percent remaining"
      )
    }
    XCTAssertEqual(
      CapacityMenuItemPresentation.make(remainingPercent: nil).title,
      "Codex Capacity"
    )
  }

  func testConfirmedExhaustionKeepsZeroWhileUsableOrUnknownCapacityIsQualified() {
    let exhausted = CapacityRemainingPresentation(0, ordinaryUsageAllowed: false)
    XCTAssertEqual(exhausted.percentText, "0%")
    XCTAssertEqual(exhausted.accessibilityValue, "0 percent remaining")
    for permission: Bool? in [true, nil] {
      let presentation = CapacityRemainingPresentation(0, ordinaryUsageAllowed: permission)
      XCTAssertEqual(presentation.percentText, "<1%")
      XCTAssertEqual(presentation.accessibilityValue, "less than 1 percent remaining")
    }
    XCTAssertEqual(
      CapacityRemainingPresentation(12, ordinaryUsageAllowed: false).percentText,
      "12%"
    )
  }
}
