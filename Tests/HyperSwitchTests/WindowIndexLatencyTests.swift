import XCTest
@testable import HyperSwitch

nonisolated final class WindowIndexLatencyTests: XCTestCase {
    func testWindowQueryDoesNotWaitForTitleRefresh() async {
        let index = WindowIndex(titleLoader: {
            try await Task.sleep(for: .milliseconds(600))
            return [:]
        })
        let query = WindowQuery(
            includeOtherSpaces: false,
            includeOtherScreens: true,
            includeMinimized: false,
            screenFrame: nil
        )

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            _ = await index.windowCounts(query)
        }

        XCTAssertLessThan(
            elapsed,
            Duration.milliseconds(250),
            "Window enumeration must not wait for the slower ScreenCaptureKit title refresh"
        )
    }
}
