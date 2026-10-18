import CoreGraphics
import XCTest
@testable import HyperSwitch

/// The window-list judgements that decide what the switcher offers and what counts as
/// "this application has a window". Each one is a rule about measured window-server
/// behaviour, so each is pinned against plain values rather than a live listing.
nonisolated final class WindowEvidenceTests: XCTestCase {

    // MARK: - Titles

    /// The live title is as current as the query; the cache can be seconds behind.
    func testTheLiveTitleWinsOverTheCache() {
        XCTAssertEqual(WindowIndex.title(live: "Inbox (3)", cached: "Inbox (2)"), "Inbox (3)")
    }

    /// Without Screen Recording the live title is empty, and the cache is all there is.
    func testTheCacheFillsInWhenThereIsNoLiveTitle() {
        XCTAssertEqual(WindowIndex.title(live: "", cached: "Inbox"), "Inbox")
        XCTAssertEqual(WindowIndex.title(live: nil, cached: "Inbox"), "Inbox")
        XCTAssertEqual(WindowIndex.title(live: nil, cached: nil), "")
    }

    // MARK: - Closed windows

    /// The reported case: three windows on screen, two minimised, and an answer that
    /// lists only the three it is showing. A count comparison trusted it (3 >= 2) and
    /// deleted both real minimised windows.
    func testAnAnswerThatVendsNoOffScreenWindowIsNotTrusted() {
        XCTAssertFalse(ClosedWindowEvidence.isTrustworthy(vended: [1, 2, 3],
                                                          visible: [1, 2, 3],
                                                          suspects: [4, 5]))
    }

    /// Missing a window the user can see is a partial answer, whatever else it lists.
    func testAnAnswerMissingAVisibleWindowIsNotTrusted() {
        XCTAssertFalse(ClosedWindowEvidence.isTrustworthy(vended: [2, 4],
                                                          visible: [1, 2],
                                                          suspects: [4, 5]))
    }

    /// Complete for what is visible, and proven to report off-screen windows: the one
    /// doubted window it leaves out is the one that closed.
    func testACompleteAnswerIsTrusted() {
        XCTAssertTrue(ClosedWindowEvidence.isTrustworthy(vended: [1, 4],
                                                         visible: [1],
                                                         suspects: [4, 5]))
    }

    // MARK: - "Has a window"

    private func entry(pid: pid_t = 42, id: CGWindowID = 7, layer: Int = 0,
                       width: CGFloat = 500, height: CGFloat = 500,
                       onScreen: Bool? = nil, alpha: Double? = 1) -> [String: Any] {
        var entry: [String: Any] = [
            kCGWindowOwnerPID as String: pid,
            kCGWindowNumber as String: id,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: ["X": CGFloat(0), "Y": CGFloat(0),
                                        "Width": width, "Height": height],
        ]
        if let onScreen { entry[kCGWindowIsOnscreen as String] = onScreen }
        if let alpha { entry[kCGWindowAlpha as String] = alpha }
        return entry
    }

    /// The 500×500 window an application built and never ordered in: above the size
    /// floor, off screen, on no Space. It is not a window the user has.
    func testANeverShownWindowDoesNotCount() {
        XCTAssertFalse(WindowActions.countsAsWindow(entry(), of: 42) { _ in false })
    }

    func testMinimisedAndOtherSpaceWindowsStillCount() {
        XCTAssertTrue(WindowActions.countsAsWindow(entry(), of: 42) { _ in true })
        XCTAssertTrue(WindowActions.countsAsWindow(entry(onScreen: true), of: 42) { _ in false })
    }

    func testStripsTransparentWindowsAndOtherOwnersDoNotCount() {
        XCTAssertFalse(WindowActions.countsAsWindow(entry(width: 2056, height: 39, onScreen: true),
                                                    of: 42) { _ in true })
        XCTAssertFalse(WindowActions.countsAsWindow(entry(onScreen: true, alpha: 0),
                                                    of: 42) { _ in true })
        XCTAssertFalse(WindowActions.countsAsWindow(entry(layer: 3, onScreen: true),
                                                    of: 42) { _ in true })
        XCTAssertFalse(WindowActions.countsAsWindow(entry(pid: 9, onScreen: true),
                                                    of: 42) { _ in true })
    }
}
