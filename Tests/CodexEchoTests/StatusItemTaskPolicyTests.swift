import AppKit
import SwiftUI
import XCTest

@testable import CodexIPC
@testable import CodexEcho

final class StatusItemTaskPolicyTests: XCTestCase {
  @MainActor
  func testSingleDigitCapacityBadgeUsesContentWidthAndRingSpacing() throws {
    let singleDigitWidth = WorkerCrewLayout.summaryWidth(
      overflowCount: 0,
      capacityRemainingPercent: 9
    )
    XCTAssertGreaterThanOrEqual(singleDigitWidth, 24)
    XCTAssertLessThanOrEqual(singleDigitWidth, 27)
    let summaryRange = try XCTUnwrap(
      WorkerCrewLayout.summaryRange(
        displayedCrewCount: 1,
        overflowCount: 0,
        capacityRemainingPercent: 9
      )
    )
    XCTAssertEqual(
      summaryRange.lowerBound - WorkerCrewLayout.taskGroupWidth(for: 1),
      WorkerCrewLayout.taskSpacing
    )

    let view = NSHostingView(
      rootView: CrewSummaryBadge(
        overflowCount: 0,
        unreadCompletionCount: 0,
        attentionCount: 0,
        capacityRemainingPercent: 9,
        phase: 0,
        reduceMotion: true
      )
      .environment(\.colorScheme, .light)
    )
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.fittingSize.width, singleDigitWidth, accuracy: 0.5)
  }

  func testApplicationMenuFooterUsesNativeAboutDiagnosticsAlternateAndUpdaterOrdering() {
    XCTAssertEqual(
      AppMenuFooterPolicy.elements(
        canCheckForUpdates: true,
        canOpenSettings: true
      ),
      [
        .item(
          .init(
            title: "About Codex Echo",
            action: .about,
            isEnabled: true
          )
        ),
        .item(
          .init(
            title: "Show Diagnostics…",
            action: .showDiagnostics,
            systemSymbolName: "stethoscope",
            isAlternate: true,
            isEnabled: true
          )
        ),
        .item(
          .init(
            title: "Check for Updates…",
            action: .checkForUpdates,
            isEnabled: true
          )
        ),
        .separator,
        .item(
          .init(
            title: "Settings…",
            action: .settings,
            keyEquivalent: ",",
            isEnabled: true
          )
        ),
        .item(
          .init(
            title: "Quit Codex Echo",
            action: .quit,
            keyEquivalent: "q",
            isEnabled: true
          )
        ),
      ]
    )
  }

  func testFeedbackDestinationIsThePublishedHTTPSGoogleForm() {
    XCTAssertEqual(
      AppPresentationCopy.feedbackFormURL.absoluteString,
      "https://docs.google.com/forms/d/e/1FAIpQLSdCoMOXOOVO86CY6wVNDVP1vMmCudkLGQbxxAVAqvnBiny5Jw/viewform"
    )
    XCTAssertEqual(AppPresentationCopy.feedbackFormURL.scheme, "https")
    XCTAssertEqual(AppPresentationCopy.feedbackFormURL.host, "docs.google.com")
  }

  func testAboutPanelCreditsExposeTheFeedbackDestinationAsACenteredLink() throws {
    let credits = try XCTUnwrap(
      AppPresentationCopy.aboutPanelOptions[.credits] as? NSAttributedString
    )

    XCTAssertEqual(credits.string, "Send Feedback…")
    let attributes = credits.attributes(at: 0, effectiveRange: nil)
    XCTAssertEqual(
      attributes[.link] as? URL,
      AppPresentationCopy.feedbackFormURL
    )
    XCTAssertEqual(
      (attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment,
      .center
    )
    let font = try XCTUnwrap(attributes[.font] as? NSFont)
    XCTAssertEqual(font.pointSize, NSFont.smallSystemFontSize, accuracy: 0.001)
    XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .labelColor)
    XCTAssertEqual(
      attributes[.underlineStyle] as? Int,
      NSUnderlineStyle.single.rawValue
    )
  }

  @MainActor
  func testAboutPanelFeedbackLinkStyleOverridesOnlyTheFeedbackTextView() throws {
    let rootView = NSView()
    let unrelatedTextView = NSTextView()
    unrelatedTextView.string = "Unrelated"
    let feedbackTextView = NSTextView()
    feedbackTextView.textStorage?.setAttributedString(
      try XCTUnwrap(
        AppPresentationCopy.aboutPanelOptions[.credits] as? NSAttributedString
      )
    )
    rootView.addSubview(unrelatedTextView)
    rootView.addSubview(feedbackTextView)

    XCTAssertTrue(
      StatusItemController.applyAboutPanelFeedbackLinkStyle(in: rootView)
    )
    XCTAssertEqual(
      feedbackTextView.linkTextAttributes?[.foregroundColor] as? NSColor,
      .labelColor
    )
    XCTAssertEqual(
      feedbackTextView.linkTextAttributes?[.underlineStyle] as? Int,
      NSUnderlineStyle.single.rawValue
    )
    XCTAssertTrue(
      (feedbackTextView.linkTextAttributes?[.cursor] as? NSCursor)?
        .isEqual(NSCursor.pointingHand) == true
    )
    XCTAssertNotEqual(
      unrelatedTextView.linkTextAttributes?[.foregroundColor] as? NSColor,
      .labelColor
    )
  }

  func testCheckForUpdatesEnabledStateExactlyMatchesUpdaterCapability() {
    let enabled = AppMenuFooterPolicy.elements(
      canCheckForUpdates: true,
      canOpenSettings: false
    )
    let disabled = AppMenuFooterPolicy.elements(
      canCheckForUpdates: false,
      canOpenSettings: false
    )

    XCTAssertEqual(
      enabled.item(for: .checkForUpdates)?.isEnabled,
      true
    )
    XCTAssertEqual(
      disabled.item(for: .checkForUpdates)?.isEnabled,
      false
    )
    XCTAssertEqual(enabled.item(for: .settings)?.isEnabled, false)
    XCTAssertEqual(disabled.item(for: .settings)?.isEnabled, false)
  }

  func testDiagnosticsIsAnOptionAlternateInsteadOfAnotherVisibleFooterRow() {
    let diagnostics = AppMenuFooterPolicy.elements(
      canCheckForUpdates: true,
      canOpenSettings: true
    ).item(for: .showDiagnostics)

    XCTAssertEqual(diagnostics?.title, "Show Diagnostics…")
    XCTAssertEqual(diagnostics?.systemSymbolName, "stethoscope")
    XCTAssertEqual(diagnostics?.isAlternate, true)
    XCTAssertEqual(diagnostics?.keyEquivalent, "")
    XCTAssertEqual(diagnostics?.isEnabled, true)
  }

  @MainActor
  func testDiagnosticsDescriptorConfiguresANativeOptionAlternateItem() throws {
    let descriptor = try XCTUnwrap(
      AppMenuFooterPolicy.elements(
        canCheckForUpdates: true,
        canOpenSettings: true
      ).item(for: .showDiagnostics)
    )
    let menuItem = NSMenuItem(
      title: descriptor.title,
      action: nil,
      keyEquivalent: descriptor.keyEquivalent
    )

    StatusItemController.configureApplicationMenuItem(
      menuItem,
      from: descriptor
    )

    XCTAssertTrue(menuItem.isAlternate)
    XCTAssertEqual(menuItem.keyEquivalentModifierMask, [.option])
    XCTAssertEqual(menuItem.image?.accessibilityDescription, "Show Diagnostics…")
    XCTAssertTrue(menuItem.isEnabled)
  }

  func testCrewPeekReservesSpaceForReadableSemanticTextStyles() {
    XCTAssertEqual(CrewPeekMetrics.size, NSSize(width: 288, height: 72))
  }

  func testSummaryHoverTargetCoversOverflowCapacityAndTheirCombination() throws {
    let capacityRange = try XCTUnwrap(
      WorkerCrewLayout.summaryRange(
        displayedCrewCount: 0,
        overflowCount: 0,
        capacityRemainingPercent: 9
      )
    )
    XCTAssertEqual(
      StatusItemHoverPolicy.target(
        at: capacityRange.lowerBound,
        displayedCrewCount: 0,
        overflowCount: 0,
        capacityRemainingPercent: 9
      ),
      .summary
    )
    XCTAssertEqual(
      StatusItemHoverPolicy.target(
        at: capacityRange.upperBound,
        displayedCrewCount: 0,
        overflowCount: 0,
        capacityRemainingPercent: 9
      ),
      .summary
    )
    XCTAssertNil(
      StatusItemHoverPolicy.target(
        at: capacityRange.upperBound + 0.1,
        displayedCrewCount: 0,
        overflowCount: 0,
        capacityRemainingPercent: 9
      )
    )
    let overflowRange = try XCTUnwrap(
      WorkerCrewLayout.summaryRange(
        displayedCrewCount: 0,
        overflowCount: 3,
        capacityRemainingPercent: nil
      )
    )
    XCTAssertEqual(
      StatusItemHoverPolicy.target(
        at: overflowRange.lowerBound,
        displayedCrewCount: 0,
        overflowCount: 3,
        capacityRemainingPercent: nil
      ),
      .summary
    )
    let combinedRange = try XCTUnwrap(
      WorkerCrewLayout.summaryRange(
        displayedCrewCount: 0,
        overflowCount: 3,
        capacityRemainingPercent: 9
      )
    )
    XCTAssertEqual(
      StatusItemHoverPolicy.target(
        at: combinedRange.upperBound,
        displayedCrewCount: 0,
        overflowCount: 3,
        capacityRemainingPercent: 9
      ),
      .summary
    )
    XCTAssertEqual(
      StatusItemHoverPolicy.target(
        at: 0,
        displayedCrewCount: 1,
        overflowCount: 1,
        capacityRemainingPercent: 9
      ),
      .task(0)
    )
    XCTAssertNil(
      StatusItemHoverPolicy.target(
        at: 22.1,
        displayedCrewCount: 1,
        overflowCount: 1,
        capacityRemainingPercent: 9
      )
    )
  }

  func testSummaryPeekCombinesOverflowSignalsAndCapacityDetails() throws {
    let resetDescription = "Resets Jul 31, 2026 at 19:49"
    let combined = try XCTUnwrap(
      CrewSummaryPeekPresentation.make(
        overflowCount: 3,
        attentionCount: 1,
        unreadCompletionCount: 1,
        capacityRemainingPercent: 43,
        resetDescription: resetDescription
      )
    )

    XCTAssertEqual(combined.title, "3 More Tasks")
    XCTAssertEqual(
      combined.detailLines,
      [
        "1 needs attention · 1 unread",
        "Codex Capacity · 43% remaining",
        resetDescription,
      ]
    )
    XCTAssertEqual(combined.systemImageName, "ellipsis.circle")

    let capacityOnly = try XCTUnwrap(
      CrewSummaryPeekPresentation.make(
        overflowCount: 0,
        attentionCount: 0,
        unreadCompletionCount: 0,
        capacityRemainingPercent: 43,
        resetDescription: resetDescription
      )
    )
    XCTAssertEqual(capacityOnly.title, "Codex Capacity")
    XCTAssertEqual(
      capacityOnly.detailLines,
      ["43% remaining", resetDescription]
    )
    XCTAssertEqual(capacityOnly.systemImageName, "chart.pie")

    let overflowOnly = try XCTUnwrap(
      CrewSummaryPeekPresentation.make(
        overflowCount: 2,
        attentionCount: 0,
        unreadCompletionCount: 0,
        capacityRemainingPercent: nil,
        resetDescription: nil
      )
    )
    XCTAssertEqual(overflowOnly.title, "2 More Tasks")
    XCTAssertEqual(overflowOnly.detailLines, [])
    XCTAssertNil(
      CrewSummaryPeekPresentation.make(
        overflowCount: 0,
        attentionCount: 0,
        unreadCompletionCount: 0,
        capacityRemainingPercent: nil,
        resetDescription: nil
      )
    )
  }

  func testTaskMenuTextPolicyCapsLongTextByRenderedWidth() {
    let shortTitle = "タスク diff 表示を追加"
    XCTAssertEqual(
      TaskMenuTextPolicy.displayedTitle(shortTitle),
      shortTitle
    )

    let longTitle =
      "カナ対応、アカウント承認、について、ドコピへの質問項目リストを作成してみて。"
      + "要点を端的に突く感じで。優先度順に最大5個くらいずつ"
    let displayedTitle = TaskMenuTextPolicy.displayedTitle(longTitle)
    XCTAssertTrue(displayedTitle.hasSuffix("…"))
    XCTAssertTrue(longTitle.hasPrefix(String(displayedTitle.dropLast())))
    XCTAssertLessThan(
      TaskMenuTextPolicy.measuredWidth(
        displayedTitle,
        font: TaskMenuTextPolicy.titleFont
      ),
      TaskMenuTextPolicy.maximumTextWidth + 0.01
    )

    let menuItem = NSMenuItem(title: "Stale", action: nil, keyEquivalent: "")
    menuItem.toolTip = "Stale tooltip"
    TaskMenuTextPolicy.configureTaskTitle(longTitle, on: menuItem)
    XCTAssertEqual(menuItem.title, displayedTitle)
    XCTAssertNil(menuItem.toolTip)
    XCTAssertEqual(menuItem.accessibilityLabel(), longTitle)

    let longSubtitle =
      "Completed in 1 min · "
      + String(repeating: "knowledge-kernel-", count: 8)
    let displayedSubtitle = TaskMenuTextPolicy.displayedSubtitle(longSubtitle)
    XCTAssertTrue(displayedSubtitle.hasSuffix("…"))
    XCTAssertLessThan(
      TaskMenuTextPolicy.measuredWidth(
        displayedSubtitle,
        font: TaskMenuTextPolicy.subtitleFont
      ),
      TaskMenuTextPolicy.maximumTextWidth + 0.01
    )
  }

  func testReadStateBroadcastUsesCodexVersionTwoPayload() {
    let message: [String: Any] = [
      "method": "thread-read-state-changed",
      "version": 2,
      "params": [
        "hostId": "local",
        "conversationId": "thread-1",
        "hasUnreadTurn": false,
      ],
    ]

    let change = CodexIPCReadStateChange(
      broadcast: message,
      subscribedConversationIDs: ["thread-1"]
    )
    XCTAssertEqual(change?.conversationID, "thread-1")
    XCTAssertEqual(change?.hasUnreadTurn, false)

    var oldVersionMessage = message
    oldVersionMessage["version"] = 1
    XCTAssertNil(
      CodexIPCReadStateChange(
        broadcast: oldVersionMessage,
        subscribedConversationIDs: ["thread-1"]
      )
    )
    XCTAssertNil(
      CodexIPCReadStateChange(
        broadcast: message,
        subscribedConversationIDs: ["another-thread"]
      )
    )
  }

  func testThreadCatalogBroadcastsUseVerifiedVersionsAndLocalHost() {
    let archiveMessage: [String: Any] = [
      "method": "thread-archived",
      "version": 2,
      "params": [
        "hostId": "local",
        "conversationId": "thread-1",
        "cwd": "/tmp/project",
      ],
    ]
    let unarchiveMessage: [String: Any] = [
      "method": "thread-unarchived",
      "version": 1,
      "params": [
        "hostId": "local",
        "conversationId": "thread-1",
      ],
    ]

    XCTAssertEqual(
      CodexIPCThreadCatalogChange(broadcast: archiveMessage),
      .archived(conversationID: "thread-1")
    )
    XCTAssertEqual(
      CodexIPCThreadCatalogChange(broadcast: unarchiveMessage),
      .unarchived(conversationID: "thread-1")
    )

    var oldArchiveMessage = archiveMessage
    oldArchiveMessage["version"] = 1
    XCTAssertNil(CodexIPCThreadCatalogChange(broadcast: oldArchiveMessage))

    var remoteUnarchiveMessage = unarchiveMessage
    remoteUnarchiveMessage["params"] = [
      "hostId": "remote",
      "conversationId": "thread-1",
    ]
    XCTAssertNil(CodexIPCThreadCatalogChange(broadcast: remoteUnarchiveMessage))
  }

  func testHiddenRingRestoresOnlyWhenNewActiveStateBegins() {
    XCTAssertTrue(
      CrewRingVisibilityPolicy.shouldRestoreHiddenRing(from: .ready, to: .working)
    )
    XCTAssertTrue(
      CrewRingVisibilityPolicy.shouldRestoreHiddenRing(from: .working, to: .needsApproval)
    )
    XCTAssertTrue(
      CrewRingVisibilityPolicy.shouldRestoreHiddenRing(from: .ready, to: .needsInput)
    )
    XCTAssertTrue(
      CrewRingVisibilityPolicy.shouldRestoreHiddenRing(from: .ready, to: .blocked)
    )
    XCTAssertFalse(
      CrewRingVisibilityPolicy.shouldRestoreHiddenRing(from: .working, to: .working)
    )
    XCTAssertFalse(
      CrewRingVisibilityPolicy.shouldRestoreHiddenRing(from: .working, to: .ready)
    )
    XCTAssertFalse(
      CrewRingVisibilityPolicy.shouldRestoreHiddenRing(from: .ready, to: .idle)
    )
  }

  func testCompletedTaskAutoHideRequiresReadExpiredCompletion() {
    let now = Date(timeIntervalSince1970: 10_000)
    let expired = TaskPresentation(
      id: "expired",
      title: "expired",
      project: nil,
      state: .ready,
      isUnread: false,
      activeSubagentCount: 0,
      updatedAt: now.addingTimeInterval(-1_000),
      completedAt: now.addingTimeInterval(-901),
      completedDuration: 60
    )

    XCTAssertTrue(
      CompletedTaskAutoHidePolicy.shouldHide(
        expired,
        isEnabled: true,
        delay: .fifteenMinutes,
        now: now
      )
    )
    XCTAssertFalse(
      CompletedTaskAutoHidePolicy.shouldHide(
        TaskPresentation(
          id: "unread",
          title: "unread",
          project: nil,
          state: .ready,
          isUnread: true,
          activeSubagentCount: 0,
          updatedAt: now.addingTimeInterval(-1_000),
          completedAt: now.addingTimeInterval(-901),
          completedDuration: 60
        ),
        isEnabled: true,
        delay: .fifteenMinutes,
        now: now
      )
    )
    XCTAssertFalse(
      CompletedTaskAutoHidePolicy.shouldHide(
        expired,
        isEnabled: false,
        delay: .fifteenMinutes,
        now: now
      )
    )
    XCTAssertFalse(
      CompletedTaskAutoHidePolicy.shouldHide(
        TaskPresentation(
          id: "working",
          title: "working",
          project: nil,
          state: .working,
          activeSubagentCount: 0,
          updatedAt: now,
          completedAt: now.addingTimeInterval(-901),
          completedDuration: 60
        ),
        isEnabled: true,
        delay: .fifteenMinutes,
        now: now
      )
    )
  }

  func testCompletedTaskAutoHideSchedulesOnlyTheNextReadCompletion() {
    let now = Date(timeIntervalSince1970: 10_000)
    func completed(
      id: String,
      isUnread: Bool = false,
      after interval: TimeInterval
    ) -> TaskPresentation {
      TaskPresentation(
        id: id,
        title: id,
        project: nil,
        state: .ready,
        isUnread: isUnread,
        activeSubagentCount: 0,
        updatedAt: now,
        completedAt: now.addingTimeInterval(interval - 900),
        completedDuration: 60
      )
    }

    XCTAssertEqual(
      CompletedTaskAutoHidePolicy.nextExpiration(
        among: [
          completed(id: "later", after: 30),
          completed(id: "next", after: 10),
          completed(id: "unread", isUnread: true, after: 5),
        ],
        isEnabled: true,
        delay: .fifteenMinutes,
        now: now
      ),
      now.addingTimeInterval(10)
    )
    XCTAssertNil(
      CompletedTaskAutoHidePolicy.nextExpiration(
        among: [completed(id: "next", after: 10)],
        isEnabled: false,
        delay: .fifteenMinutes,
        now: now
      )
    )
  }

  func testCrewRingOrderMovesVisibleTaskWithoutReorderingOverflow() {
    XCTAssertEqual(
      CrewRingOrderPolicy.moving(
        taskID: "approval",
        toVisibleIndex: 2,
        visibleTaskIDs: ["one", "two", "three", "approval"],
        displayedTaskIDs: ["one", "two", "three", "four", "approval", "five"],
        preferredTaskIDs: ["hidden", "one", "two", "three", "four", "approval", "five"]
      ),
      ["hidden", "one", "two", "approval", "three", "four", "five"]
    )
  }

  func testCrewRingOrderAppendsNewTasksAndKeepsHiddenPreferences() {
    XCTAssertEqual(
      CrewRingOrderPolicy.appendingMissing(
        taskIDs: ["one", "two", "new"],
        to: ["hidden", "two", "one"]
      ),
      ["hidden", "two", "one", "new"]
    )
  }

  func testRestoredHiddenTaskReturnsAtTheEndWithoutDisplacingRememberedSlots() {
    XCTAssertEqual(
      CrewRingOrderPolicy.restoringAtEnd(
        taskID: "hidden",
        preferredTaskIDs: ["one", "hidden", "two", "three"]
      ),
      ["one", "two", "three", "hidden"]
    )
  }

  func testCrewRingOrderPersistsAcrossModelRestarts() {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Unable to create isolated user defaults")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    CrewRingOrderPersistence.save(
      ["three", "one", "two"],
      to: defaults,
      key: "crewOrder"
    )

    XCTAssertEqual(
      CrewRingOrderPersistence.load(from: defaults, key: "crewOrder"),
      ["three", "one", "two"]
    )
  }

  func testCrewRingOrderRejectsNoOpAndOutOfRangeMoves() {
    let visible = ["one", "two", "three"]
    let preferred = ["one", "two", "three", "overflow"]

    XCTAssertNil(
      CrewRingOrderPolicy.moving(
        taskID: "one",
        toVisibleIndex: 0,
        visibleTaskIDs: visible,
        displayedTaskIDs: preferred,
        preferredTaskIDs: preferred
      )
    )
    XCTAssertNil(
      CrewRingOrderPolicy.moving(
        taskID: "missing",
        toVisibleIndex: 1,
        visibleTaskIDs: visible,
        displayedTaskIDs: preferred,
        preferredTaskIDs: preferred
      )
    )
    XCTAssertNil(
      CrewRingOrderPolicy.moving(
        taskID: "two",
        toVisibleIndex: 4,
        visibleTaskIDs: visible,
        displayedTaskIDs: preferred,
        preferredTaskIDs: preferred
      )
    )
  }

  func testCrewRingOrderAddsOverflowTaskAfterTheVisiblePrefix() {
    XCTAssertEqual(
      CrewRingOrderPolicy.addingToVisibleEnd(
        taskID: "six",
        visibleLimit: 4,
        displayedTaskIDs: ["one", "two", "three", "four", "five", "six"],
        preferredTaskIDs: ["hidden", "one", "two", "three", "four", "five", "six"]
      ),
      ["hidden", "one", "two", "three", "four", "six", "five"]
    )
    XCTAssertNil(
      CrewRingOrderPolicy.addingToVisibleEnd(
        taskID: "two",
        visibleLimit: 4,
        displayedTaskIDs: ["one", "two", "three", "four", "five"],
        preferredTaskIDs: ["one", "two", "three", "four", "five"]
      )
    )
  }

  func testCrewRingOrderAddsTheFirstRingFromAZeroVisibleLimit() {
    XCTAssertEqual(
      CrewRingOrderPolicy.addingToVisibleEnd(
        taskID: "two",
        visibleLimit: 0,
        displayedTaskIDs: ["one", "two", "three"],
        preferredTaskIDs: ["one", "two", "three"]
      ),
      ["two", "one", "three"]
    )
  }

  func testCrewRingOrderReplacesTheLastVisibleTaskWithAnOverflowTask() {
    XCTAssertEqual(
      CrewRingOrderPolicy.replacingVisibleEnd(
        taskID: "five",
        visibleLimit: 4,
        displayedTaskIDs: ["one", "two", "three", "four", "five", "six"],
        preferredTaskIDs: ["hidden", "one", "two", "three", "four", "five", "six"]
      ),
      ["hidden", "one", "two", "three", "five", "four", "six"]
    )
    XCTAssertNil(
      CrewRingOrderPolicy.replacingVisibleEnd(
        taskID: "two",
        visibleLimit: 4,
        displayedTaskIDs: ["one", "two", "three", "four", "five"],
        preferredTaskIDs: ["one", "two", "three", "four", "five"]
      )
    )
    XCTAssertNil(
      CrewRingOrderPolicy.replacingVisibleEnd(
        taskID: "one",
        visibleLimit: 0,
        displayedTaskIDs: ["one", "two"],
        preferredTaskIDs: ["one", "two"]
      )
    )
  }

  func testRingMenuKeepsOnlyTheDirectHideAction() {
    XCTAssertEqual(CrewRingMenuPolicy.actions(forStatusBarTaskCount: 0), [])
    XCTAssertEqual(
      CrewRingMenuPolicy.actions(forStatusBarTaskCount: 1),
      [.hide]
    )
    XCTAssertEqual(
      CrewRingMenuPolicy.actions(forStatusBarTaskCount: 2),
      [.hide]
    )
  }

  func testTaskCustomizationMenuCollapsesScopeRowsIntoColorAndVoice() {
    XCTAssertEqual(
      TaskCustomizationMenuPolicy.elements(speaksAnnouncements: true),
      [.color, .voice]
    )
    XCTAssertEqual(
      TaskCustomizationMenuPolicy.elements(speaksAnnouncements: false),
      [.color]
    )
    XCTAssertEqual(
      TaskCustomizationMenuPolicy.scopes(hasParentScope: true),
      [.project, .task]
    )
    XCTAssertEqual(
      TaskCustomizationMenuPolicy.scopes(hasParentScope: false),
      [.task]
    )
    XCTAssertEqual(
      TaskCustomizationInheritancePolicy.colorTitle(
        for: .project("/tmp/project")
      ),
      "Use Project Color"
    )
    XCTAssertEqual(
      TaskCustomizationInheritancePolicy.colorTitle(for: .noProject),
      "Use No Project Color"
    )
    XCTAssertEqual(
      TaskCustomizationInheritancePolicy.voiceTitle(for: .noProject),
      "Use No Project Voice"
    )
    XCTAssertNil(TaskCustomizationInheritancePolicy.colorTitle(for: nil))
  }

  func testCrewRingDragActivatesOnlyAfterPointerLeavesClickSlop() {
    XCTAssertFalse(
      CrewRingDragActivation.shouldStart(
        translation: CGSize(width: 3, height: 0),
        inputPhase: .dragged
      )
    )
    XCTAssertFalse(
      CrewRingDragActivation.shouldStart(
        translation: CGSize(width: 2, height: 2),
        inputPhase: .dragged
      )
    )
    XCTAssertFalse(
      CrewRingDragActivation.shouldStart(
        translation: CGSize(width: 3, height: 30),
        inputPhase: .dragged
      )
    )
    XCTAssertTrue(
      CrewRingDragActivation.shouldStart(
        translation: CGSize(width: 4, height: 0),
        inputPhase: .dragged
      )
    )
  }

  func testCrewRingDragNeverActivatesFromMouseRelease() {
    XCTAssertFalse(
      CrewRingDragActivation.shouldStart(
        translation: CGSize(width: 4, height: 0),
        inputPhase: .released
      )
    )
    XCTAssertFalse(
      CrewRingDragActivation.shouldStart(
        translation: CGSize(width: 30, height: 0),
        inputPhase: .released
      )
    )
  }

  func testCrewRingDragChoosesAndClampsDestinationByCellMidpoint() {
    let stride = WorkerCrewLayout.taskStride

    XCTAssertEqual(
      CrewRingDragLayout.destinationIndex(
        sourceIndex: 1,
        translationX: stride * 0.49,
        taskCount: 4
      ),
      1
    )
    XCTAssertEqual(
      CrewRingDragLayout.destinationIndex(
        sourceIndex: 1,
        translationX: stride * 0.51,
        taskCount: 4
      ),
      2
    )
    XCTAssertEqual(
      CrewRingDragLayout.destinationIndex(
        sourceIndex: 2,
        translationX: -stride * 0.51,
        taskCount: 4
      ),
      1
    )
    XCTAssertEqual(
      CrewRingDragLayout.destinationIndex(
        sourceIndex: 1,
        translationX: stride * 20,
        taskCount: 4
      ),
      3
    )
    XCTAssertEqual(
      CrewRingDragLayout.destinationIndex(
        sourceIndex: 2,
        translationX: -stride * 20,
        taskCount: 4
      ),
      0
    )
  }

  func testCrewRingDragKeepsDraggedRingUnderPointerAndOpensDestinationGap() {
    let stride = WorkerCrewLayout.taskStride

    XCTAssertEqual(
      (0..<4).map {
        CrewRingDragLayout.offset(
          forIndex: $0,
          sourceIndex: 1,
          destinationIndex: 3,
          translationX: stride * 1.7
        )
      },
      [0, stride * 1.7, -stride, -stride]
    )
    XCTAssertEqual(
      (0..<4).map {
        CrewRingDragLayout.offset(
          forIndex: $0,
          sourceIndex: 3,
          destinationIndex: 1,
          translationX: -stride * 1.7
        )
      },
      [0, stride, stride, -stride * 1.7]
    )
  }

  func testClickPolicyOpensOnlyPrimaryClicksOnTaskRings() {
    XCTAssertEqual(
      StatusItemClickPolicy.intent(isSecondaryClick: false, target: .task),
      .openTask
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(isSecondaryClick: true, target: .task),
      .showMenu
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(isSecondaryClick: false, target: .overflow),
      .showOverflowMenu
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(isSecondaryClick: true, target: .overflow),
      .showOverflowMenu
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(isSecondaryClick: true, target: .background),
      .showMenu
    )
    XCTAssertEqual(
      StatusItemClickPolicy.intent(isSecondaryClick: false, target: .background),
      .showMenu
    )
  }

  func testPrimaryPanAttemptsOnlyFromTaskRings() {
    XCTAssertTrue(
      StatusItemPrimaryGesturePolicy.shouldAttemptPan(
        isCommandModified: false,
        target: .task
      )
    )
    XCTAssertFalse(
      StatusItemPrimaryGesturePolicy.shouldAttemptPan(
        isCommandModified: false,
        target: .overflow
      )
    )
    XCTAssertFalse(
      StatusItemPrimaryGesturePolicy.shouldAttemptPan(
        isCommandModified: false,
        target: .background
      )
    )
    XCTAssertFalse(
      StatusItemPrimaryGesturePolicy.shouldAttemptPan(
        isCommandModified: true,
        target: .task
      )
    )
  }

  @MainActor
  func testMenuPresentationDefersUntilAfterPointerDispatchCompletes() {
    var events = ["pointer"]
    let presentation = expectation(description: "menu presentation")

    StatusItemMenuPresentationPolicy.schedule {
      events.append("menu")
      presentation.fulfill()
    }
    events.append("pointer-complete")

    XCTAssertEqual(events, ["pointer", "pointer-complete"])
    wait(for: [presentation], timeout: 1)
    XCTAssertEqual(events, ["pointer", "pointer-complete", "menu"])
  }

  func testStatusButtonActionHandlesEachSecondaryMouseUpOnlyOnce() {
    let firstEvent = StatusItemActionEventIdentity(eventNumber: 42, timestamp: 1.25)
    let nextEvent = StatusItemActionEventIdentity(eventNumber: 43, timestamp: 1.5)

    XCTAssertTrue(
      StatusItemSecondaryActionPolicy.canReadIdentity(for: .rightMouseUp)
    )
    XCTAssertFalse(
      StatusItemSecondaryActionPolicy.canReadIdentity(for: .leftMouseUp)
    )
    XCTAssertFalse(
      StatusItemSecondaryActionPolicy.canReadIdentity(for: .keyDown)
    )
    XCTAssertTrue(
      StatusItemSecondaryActionPolicy.shouldHandle(
        eventType: .rightMouseUp,
        identity: firstEvent,
        lastHandledIdentity: nil
      )
    )
    XCTAssertFalse(
      StatusItemSecondaryActionPolicy.shouldHandle(
        eventType: .rightMouseUp,
        identity: firstEvent,
        lastHandledIdentity: firstEvent
      )
    )
    XCTAssertTrue(
      StatusItemSecondaryActionPolicy.shouldHandle(
        eventType: .rightMouseUp,
        identity: nextEvent,
        lastHandledIdentity: firstEvent
      )
    )
    XCTAssertFalse(
      StatusItemSecondaryActionPolicy.shouldHandle(
        eventType: .leftMouseUp,
        identity: nextEvent,
        lastHandledIdentity: firstEvent
      )
    )
  }

  func testReducedMotionUsesAStableWorkingPhase() {
    let firstDate = Date(timeIntervalSinceReferenceDate: 10)
    let secondDate = Date(timeIntervalSinceReferenceDate: 20)

    XCTAssertEqual(
      WorkerCrewMotion.phase(for: firstDate, reduceMotion: true),
      WorkerCrewMotion.reducedMotionPhase
    )
    XCTAssertEqual(
      WorkerCrewMotion.phase(for: secondDate, reduceMotion: true),
      WorkerCrewMotion.reducedMotionPhase
    )
    XCTAssertNotEqual(
      WorkerCrewMotion.phase(for: firstDate, reduceMotion: false),
      WorkerCrewMotion.phase(for: secondDate, reduceMotion: false)
    )
  }

  func testTaskRingAnimationRunsForWorkingUnreadCompletionAndAttentionWithoutReducedMotion() {
    let unreadCompletion = TaskPresentation(
      id: "unread",
      title: "unread",
      project: nil,
      state: .ready,
      isUnread: true,
      activeSubagentCount: 0,
      updatedAt: nil
    )

    XCTAssertTrue(
      WorkerCrewMotion.shouldAnimate(
        tasks: [task("working", .working), task("ready", .ready)],
        reduceMotion: false
      )
    )
    XCTAssertTrue(
      WorkerCrewMotion.shouldAnimate(
        tasks: [task("ready", .ready), unreadCompletion],
        reduceMotion: false
      )
    )
    XCTAssertTrue(
      WorkerCrewMotion.shouldAnimate(
        tasks: [task("ready", .ready), task("input", .needsInput)],
        reduceMotion: false
      )
    )
    XCTAssertTrue(
      WorkerCrewMotion.shouldAnimate(
        tasks: [task("approval", .needsApproval), task("blocked", .blocked)],
        reduceMotion: false
      )
    )
    XCTAssertFalse(
      WorkerCrewMotion.shouldAnimate(
        tasks: [task("working", .working), unreadCompletion],
        reduceMotion: true
      )
    )
    XCTAssertTrue(
      WorkerCrewMotion.shouldAnimate(
        tasks: [task("ready", .ready)],
        hasUnreadOverflow: true,
        reduceMotion: false
      )
    )
    XCTAssertFalse(
      WorkerCrewMotion.shouldAnimate(
        tasks: [task("ready", .ready)],
        hasUnreadOverflow: true,
        reduceMotion: true
      )
    )
    XCTAssertTrue(
      WorkerCrewMotion.shouldAnimate(
        tasks: [task("ready", .ready)],
        hasAttentionOverflow: true,
        reduceMotion: false
      )
    )
    XCTAssertFalse(
      WorkerCrewMotion.shouldAnimate(
        tasks: [task("ready", .ready)],
        hasAttentionOverflow: true,
        reduceMotion: true
      )
    )
  }

  func testSharedRingGeometryKeepsSegmentCoverageAndDurationStable() {
    XCTAssertEqual(WorkerCrewRingGeometry.animationDuration, 1.2)
    XCTAssertEqual(WorkerCrewRingGeometry.smoothWaveCount, 7)
    XCTAssertEqual(WorkerCrewRingGeometry.facetedWaveCount, 6)
    XCTAssertEqual(WorkerCrewRingGeometry.smoothWaveAmplitude, 1.4)
    XCTAssertEqual(WorkerCrewRingGeometry.facetedWaveAmplitude, 2.0)
    XCTAssertEqual(WorkerCrewRingGeometry.maximumWaveAmplitude, 2.0)
    XCTAssertEqual(
      WorkerCrewRingGeometry.waveAmplitude(for: .smoothWave),
      1.4
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.waveAmplitude(for: .facetedWave),
      2.0
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.renderedLineWidth(for: .circular),
      3.0
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.renderedLineWidth(for: .smoothWave),
      3.0
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.renderedLineWidth(for: .facetedWave),
      3.0
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.renderedDiameter(for: .circular),
      13.0
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.renderedDiameter(for: .smoothWave),
      13.0
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.renderedDiameter(for: .facetedWave),
      13.0
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.renderedDiameter(for: .circular)
        + WorkerCrewRingGeometry.renderedLineWidth(for: .circular),
      WorkerCrewRingGeometry.renderedDiameter(for: .smoothWave)
        + WorkerCrewRingGeometry.renderedLineWidth(for: .smoothWave),
      accuracy: 0.0001
    )
    XCTAssertFalse(
      WorkerCrewRingGeometry.usesStationaryContourMask(for: .circular)
    )
    XCTAssertTrue(
      WorkerCrewRingGeometry.usesStationaryContourMask(for: .smoothWave)
    )
    XCTAssertTrue(
      WorkerCrewRingGeometry.usesStationaryContourMask(for: .facetedWave)
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.contourMaskLineWidth(ringLineWidth: 3),
      7,
      accuracy: 0.0001
    )
    XCTAssertEqual(WorkerCrewRingGeometry.activeSegmentCount(subagentCount: 0), 1)
    XCTAssertEqual(WorkerCrewRingGeometry.activeSegmentCount(subagentCount: 3), 4)
    XCTAssertEqual(WorkerCrewRingGeometry.activeSegmentCount(subagentCount: 99), 9)
    XCTAssertEqual(
      WorkerCrewRingGeometry.activeSegmentLength(subagentCount: 0),
      0.68,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.activeSegmentLength(subagentCount: 3) * 4,
      0.60,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      (WorkerCrewLayout.cellWidth - WorkerCrewRingGeometry.diameter) / 2,
      1.5
    )
    XCTAssertEqual(WorkerCrewRingGeometry.signalCoreDiameter, 16)
    XCTAssertEqual(
      WorkerCrewRingGeometry.diameter + WorkerCrewRingGeometry.lineWidth,
      WorkerCrewRingGeometry.signalCoreDiameter,
      accuracy: 0.0001
    )
    XCTAssertEqual(WorkerCrewRingGeometry.signalPulseDuration, 2.0)
    XCTAssertEqual(
      WorkerCrewRingGeometry.trackOpacity(for: .ready),
      1,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.signalHaloOpacity(
        for: .ready,
        isUnreadCompletion: true,
        phase: 1.0,
        reduceMotion: false
      ) ?? -1,
      WorkerCrewRingGeometry.signalHaloMinimumOpacity,
      accuracy: 0.0001
    )
    XCTAssertNil(
      WorkerCrewRingGeometry.signalHaloOpacity(
        for: .ready,
        isUnreadCompletion: false,
        phase: 1.0,
        reduceMotion: false
      )
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.signalHaloOpacity(
        for: .approval,
        isUnreadCompletion: false,
        phase: 0,
        reduceMotion: false
      ) ?? -1,
      1,
      accuracy: 0.0001
    )
    for phase in [0.0, 1.0, 2.0] {
      XCTAssertEqual(
        WorkerCrewRingGeometry.signalHaloOpacity(
          for: .approval,
          isUnreadCompletion: false,
          phase: phase,
          reduceMotion: false
        ) ?? -1,
        WorkerCrewRingGeometry.signalHaloOpacity(
          for: .ready,
          isUnreadCompletion: true,
          phase: phase,
          reduceMotion: false
        ) ?? -2,
        accuracy: 0.0001
      )
    }
    XCTAssertEqual(
      WorkerCrewRingGeometry.signalHaloOpacity(
        for: .approval,
        isUnreadCompletion: false,
        phase: 1.0,
        reduceMotion: false
      ) ?? -1,
      WorkerCrewRingGeometry.signalHaloMinimumOpacity,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.signalHaloOpacity(
        for: .ready,
        isUnreadCompletion: true,
        phase: 2.0,
        reduceMotion: false
      ) ?? -1,
      1,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.signalHaloOpacity(
        for: .ready,
        isUnreadCompletion: true,
        phase: 1.0,
        reduceMotion: true
      ) ?? -1,
      1,
      accuracy: 0.0001
    )
    XCTAssertGreaterThan(
      WorkerCrewRingGeometry.signalHaloLineWidth(reduceMotion: true),
      WorkerCrewRingGeometry.signalHaloLineWidth(reduceMotion: false)
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.outlineOpacity(
        for: 1.0,
        hasUnreadCompletion: true,
        reduceMotion: false
      ),
      CrewOverflowBadgeGeometry.unreadOutlineMinimumOpacity,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.outlineOpacity(
        for: 1.0,
        hasUnreadCompletion: true,
        reduceMotion: false
      ),
      CrewOverflowBadgeGeometry.outlineOpacity(
        for: 1.0,
        hasUnreadCompletion: false,
        hasAttention: true,
        reduceMotion: false
      ),
      accuracy: 0.0001
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.outlineOpacity(
        for: 0,
        hasUnreadCompletion: true,
        reduceMotion: false
      ),
      1,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.outlineOpacity(
        for: 1.5,
        hasUnreadCompletion: false,
        reduceMotion: false
      ),
      CrewOverflowBadgeGeometry.normalOutlineOpacity,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.outlineOpacity(
        for: 1.0,
        hasUnreadCompletion: false,
        hasAttention: true,
        reduceMotion: false
      ),
      CrewOverflowBadgeGeometry.unreadOutlineMinimumOpacity,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.textOpacity(
        for: 1.0,
        hasUnreadCompletion: true,
        reduceMotion: false
      ),
      CrewOverflowBadgeGeometry.unreadTextMinimumOpacity,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.unreadTextMinimumOpacity,
      0.55,
      accuracy: 0.0001
    )
    XCTAssertGreaterThan(
      CrewOverflowBadgeGeometry.unreadTextMinimumOpacity,
      CrewOverflowBadgeGeometry.unreadOutlineMinimumOpacity
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.textOpacity(
        for: 0,
        hasUnreadCompletion: true,
        reduceMotion: false
      ),
      1,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.textOpacity(
        for: 1.5,
        hasUnreadCompletion: true,
        reduceMotion: true
      ),
      1,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.textOpacity(
        for: 1.5,
        hasUnreadCompletion: false,
        reduceMotion: false
      ),
      1,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.lineWidth(
        hasUnreadCompletion: true,
        reduceMotion: false
      ),
      CrewOverflowBadgeGeometry.unreadLineWidth
    )
    XCTAssertEqual(
      CrewOverflowBadgeGeometry.lineWidth(
        hasUnreadCompletion: false,
        hasAttention: true,
        reduceMotion: false
      ),
      CrewOverflowBadgeGeometry.unreadLineWidth
    )
    XCTAssertGreaterThan(
      CrewOverflowBadgeGeometry.lineWidth(
        hasUnreadCompletion: true,
        reduceMotion: true
      ),
      CrewOverflowBadgeGeometry.unreadLineWidth
    )
  }

  func testTaskAccessibilityValueIncludesStateAndSubagentCount() {
    XCTAssertEqual(task("one", .needsInput).accessibilityValue, "Needs Input")
    let taskWithSubagents = TaskPresentation(
      id: "two",
      title: "two",
      project: nil,
      state: .working,
      activeSubagentCount: 2,
      updatedAt: nil
    )
    XCTAssertEqual(taskWithSubagents.accessibilityValue, "Working, 2 active subagents")
  }

  func testContourGeometryAndDisabledActivitySwitchingStayStable() {
    XCTAssertEqual(WorkerCrewRingGeometry.smoothWaveCount, 7)
    XCTAssertEqual(WorkerCrewRingGeometry.facetedWaveCount, 6)
    XCTAssertEqual(
      WorkerCrewRingGeometry.waveCount(for: .smoothWave),
      7
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.waveCount(for: .facetedWave),
      6
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.lineJoin(for: .smoothWave),
      .round
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.lineJoin(for: .facetedWave),
      .miter
    )
    let activities: [CodexTaskCurrentActivity?] = [
      nil,
      .working,
      .writingResponse,
      .thinking,
      .planning,
      .runningCommand,
      .editingFiles,
      .coordinatingAgents,
      .checkingPermissions,
      .compactingContext,
    ]
    for activity in activities {
      XCTAssertEqual(WorkerCrewRingGeometry.contour(for: activity), .circular)
    }

    XCTAssertEqual(WorkerCrewRingGeometry.animationDuration, 1.2)
    XCTAssertEqual(
      WorkerCrewRingGeometry.activeSegmentLength(subagentCount: 0),
      0.68,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.radialInset(for: .smoothWave, fraction: 0),
      0,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.radialInset(
        for: .smoothWave,
        fraction: 0.5 / WorkerCrewRingGeometry.waveCount(for: .smoothWave)
      ),
      WorkerCrewRingGeometry.smoothWaveAmplitude,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      WorkerCrewRingGeometry.radialInset(
        for: .facetedWave,
        fraction: 0.5 / WorkerCrewRingGeometry.waveCount(for: .facetedWave)
      ),
      WorkerCrewRingGeometry.facetedWaveAmplitude,
      accuracy: 0.0001
    )
  }

  func testAttentionStateAndOverflowAccessibilityStayConsistent() {
    XCTAssertTrue(CodexTaskActivityState.needsApproval.requiresAttention)
    XCTAssertTrue(CodexTaskActivityState.needsInput.requiresAttention)
    XCTAssertTrue(CodexTaskActivityState.blocked.requiresAttention)
    XCTAssertFalse(CodexTaskActivityState.working.requiresAttention)
    XCTAssertFalse(CodexTaskActivityState.ready.requiresAttention)

    XCTAssertEqual(
      CrewOverflowAccessibility.detail(attentionCount: 2, unreadCompletionCount: 1),
      "2 need attention, 1 completed unread"
    )
    XCTAssertEqual(
      CrewOverflowAccessibility.label(
        overflowCount: 3,
        attentionCount: 2,
        unreadCompletionCount: 1
      ),
      "3 more tasks, 2 need attention, 1 completed unread"
    )
    XCTAssertEqual(
      CrewSummaryAccessibility.label(
        overflowCount: 3,
        attentionCount: 2,
        unreadCompletionCount: 1,
        capacityRemainingPercent: 1
      ),
      "3 more tasks, 2 need attention, 1 completed unread, Codex capacity 1 percent remaining"
    )
  }

  func testElapsedLabelUsesTurnStartAndRejectsFutureTimes() {
    let now = Date(timeIntervalSince1970: 10_000)
    XCTAssertEqual(
      taskStarted(secondsAgo: 45, relativeTo: now).elapsedLabel(relativeTo: now), "<1 min")
    XCTAssertEqual(
      taskStarted(secondsAgo: 245, relativeTo: now).elapsedLabel(relativeTo: now), "4 min")
    XCTAssertEqual(
      taskStarted(secondsAgo: 7_200, relativeTo: now).elapsedLabel(relativeTo: now), "2 hr")
    XCTAssertNil(taskStarted(secondsAgo: -1, relativeTo: now).elapsedLabel(relativeTo: now))
  }

  func testActivitySummariesKeepProjectIdentityFirstInMenus() {
    let now = Date(timeIntervalSince1970: 10_000)
    let activeTask = TaskPresentation(
      id: "active",
      title: "active",
      project: "codex-echo",
      state: .working,
      activeSubagentCount: 2,
      updatedAt: nil,
      turnStartedAt: now.addingTimeInterval(-245),
      currentActivity: .runningCommand
    )

    XCTAssertEqual(
      activeTask.hoverActivitySummary(relativeTo: now),
      "Running command · 4 min · 2 subagents"
    )
    XCTAssertEqual(
      activeTask.menuActivitySummary(relativeTo: now),
      "codex-echo · Running command · 4 min · 2 subagents"
    )
    XCTAssertEqual(activeTask.accessibilityValue, "Running command, 2 active subagents")

    let compactionTask = TaskPresentation(
      id: "compaction",
      title: "compaction",
      project: "codex-echo",
      state: .working,
      activeSubagentCount: 0,
      updatedAt: nil,
      currentActivity: .compactingContext
    )
    XCTAssertEqual(
      compactionTask.menuActivitySummary(relativeTo: now),
      "codex-echo · Compacting context"
    )
    XCTAssertEqual(compactionTask.accessibilityValue, "Compacting context")
    XCTAssertEqual(TaskActivityPresentationTiming.elapsedRefreshInterval, 15)

    let noProjectTask = TaskPresentation(
      id: "no-project",
      title: "no project",
      projectIdentity: .noProject,
      state: .working,
      activeSubagentCount: 0,
      updatedAt: nil
    )
    XCTAssertEqual(noProjectTask.project, "No Project")
    XCTAssertEqual(
      noProjectTask.menuActivitySummary(relativeTo: now),
      "No Project · Working"
    )
  }

  func testAttentionSummaryDoesNotMislabelTurnElapsedTimeAsWaitingTime() {
    let now = Date(timeIntervalSince1970: 10_000)
    let attentionTask = TaskPresentation(
      id: "attention",
      title: "attention",
      project: "codex-echo",
      state: .needsApproval,
      activeSubagentCount: 0,
      updatedAt: nil,
      turnStartedAt: now.addingTimeInterval(-245)
    )

    XCTAssertEqual(attentionTask.hoverActivitySummary(relativeTo: now), "Approval Required")
    XCTAssertEqual(
      attentionTask.menuActivitySummary(relativeTo: now),
      "codex-echo · Approval Required"
    )
  }

  func testCompletedSummaryPreservesTheTurnDuration() {
    let completedAt = Date(timeIntervalSince1970: 10_000)
    let completedTask = TaskPresentation(
      id: "completed",
      title: "completed",
      project: "codex-echo",
      state: .ready,
      activeSubagentCount: 0,
      updatedAt: completedAt,
      completedAt: completedAt,
      completedDuration: 245
    )

    XCTAssertEqual(completedTask.completedDurationLabel, "4 min")
    XCTAssertEqual(completedTask.hoverActivitySummary(), "Completed in 4 min")
    XCTAssertEqual(
      completedTask.menuActivitySummary(),
      "codex-echo · Completed in 4 min"
    )
    XCTAssertEqual(completedTask.accessibilityValue, "Completed in 4 min")
  }

  func testUnreadCompletedTaskUsesSignalAndConsistentText() {
    let completedTask = TaskPresentation(
      id: "completed-unread",
      title: "completed unread",
      project: "codex-echo",
      state: .ready,
      isUnread: true,
      activeSubagentCount: 0,
      updatedAt: nil,
      completedDuration: 245
    )

    XCTAssertTrue(completedTask.showsUnreadCompletionSignal)
    XCTAssertEqual(completedTask.hoverActivitySummary(), "Completed in 4 min · Unread")
    XCTAssertEqual(
      completedTask.menuActivitySummary(),
      "codex-echo · Completed in 4 min · Unread"
    )
    XCTAssertEqual(completedTask.accessibilityValue, "Completed in 4 min, unread")

    let workingTask = TaskPresentation(
      id: "working-unread",
      title: "working unread",
      project: nil,
      state: .working,
      isUnread: true,
      activeSubagentCount: 0,
      updatedAt: nil
    )
    XCTAssertFalse(workingTask.showsUnreadCompletionSignal)
    XCTAssertEqual(workingTask.hoverActivitySummary(), "Working")
  }

  func testCompletionTimingPrefersIPCAndFallsBackToTheObservedTransition() {
    let observedAt = Date(timeIntervalSince1970: 10_000)
    let exactCompletedAt = observedAt.addingTimeInterval(-10)
    let exact = CompletionTimingPolicy.resolve(
      exactCompletedAt: exactCompletedAt,
      exactDuration: 245,
      previousTurnStartedAt: observedAt.addingTimeInterval(-500),
      observedAt: observedAt
    )

    XCTAssertEqual(exact?.completedAt, exactCompletedAt)
    XCTAssertEqual(exact?.duration, 245)
    XCTAssertEqual(exact?.turnStartedAt, exactCompletedAt.addingTimeInterval(-245))

    let fallback = CompletionTimingPolicy.resolve(
      exactCompletedAt: nil,
      exactDuration: nil,
      previousTurnStartedAt: observedAt.addingTimeInterval(-95),
      observedAt: observedAt
    )
    XCTAssertEqual(fallback?.completedAt, observedAt)
    XCTAssertEqual(fallback?.duration, 95)
    XCTAssertNil(
      CompletionTimingPolicy.resolve(
        exactCompletedAt: nil,
        exactDuration: nil,
        previousTurnStartedAt: observedAt.addingTimeInterval(1),
        observedAt: observedAt
      )
    )
  }

  func testCompletedTimingPersistsAcrossModelRestarts() {
    let suiteName = "CodexEchoTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Unable to create isolated user defaults")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let timing = CompletedTaskTiming(
      turnStartedAt: Date(timeIntervalSince1970: 9_755),
      completedAt: Date(timeIntervalSince1970: 10_000),
      duration: 245
    )

    CompletedTaskTimingPersistence.save(
      ["completed": timing],
      to: defaults,
      key: "completedTaskTimings"
    )

    XCTAssertEqual(
      CompletedTaskTimingPersistence.load(
        from: defaults,
        key: "completedTaskTimings"
      ),
      ["completed": timing]
    )
  }

  func testConnectionHealthRequiresBothSourcesForLiveState() {
    XCTAssertEqual(
      CodexConnectionHealthPolicy.resolve(ipc: .connected, appServer: .running),
      .live
    )
    XCTAssertEqual(
      CodexConnectionHealthPolicy.resolve(
        ipc: .connected,
        appServer: .failed(message: "catalog failed")
      ),
      .degraded(.taskCatalogUnavailable)
    )
    XCTAssertEqual(
      CodexConnectionHealthPolicy.resolve(ipc: .disconnected, appServer: .running),
      .degraded(.liveActivityUnavailable)
    )
    XCTAssertEqual(
      CodexConnectionHealthPolicy.resolve(
        ipc: .incompatible(reason: "version"),
        appServer: .running
      ),
      .incompatible
    )
    XCTAssertEqual(
      CodexConnectionHealthPolicy.resolve(
        ipc: .disconnected,
        appServer: .failed(message: "offline")
      ),
      .offline
    )
  }

  func testConnectionMenuStatusAppearsOnlyWhenConnectionIsNotLive() {
    XCTAssertFalse(CodexConnectionHealth.live.showsMenuStatus)
    XCTAssertTrue(CodexConnectionHealth.connecting.showsMenuStatus)
    XCTAssertTrue(
      CodexConnectionHealth.degraded(.taskCatalogUnavailable).showsMenuStatus
    )
    XCTAssertTrue(CodexConnectionHealth.incompatible.showsMenuStatus)
    XCTAssertTrue(CodexConnectionHealth.offline.showsMenuStatus)
  }

  func testDesktopAppPresenceIsResolvedIndependentlyFromConnectionHealth() {
    XCTAssertEqual(
      CodexDesktopAppStatePolicy.resolve(isInstalled: false, isRunning: false),
      .notInstalled
    )
    XCTAssertEqual(
      CodexDesktopAppStatePolicy.resolve(isInstalled: true, isRunning: false),
      .notRunning
    )
    XCTAssertEqual(
      CodexDesktopAppStatePolicy.resolve(isInstalled: false, isRunning: true),
      .running
    )

    XCTAssertEqual(
      CodexStatusPresentationPolicy.resolve(
        desktopAppState: .notRunning,
        connectionHealth: .live
      ),
      .desktopAppNotRunning
    )
    XCTAssertEqual(
      CodexStatusPresentationPolicy.resolve(
        desktopAppState: .running,
        connectionHealth: .degraded(.liveActivityUnavailable)
      ),
      .connection(.degraded(.liveActivityUnavailable))
    )
  }

  func testDesktopAppRecoveryMenuExplainsStateAndOffersOnlyValidAction() {
    XCTAssertEqual(
      CodexStatusPresentation.desktopAppNotRunning.desktopAppRecoveryMenu,
      CodexDesktopAppRecoveryMenu(
        statusTitle: "Codex App Isn’t Running",
        statusSymbolName: "exclamationmark.circle",
        actionTitle: "Open Codex",
        actionSymbolName: "arrow.up.forward.app"
      )
    )
    XCTAssertEqual(
      CodexStatusPresentation.desktopAppLaunching.desktopAppRecoveryMenu,
      CodexDesktopAppRecoveryMenu(
        statusTitle: "Opening Codex…",
        statusSymbolName: "ellipsis.circle",
        actionTitle: nil,
        actionSymbolName: nil
      )
    )
    XCTAssertEqual(
      CodexStatusPresentation.desktopAppLaunchFailed.desktopAppRecoveryMenu,
      CodexDesktopAppRecoveryMenu(
        statusTitle: "Couldn’t Open Codex",
        statusSymbolName: "exclamationmark.circle",
        actionTitle: "Try Again",
        actionSymbolName: "arrow.clockwise"
      )
    )
    XCTAssertEqual(
      CodexStatusPresentation.desktopAppNotInstalled.desktopAppRecoveryMenu,
      CodexDesktopAppRecoveryMenu(
        statusTitle: "Codex App Not Found",
        statusSymbolName: "exclamationmark.circle",
        actionTitle: nil,
        actionSymbolName: nil
      )
    )
    XCTAssertNil(CodexStatusPresentation.connection(.live).desktopAppRecoveryMenu)
  }

  func testNoTaskFallbackUsesFamiliarStaticSystemSymbolsAndHidesStaleTaskSignals() {
    XCTAssertEqual(
      CodexStatusPresentation.desktopAppNotRunning.fallbackSymbolName,
      "exclamationmark.circle"
    )
    XCTAssertEqual(
      CodexStatusPresentation.connection(.live).fallbackSymbolName,
      "checkmark.circle"
    )
    XCTAssertEqual(
      CodexStatusPresentation.connection(.connecting).fallbackSymbolName,
      "ellipsis.circle"
    )
    XCTAssertEqual(
      CodexStatusPresentation.connection(.degraded(.taskCatalogUnavailable))
        .fallbackSymbolName,
      "exclamationmark.triangle"
    )
    XCTAssertEqual(
      CodexStatusPresentation.connection(.incompatible).fallbackSymbolName,
      "exclamationmark.triangle.fill"
    )
    XCTAssertEqual(
      CodexStatusPresentation.connection(.offline).fallbackSymbolName,
      "bolt.horizontal.circle"
    )
    XCTAssertEqual(
      CodexStatusPresentation.connection(.live).accessibilityLabel,
      "Connected to Codex"
    )
    XCTAssertEqual(
      CodexStatusPresentation.desktopAppNotRunning.accessibilityLabel,
      "Codex App isn’t running"
    )
    XCTAssertFalse(CodexStatusPresentation.desktopAppNotRunning.showsTaskSignals)
    XCTAssertFalse(CodexStatusPresentation.desktopAppLaunching.showsTaskSignals)
    XCTAssertTrue(CodexStatusPresentation.connection(.connecting).showsTaskSignals)
    XCTAssertTrue(CodexStatusPresentation.connection(.live).showsAuthoritativeEmptyTaskState)
    XCTAssertFalse(
      CodexStatusPresentation.connection(.connecting).showsAuthoritativeEmptyTaskState
    )
  }

  func testHitTargetsKeepCrewCellsGapsAndOverflowDistinct() throws {
    let summaryRange = try XCTUnwrap(
      WorkerCrewLayout.summaryRange(
        displayedCrewCount: 4,
        overflowCount: 2,
        capacityRemainingPercent: nil
      )
    )
    XCTAssertEqual(hitTarget(0), .crew(0))
    XCTAssertEqual(hitTarget(22), .crew(0))
    XCTAssertNil(hitTarget(22.1))
    XCTAssertNil(hitTarget(29.9))
    XCTAssertEqual(hitTarget(31), .crew(1))
    XCTAssertEqual(hitTarget(115), .crew(3))
    XCTAssertNil(hitTarget(115.1))
    XCTAssertNil(hitTarget(summaryRange.lowerBound - 0.1))
    XCTAssertEqual(hitTarget(summaryRange.lowerBound), .overflow)
    XCTAssertEqual(hitTarget(summaryRange.upperBound), .overflow)
    XCTAssertNil(hitTarget(summaryRange.upperBound + 0.1))
  }

  func testZeroVisibleLimitKeepsTheConnectionGlyphAndOverflowHitTargetsDistinct() throws {
    func zeroLimitHitTarget(
      _ x: CGFloat,
      capacityRemainingPercent: Int? = nil
    ) -> WorkerCrewHitTarget? {
      WorkerCrewLayout.hitTarget(
        at: x,
        displayedCrewCount: 0,
        overflowCount: 3,
        capacityRemainingPercent: capacityRemainingPercent
      )
    }

    let overflowRange = try XCTUnwrap(
      WorkerCrewLayout.summaryRange(
        displayedCrewCount: 0,
        overflowCount: 3,
        capacityRemainingPercent: nil
      )
    )
    XCTAssertNil(zeroLimitHitTarget(0))
    XCTAssertNil(zeroLimitHitTarget(22))
    XCTAssertNil(zeroLimitHitTarget(overflowRange.lowerBound - 0.1))
    XCTAssertEqual(zeroLimitHitTarget(overflowRange.lowerBound), .overflow)
    XCTAssertEqual(zeroLimitHitTarget(overflowRange.upperBound), .overflow)
    XCTAssertNil(zeroLimitHitTarget(overflowRange.upperBound + 0.1))

    let combinedRange = try XCTUnwrap(
      WorkerCrewLayout.summaryRange(
        displayedCrewCount: 0,
        overflowCount: 3,
        capacityRemainingPercent: 9
      )
    )
    XCTAssertEqual(
      zeroLimitHitTarget(
        combinedRange.upperBound,
        capacityRemainingPercent: 9
      ),
      .overflow
    )
    XCTAssertNil(
      zeroLimitHitTarget(
        combinedRange.upperBound + 0.1,
        capacityRemainingPercent: 9
      )
    )

    let twoDigitOverflowRange = try XCTUnwrap(
      WorkerCrewLayout.summaryRange(
        displayedCrewCount: 0,
        overflowCount: 17,
        capacityRemainingPercent: nil
      )
    )
    XCTAssertEqual(
      WorkerCrewLayout.hitTarget(
        at: twoDigitOverflowRange.upperBound,
        displayedCrewCount: 0,
        overflowCount: 17
      ),
      .overflow
    )
    XCTAssertNil(
      WorkerCrewLayout.hitTarget(
        at: twoDigitOverflowRange.upperBound + 0.1,
        displayedCrewCount: 0,
        overflowCount: 17
      )
    )
  }

  func testCapacitySegmentSharesTheOverflowHitTarget() throws {
    func combinedHitTarget(_ x: CGFloat) -> WorkerCrewHitTarget? {
      WorkerCrewLayout.hitTarget(
        at: x,
        displayedCrewCount: 4,
        overflowCount: 2,
        capacityRemainingPercent: 9
      )
    }

    let combinedRange = try XCTUnwrap(
      WorkerCrewLayout.summaryRange(
        displayedCrewCount: 4,
        overflowCount: 2,
        capacityRemainingPercent: 9
      )
    )
    XCTAssertNil(combinedHitTarget(combinedRange.lowerBound - 0.1))
    XCTAssertEqual(combinedHitTarget(combinedRange.lowerBound), .overflow)
    XCTAssertEqual(combinedHitTarget(combinedRange.upperBound), .overflow)
    XCTAssertNil(combinedHitTarget(combinedRange.upperBound + 0.1))
  }

  func testContentWidthTracksVisibleElementsWithoutExteriorPadding() {
    XCTAssertEqual(WorkerCrewLayout.contentWidth(forCrewCount: 0), 16)
    XCTAssertEqual(WorkerCrewLayout.contentWidth(forCrewCount: 1), 16)
    XCTAssertEqual(WorkerCrewLayout.contentWidth(forCrewCount: 2), 47)
    XCTAssertEqual(WorkerCrewLayout.contentWidth(forCrewCount: 3), 78)
    XCTAssertEqual(WorkerCrewLayout.contentWidth(forCrewCount: 4), 109)
    let fourTasksWithSingleDigitOverflow =
      WorkerCrewLayout.taskGroupWidth(for: 4)
      + WorkerCrewLayout.summarySpacing
      + WorkerCrewLayout.summaryWidth(
        overflowCount: 1,
        capacityRemainingPercent: nil
      )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(forCrewCount: 5),
      fourTasksWithSingleDigitOverflow
    )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(forCrewCount: 8),
      fourTasksWithSingleDigitOverflow
    )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(forCrewCount: 1, showsHealthBadge: true),
      40
    )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(forCrewCount: 5, showsHealthBadge: true),
      fourTasksWithSingleDigitOverflow
        + WorkerCrewLayout.spacing
        + WorkerCrewLayout.healthWidth
    )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(
        forDisplayedCrewCount: 0,
        overflowCount: 3
      ),
      WorkerCrewLayout.cellWidth
        + WorkerCrewLayout.summarySpacing
        + WorkerCrewLayout.summaryWidth(
          overflowCount: 3,
          capacityRemainingPercent: nil
        )
    )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(
        forDisplayedCrewCount: 0,
        overflowCount: 3,
        capacityRemainingPercent: 9
      ),
      WorkerCrewLayout.cellWidth
        + WorkerCrewLayout.summarySpacing
        + WorkerCrewLayout.summaryWidth(
          overflowCount: 3,
          capacityRemainingPercent: 9
        )
    )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(
        forDisplayedCrewCount: 0,
        overflowCount: 17
      ),
      WorkerCrewLayout.cellWidth
        + WorkerCrewLayout.summarySpacing
        + WorkerCrewLayout.summaryWidth(
          overflowCount: 17,
          capacityRemainingPercent: nil
        )
    )
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(
        forDisplayedCrewCount: 0,
        overflowCount: 100,
        capacityRemainingPercent: 100
      ),
      WorkerCrewLayout.cellWidth
        + WorkerCrewLayout.summarySpacing
        + WorkerCrewLayout.summaryWidth(
          overflowCount: 100,
          capacityRemainingPercent: 100
        )
    )
  }

  func testStatusItemOpticalEdgesKeepSystemRhythmWithoutExteriorPadding() {
    XCTAssertEqual(
      WorkerCrewLayout.cellWidth,
      WorkerCrewRingGeometry.signalCoreDiameter
    )
    XCTAssertEqual(WorkerCrewLayout.taskHitTargetWidth, 22)
    XCTAssertEqual(WorkerCrewLayout.taskStride, 31)
    XCTAssertEqual(WorkerCrewLayout.summarySpacing, WorkerCrewLayout.taskSpacing)
    XCTAssertEqual(WorkerCrewLayout.summaryHorizontalPadding, 5)
    XCTAssertEqual(WorkerCrewLayout.summaryContentSpacing, 4)
    XCTAssertEqual(
      WorkerCrewLayout.contentWidth(
        forDisplayedCrewCount: 2,
        overflowCount: 0,
        capacityRemainingPercent: 9
      ),
      WorkerCrewLayout.taskGroupWidth(for: 2)
        + WorkerCrewLayout.summarySpacing
        + WorkerCrewLayout.summaryWidth(
          overflowCount: 0,
          capacityRemainingPercent: 9
        )
    )
  }

  func testSummaryCapsuleWidthTracksOverflowAndCapacityDigitCounts() {
    let overflowWidths = [1, 10, 100].map {
      WorkerCrewLayout.summaryWidth(
        overflowCount: $0,
        capacityRemainingPercent: nil
      )
    }
    let capacityWidths = [9, 10, 100].map {
      WorkerCrewLayout.summaryWidth(
        overflowCount: 0,
        capacityRemainingPercent: $0
      )
    }
    let combinedWidths = [9, 10, 100].map {
      WorkerCrewLayout.summaryWidth(
        overflowCount: 1,
        capacityRemainingPercent: $0
      )
    }

    for widths in [overflowWidths, capacityWidths, combinedWidths] {
      XCTAssertLessThan(widths[0], widths[1])
      XCTAssertLessThan(widths[1], widths[2])
      XCTAssertLessThanOrEqual(widths[1] - widths[0], 8)
      XCTAssertLessThanOrEqual(widths[2] - widths[1], 8)
    }
    XCTAssertLessThan(combinedWidths[0], 50)
  }

  @MainActor
  func testSummaryLayoutWidthFitsEveryRenderedDigitVariant() {
    let variants: [(overflowCount: Int, capacityRemainingPercent: Int?)] = [
      (1, nil),
      (10, nil),
      (100, nil),
      (0, 9),
      (0, 10),
      (0, 100),
      (1, 9),
      (1, 10),
      (1, 100),
      (10, 9),
      (100, 100),
    ]

    for variant in variants {
      let view = NSHostingView(
        rootView: CrewSummaryBadge(
          overflowCount: variant.overflowCount,
          unreadCompletionCount: 0,
          attentionCount: 0,
          capacityRemainingPercent: variant.capacityRemainingPercent,
          phase: 0,
          reduceMotion: true
        )
        .environment(\.colorScheme, .light)
      )
      view.layoutSubtreeIfNeeded()
      let layoutWidth = WorkerCrewLayout.summaryWidth(
        overflowCount: variant.overflowCount,
        capacityRemainingPercent: variant.capacityRemainingPercent
      )

      XCTAssertEqual(
        layoutWidth,
        view.fittingSize.width.rounded(.up),
        accuracy: 0.5,
        "Width mismatch for +\(variant.overflowCount) and "
          + "\(variant.capacityRemainingPercent.map(String.init) ?? "no")%"
      )
    }
  }

  func testZeroVisibleLimitKeepsEveryRingWorthyTaskInOverflow() {
    let tasks = [
      task("working", .working),
      task("ready", .ready),
      task("input", .needsInput),
    ]

    let visible = StatusItemTaskPolicy.statusBarTasks(from: tasks, limit: 0)
    let overflow = StatusItemTaskPolicy.overflowTasks(
      from: tasks,
      visibleTasks: visible
    )

    XCTAssertTrue(visible.isEmpty)
    XCTAssertEqual(overflow.map(\.id), ["working", "ready", "input"])
  }

  func testStatusBarSlotsStayBoundToThePreferredPrefixWhenUrgencyChanges() {
    let tasks = [
      task("one", .working),
      task("two", .needsInput),
      task("three", .working),
      task("four", .ready),
      task("five", .needsApproval),
    ]

    let visible = StatusItemTaskPolicy.statusBarTasks(from: tasks)

    XCTAssertEqual(visible.map(\.id), ["one", "two", "three", "four"])
  }

  func testOverflowKeepsUrgentTasksWithoutReplacingRememberedRingPositions() {
    let tasks = [
      task("one", .working),
      task("two", .ready),
      task("three", .working),
      task("four", .ready),
      task("input", .needsInput),
      task("approval", .needsApproval),
    ]

    let visible = StatusItemTaskPolicy.statusBarTasks(from: tasks)
    let overflow = StatusItemTaskPolicy.overflowTasks(from: tasks, visibleTasks: visible)

    XCTAssertEqual(visible.map(\.id), ["one", "two", "three", "four"])
    XCTAssertEqual(overflow.map(\.id), ["input", "approval"])
  }

  func testStatusBarNeverReordersAnAllAttentionPrefix() {
    let tasks = [
      task("input-one", .needsInput, updatedAt: 4),
      task("error", .blocked, updatedAt: 3),
      task("input-two", .needsInput, updatedAt: 2),
      task("input-three", .needsInput, updatedAt: 1),
      task("approval", .needsApproval, updatedAt: 5),
    ]

    let visible = StatusItemTaskPolicy.statusBarTasks(from: tasks)

    XCTAssertEqual(visible.map(\.id), ["input-one", "error", "input-two", "input-three"])
  }

  func testMenuTasksRemainCompleteAndDeduplicatedBeyondEightItems() {
    let allTasks = (1...10).map { task("task-\($0)", .idle) }
    let crewTasks = [allTasks[8], allTasks[9]]

    let menuTasks = StatusItemTaskPolicy.menuTasks(
      crewTasks: crewTasks,
      allTasks: allTasks
    )

    XCTAssertEqual(menuTasks.count, 10)
    XCTAssertEqual(menuTasks.prefix(2).map(\.id), ["task-9", "task-10"])
    XCTAssertEqual(Set(menuTasks.map(\.id)).count, 10)
  }

  func testMenuTaskPrefixMatchesTheVisibleRingOrder() {
    let allTasks = [
      task("one", .working),
      task("two", .ready),
      task("three", .working),
      task("four", .ready),
      task("approval", .needsApproval),
    ]
    let visibleRings = StatusItemTaskPolicy.statusBarTasks(from: allTasks)

    let menuTasks = StatusItemTaskPolicy.menuTasks(
      crewTasks: visibleRings,
      allTasks: allTasks
    )

    XCTAssertEqual(visibleRings.map(\.id), ["one", "two", "three", "four"])
    XCTAssertEqual(
      Array(menuTasks.prefix(visibleRings.count)).map(\.id),
      visibleRings.map(\.id)
    )
    XCTAssertEqual(menuTasks.map(\.id), ["one", "two", "three", "four", "approval"])
  }

  func testContextMenuStaysAppScopedWithoutAClickedTask() {
    let tasks = [
      task("visible-one", .working),
      task("visible-two", .ready),
      task("overflow", .working),
      task("recent", .idle),
    ]

    XCTAssertNil(
      StatusItemContextMenuTaskPolicy.task(
        in: tasks,
        scope: .appScoped
      )
    )
  }

  func testContextMenuResolvesOnlyTheClickedTask() {
    let tasks = (1...10).map { task("task-\($0)", .working) }

    let contextualTask = StatusItemContextMenuTaskPolicy.task(
      in: tasks,
      scope: .task(tasks[8])
    )

    XCTAssertEqual(contextualTask?.id, "task-9")
  }

  func testContextMenuResolvesClickedTaskAgainstTheCurrentTaskList() {
    let currentTask = task("current", .ready)
    let removedTask = task("removed", .working)
    let absentTask = StatusItemContextMenuTaskPolicy.task(
      in: [currentTask],
      scope: .task(removedTask)
    )

    XCTAssertNil(absentTask)

    let staleSnapshot = task("current", .working)
    let refreshedTask = StatusItemContextMenuTaskPolicy.task(
      in: [currentTask],
      scope: .task(staleSnapshot)
    )

    XCTAssertEqual(refreshedTask?.state, .ready)
  }

  private func task(
    _ id: String,
    _ state: CodexTaskActivityState,
    updatedAt: TimeInterval? = nil
  ) -> TaskPresentation {
    TaskPresentation(
      id: id,
      title: id,
      project: nil,
      state: state,
      activeSubagentCount: 0,
      updatedAt: updatedAt.map(Date.init(timeIntervalSince1970:))
    )
  }

  private func hitTarget(_ x: CGFloat) -> WorkerCrewHitTarget? {
    WorkerCrewLayout.hitTarget(
      at: x,
      displayedCrewCount: 4,
      overflowCount: 2
    )
  }

  private func taskStarted(secondsAgo: TimeInterval, relativeTo now: Date) -> TaskPresentation {
    TaskPresentation(
      id: "elapsed",
      title: "elapsed",
      project: nil,
      state: .working,
      activeSubagentCount: 0,
      updatedAt: nil,
      turnStartedAt: now.addingTimeInterval(-secondsAgo),
      currentActivity: .thinking
    )
  }
}
