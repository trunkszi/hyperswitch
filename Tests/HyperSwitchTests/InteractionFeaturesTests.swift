import CoreGraphics
import XCTest
@testable import HyperSwitch

nonisolated final class InteractionFeaturesTests: XCTestCase {
    func testSearchMatchesApplicationAndWindowTitleIgnoringCaseAndDiacritics() {
        let windows = [
            window(id: 1, title: "Résumé 2026", app: "Pages", space: 1),
            window(id: 2, title: "Build Log", app: "Xcode", space: 2),
            window(id: 3, title: "Inbox", app: "Mail", space: nil),
        ]

        XCTAssertEqual(SwitcherSearch.filter(windows, query: "resume").map(\.id), [1])
        XCTAssertEqual(SwitcherSearch.filter(windows, query: "XCODE").map(\.id), [2])
        XCTAssertEqual(SwitcherSearch.filter(windows, query: "").map(\.id), [1, 2, 3])
    }

    /// The rule that stops the keyboard and the full-size preview driving each other in a
    /// loop: after a keyboard move, a hover only counts once the pointer has really gone
    /// somewhere. A panel re-fitting itself moves the cards, not the mouse.
    func testPointerSuppressionOnlyLiftsOnRealMovement() {
        let anchor = CGPoint(x: 400, y: 300)

        XCTAssertFalse(PointerSuppression.shouldRelease(
            anchor: anchor, current: anchor, beyond: 6))
        XCTAssertFalse(PointerSuppression.shouldRelease(
            anchor: anchor, current: CGPoint(x: 404, y: 303), beyond: 6),
            "5 pt is inside the radius — hand tremor, not intent")
        XCTAssertTrue(PointerSuppression.shouldRelease(
            anchor: anchor, current: CGPoint(x: 410, y: 300), beyond: 6))
        XCTAssertTrue(PointerSuppression.shouldRelease(
            anchor: anchor, current: CGPoint(x: 400, y: 290), beyond: 6),
            "the test is distance, so vertical movement counts the same")
    }

    func testCenteredSliceKeepsSelectionInCentralBandAndClampsAtEdges() {
        XCTAssertEqual(CenteredSlice.range(count: 10, selected: 0, capacity: 5), 0..<5)
        XCTAssertEqual(CenteredSlice.range(count: 10, selected: 5, capacity: 5), 3..<8)
        XCTAssertEqual(CenteredSlice.range(count: 10, selected: 9, capacity: 5), 5..<10)
        XCTAssertEqual(CenteredSlice.range(count: 3, selected: 1, capacity: 5), 0..<3)
        XCTAssertEqual(CenteredSlice.range(count: 0, selected: -1, capacity: 5), 0..<0)
    }

    func testWindowGroupingUsesApplicationAndSpaceOnlyPastThreshold() {
        let windows = [
            window(id: 1, title: "A", app: "Xcode", space: 1),
            window(id: 2, title: "B", app: "Xcode", space: 2),
            window(id: 3, title: "C", app: "Safari", space: 2),
        ]

        let ungrouped = WindowGrouping.groups(windows, threshold: 4)
        XCTAssertEqual(ungrouped.count, 1)
        XCTAssertNil(ungrouped[0].key)

        let grouped = WindowGrouping.groups(windows, threshold: 3)
        XCTAssertEqual(grouped.map(\.key?.applicationName), ["Xcode", "Xcode", "Safari"])
        XCTAssertEqual(grouped.map(\.key?.spaceNumber), [1, 2, 2])
        XCTAssertEqual(grouped.flatMap(\.windows).map(\.id), [1, 2, 3])
    }

    func testDelayCalibrationUsesRoundedClampedEightiethPercentile() {
        var calibration = DelayCalibration(requiredSamples: 10)
        [50, 60, 70, 80, 90, 100, 110, 120, 130, 140].forEach {
            calibration.record(milliseconds: $0)
        }
        XCTAssertTrue(calibration.isComplete)
        XCTAssertEqual(calibration.recommendedMilliseconds, 120)

        var low = DelayCalibration(requiredSamples: 3)
        [1, 7, 12].forEach { low.record(milliseconds: $0) }
        XCTAssertEqual(low.recommendedMilliseconds, 40)

        var high = DelayCalibration(requiredSamples: 3)
        [800, 900, 1_000].forEach { high.record(milliseconds: $0) }
        XCTAssertEqual(high.recommendedMilliseconds, 500)
    }

    func testHoverIntentRequiresStablePointerAndAbandonsContinuousMotion() {
        var stable = HoverIntentTracker(stableRadius: 6, dwell: 0.2, timeout: 1.2)
        XCTAssertEqual(stable.update(candidate: 7, point: .zero, time: 0), .waiting)
        XCTAssertEqual(stable.update(candidate: 7, point: CGPoint(x: 3, y: 2), time: 0.1), .waiting)
        XCTAssertEqual(stable.update(candidate: 7, point: CGPoint(x: 4, y: 1), time: 0.21), .ready)

        var moving = HoverIntentTracker(stableRadius: 6, dwell: 0.2, timeout: 0.5)
        XCTAssertEqual(moving.update(candidate: 8, point: .zero, time: 0), .waiting)
        XCTAssertEqual(moving.update(candidate: 8, point: CGPoint(x: 8, y: 0), time: 0.15), .waiting)
        XCTAssertEqual(moving.update(candidate: 8, point: CGPoint(x: 16, y: 0), time: 0.3), .waiting)
        XCTAssertEqual(moving.update(candidate: 8, point: CGPoint(x: 24, y: 0), time: 0.51), .abandoned)

        XCTAssertEqual(moving.update(candidate: 9, point: .zero, time: 1), .waiting)
    }

    func testQuitConfirmationRequiresSameTargetWithinDeadline() {
        var state = QuitConfirmationState(window: 0.9)
        XCTAssertFalse(state.request(targetPID: 41, time: 10))
        XCTAssertTrue(state.isArmed(for: 41, time: 10.5))
        XCTAssertTrue(state.request(targetPID: 41, time: 10.8))

        XCTAssertFalse(state.request(targetPID: 41, time: 12))
        XCTAssertFalse(state.request(targetPID: 42, time: 12.2))
        XCTAssertFalse(state.isArmed(for: 41, time: 12.2))
        XCTAssertFalse(state.request(targetPID: 42, time: 13.2))
    }

    func testShortcutConflictDetectorFindsInternalAndSystemConflicts() {
        let allWindows = ShortcutBinding(
            id: "all", label: "All windows", modifiers: .option,
            keyCode: KeyCodes.tab, source: .hyperSwitch
        )
        let duplicate = ShortcutBinding(
            id: "current", label: "Current app", modifiers: .option,
            keyCode: KeyCodes.tab, source: .hyperSwitch
        )
        let system = ShortcutBinding(
            id: "system-27", label: "Move focus", modifiers: .option,
            keyCode: KeyCodes.tab, source: .system
        )

        let conflicts = ShortcutConflictDetector.conflicts(
            hyperSwitch: [allWindows, duplicate], system: [system]
        )

        XCTAssertEqual(conflicts.filter { $0.kind == .internalDuplicate }.count, 1)
        XCTAssertEqual(conflicts.filter { $0.kind == .systemOccupied }.count, 2)
        XCTAssertTrue(conflicts.allSatisfy { $0.binding.modifiers == .option })
    }

    func testInteractionStateLayersLatchSearchEscapeAndDelayedHints() {
        var state = SwitcherInteractionState()
        state.markPresented(at: 20)
        state.refreshHints(at: 20.49, enabled: true)
        XCTAssertFalse(state.showsUsageHints)
        state.refreshHints(at: 20.5, enabled: true)
        XCTAssertTrue(state.showsUsageHints)

        XCTAssertTrue(state.toggleLatch(allowed: true))
        XCTAssertTrue(state.isLatched)
        XCTAssertTrue(state.appendSearchText("q", candidateCount: 9, threshold: 9))
        XCTAssertEqual(state.query, "q")
        XCTAssertTrue(state.isSearching)

        XCTAssertEqual(state.escape(), .clearedSearch)
        XCTAssertEqual(state.query, "")
        XCTAssertFalse(state.isSearching)
        XCTAssertEqual(state.escape(), .cancelSession)

        state.reset()
        XCTAssertFalse(state.appendSearchText("x", candidateCount: 20, threshold: 9))
        XCTAssertFalse(state.toggleLatch(allowed: false))
        XCTAssertFalse(state.showsUsageHints)
    }

    func testExplicitSlashStartsSearchWithoutBecomingQuery() {
        var state = SwitcherInteractionState()
        XCTAssertTrue(state.toggleLatch(allowed: true))
        XCTAssertFalse(state.beginSearch(candidateCount: 1, threshold: 9))
        XCTAssertTrue(state.beginSearch(candidateCount: 1, threshold: 9, explicit: true))
        XCTAssertTrue(state.isSearching)
        XCTAssertEqual(state.query, "")
        XCTAssertTrue(state.appendSearchText("Window", candidateCount: 12, threshold: 9))
        state.deleteSearchCharacter()
        XCTAssertEqual(state.query, "Windo")
        XCTAssertTrue(state.appendSearchText("w", candidateCount: 1, threshold: 9))
        XCTAssertEqual(state.query, "Window")
        for _ in 0..<6 { state.deleteSearchCharacter() }
        XCTAssertEqual(state.query, "")
        XCTAssertFalse(state.isSearching)
    }

    /// Escape inside an explicitly opened, still-empty search backs out of the search,
    /// not out of the whole session.
    func testEscapeInAnEmptySearchOnlyLeavesTheSearch() {
        var state = SwitcherInteractionState()
        XCTAssertTrue(state.toggleLatch(allowed: true))
        XCTAssertTrue(state.beginSearch(candidateCount: 1, threshold: 9, explicit: true))

        XCTAssertEqual(state.escape(), .clearedSearch)
        XCTAssertFalse(state.isSearching)
        XCTAssertTrue(state.isLatched)
        XCTAssertEqual(state.escape(), .cancelSession)
    }

    /// Tab, Return and Escape arrive with text attached. None of it may open search: a
    /// silently opened search is what stopped Space unlatching and Return committing.
    func testControlAndFunctionKeyTextNeverOpensSearch() {
        var state = SwitcherInteractionState()
        XCTAssertTrue(state.toggleLatch(allowed: true))

        for text in ["\t", "\r", "\u{1B}", "\u{7F}", "\u{F702}", "\u{F700}"] {
            XCTAssertFalse(state.appendSearchText(text, candidateCount: 50, threshold: 9),
                           "\(text.unicodeScalars.map(\.value))")
            XCTAssertFalse(state.isSearching)
            XCTAssertEqual(state.query, "")
        }

        XCTAssertTrue(state.appendSearchText("a", candidateCount: 50, threshold: 9))
        XCTAssertEqual(state.query, "a")
    }

    /// Movement repeats; decisions do not. Holding Q used to answer its own quit
    /// confirmation, holding Space flipped the latch, holding W closed window after window.
    func testOnlyMovementAndSearchTypingRepeat() {
        let cycle = Int(KeyCodes.graveAccent)
        for key in [KeyCodes.tab, KeyCodes.leftArrow, KeyCodes.rightArrow,
                    KeyCodes.upArrow, KeyCodes.downArrow, KeyCodes.graveAccent] {
            XCTAssertTrue(SessionKeyRepeat.honours(keyCode: key, cycleKey: cycle,
                                                   isSearching: false), "\(key)")
        }
        for key in [KeyCodes.q, KeyCodes.w, KeyCodes.space, KeyCodes.escape,
                    KeyCodes.returnKey, KeyCodes.slash, KeyCodes.delete] {
            XCTAssertFalse(SessionKeyRepeat.honours(keyCode: key, cycleKey: cycle,
                                                    isSearching: false), "\(key)")
        }

        // Typing into the search field repeats like any other text field…
        XCTAssertTrue(SessionKeyRepeat.honours(keyCode: KeyCodes.q, cycleKey: cycle,
                                               isSearching: true))
        XCTAssertTrue(SessionKeyRepeat.honours(keyCode: KeyCodes.delete, cycleKey: cycle,
                                               isSearching: true))
        // …but Escape still backs out one level per press.
        XCTAssertFalse(SessionKeyRepeat.honours(keyCode: KeyCodes.escape, cycleKey: cycle,
                                                isSearching: true))

        // A cycle key bound to W steps, so its repeats are movement too.
        XCTAssertTrue(SessionKeyRepeat.honours(keyCode: KeyCodes.w, cycleKey: Int(KeyCodes.w),
                                               isSearching: false))
    }

    func testEscapeSpaceAndReturnCannotBeTheCycleKey() {
        XCTAssertFalse(KeyCodes.isUsableAsCycleKey(Int(KeyCodes.escape)))
        XCTAssertFalse(KeyCodes.isUsableAsCycleKey(Int(KeyCodes.space)))
        XCTAssertFalse(KeyCodes.isUsableAsCycleKey(Int(KeyCodes.returnKey)))
        XCTAssertTrue(KeyCodes.isUsableAsCycleKey(Int(KeyCodes.graveAccent)))
        XCTAssertTrue(KeyCodes.isUsableAsCycleKey(Int(KeyCodes.w)))
        XCTAssertFalse(KeyCodes.selectable.contains { !KeyCodes.isUsableAsCycleKey(Int($0.code)) },
                       "the picker must not offer a key the switcher cannot use")
    }

    func testPermissionLaunchPolicyNeverPromptsAndSuppressesTestUI() {
        XCTAssertEqual(
            PermissionLaunchPolicy.action(
                hasAccessibility: false,
                hasShownIntroduction: false,
                isRunningTests: false
            ),
            .showIntroduction
        )
        XCTAssertEqual(
            PermissionLaunchPolicy.action(
                hasAccessibility: false,
                hasShownIntroduction: false,
                isRunningTests: true
            ),
            .none
        )
        XCTAssertEqual(
            PermissionLaunchPolicy.action(
                hasAccessibility: false,
                hasShownIntroduction: true,
                isRunningTests: false
            ),
            .none
        )
        XCTAssertEqual(
            PermissionLaunchPolicy.action(
                hasAccessibility: true,
                hasShownIntroduction: false,
                isRunningTests: false
            ),
            .none
        )
    }

    private func window(id: CGWindowID, title: String, app: String, space: Int?) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid_t(id + 100),
            title: title,
            applicationName: app,
            bundleIdentifier: "test.\(app)",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            spaceNumber: space,
            isOnCurrentSpace: space == 1,
            isMinimized: false,
            isApplicationHidden: false,
            isOnScreen: true
        )
    }
}
