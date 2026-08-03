import CoreGraphics
import XCTest
@testable import HyperSwitch

/// The keyboard policy, which now runs on the tap's own thread and therefore cannot be
/// inspected by looking at the app while it runs.
///
/// Worth testing at this level precisely because of what it decides: `swallow` is the
/// difference between the system's ⌘Tab appearing and not appearing, and a wrong `pass`
/// leaks a keystroke into whatever application is underneath the panel.
nonisolated final class HotKeyPolicyTests: XCTestCase {

    // MARK: - Activation

    func testCommandTabOpensTheAppSwitcherAndIsSwallowed() {
        let decision = decide(.keyDown, key: KeyCodes.tab, flags: [.maskCommand],
                              state: HotKeySnapshot())

        XCTAssertTrue(decision.swallow)
        XCTAssertEqual(decision.action,
                       .begin(mode: .appSwitcher, modifier: .command, backwards: false))
        XCTAssertEqual(decision.edit, .beginSession(.command))
    }

    func testShiftCommandTabOpensBackwardsRegardlessOfThePreference() {
        var state = HotKeySnapshot()
        state.shiftCyclesBackwards = false

        let decision = decide(.keyDown, key: KeyCodes.tab,
                              flags: [.maskCommand, .maskShift], state: state)

        XCTAssertEqual(decision.action,
                       .begin(mode: .appSwitcher, modifier: .command, backwards: true))
    }

    /// The promise the settings pane makes: with previews off, ⌘Tab belongs to macOS. This
    /// is the one path on which passing the key through is the *correct* answer.
    func testCommandTabIsLeftToTheSystemWhenPreviewsAreOff() {
        var state = HotKeySnapshot()
        state.appSwitcherPreviewsEnabled = false

        let decision = decide(.keyDown, key: KeyCodes.tab, flags: [.maskCommand], state: state)

        XCTAssertFalse(decision.swallow)
        XCTAssertNil(decision.action)
    }

    func testOptionTabOpensTheWindowSwitcher() {
        let decision = decide(.keyDown, key: KeyCodes.tab, flags: [.maskAlternate],
                              state: HotKeySnapshot())

        XCTAssertTrue(decision.swallow)
        XCTAssertEqual(decision.action,
                       .begin(mode: .allWindows, modifier: .option, backwards: false))
    }

    func testDisabledSwitchersDoNotClaimTheirKeys() {
        var state = HotKeySnapshot()
        state.windowSwitcherEnabled = false
        state.currentAppSwitcherEnabled = false

        XCTAssertEqual(decide(.keyDown, key: KeyCodes.tab, flags: [.maskAlternate],
                              state: state), .pass)
        XCTAssertEqual(decide(.keyDown, key: KeyCodes.graveAccent, flags: [.maskAlternate],
                              state: state), .pass)
    }

    // MARK: - Inside a session

    func testEveryKeyIsSwallowedWhileASessionIsOpen() {
        let decision = decide(.keyDown, key: KeyCodes.q, flags: [.maskAlternate],
                              state: openSession(modifier: .option))

        XCTAssertTrue(decision.swallow)
        XCTAssertEqual(decision.action,
                       .sessionKey(keyCode: KeyCodes.q, flags: [.maskAlternate], text: ""))
        XCTAssertEqual(decision.edit, .none)
    }

    /// The keyboard-goes-dead case. If the modifier that opened the session is missing from
    /// an incoming key, its release was never delivered, and swallowing from here on would
    /// eat everything the user types.
    func testAKeyArrivingWithoutTheSessionModifierEndsTheSessionAndPassesThrough() {
        let decision = decide(.keyDown, key: KeyCodes.w, flags: [],
                              state: openSession(modifier: .option))

        XCTAssertFalse(decision.swallow)
        XCTAssertEqual(decision.action, .cancel)
        XCTAssertEqual(decision.edit, .endSession)
    }

    /// A latched session survives its modifier being released, so the rule above must not
    /// apply to it — otherwise the first key typed into the search field closes the panel.
    func testALatchedSessionKeepsSwallowingWithoutItsModifier() {
        var state = openSession(modifier: .option)
        state.isLatched = true

        let decision = decide(.keyDown, key: KeyCodes.w, flags: [], text: "w", state: state)

        XCTAssertTrue(decision.swallow)
        XCTAssertEqual(decision.action,
                       .sessionKey(keyCode: KeyCodes.w, flags: [], text: "w"))
    }

    /// ⌥ is still held — the user reached for ⌘ without letting go — so the flags carry
    /// both. That is what makes this the ⌘Tab case rather than the missing-modifier one.
    func testCommandTabOutranksAnOpenOptionTabSession() {
        let decision = decide(.keyDown, key: KeyCodes.tab,
                              flags: [.maskAlternate, .maskCommand],
                              state: openSession(modifier: .option))

        XCTAssertTrue(decision.swallow)
        XCTAssertEqual(decision.action,
                       .begin(mode: .appSwitcher, modifier: .command, backwards: false))
        XCTAssertEqual(decision.edit, .beginSession(.command))
    }

    /// Same keystroke, previews off: the session has to be retired *and* the key handed to
    /// macOS. Swallowing it here is what made "⌘Tab belongs to the system" untrue for as
    /// long as any session happened to be open.
    func testCommandTabDuringASessionGoesToTheSystemWhenPreviewsAreOff() {
        var state = openSession(modifier: .option)
        state.appSwitcherPreviewsEnabled = false

        let decision = decide(.keyDown, key: KeyCodes.tab,
                              flags: [.maskAlternate, .maskCommand], state: state)

        XCTAssertFalse(decision.swallow)
        XCTAssertEqual(decision.action, .cancel)
        XCTAssertEqual(decision.edit, .endSession)
    }

    func testTabInsideACommandTabSessionKeepsStepping() {
        let decision = decide(.keyDown, key: KeyCodes.tab, flags: [.maskCommand],
                              state: openSession(modifier: .command))

        XCTAssertEqual(decision.action,
                       .sessionKey(keyCode: KeyCodes.tab, flags: [.maskCommand], text: ""))
    }

    // MARK: - Modifier release

    func testReleasingTheModifierCommitsAndEndsTheSession() {
        let decision = decide(.flagsChanged, key: 0, flags: [],
                              state: openSession(modifier: .option))

        XCTAssertTrue(decision.swallow)
        XCTAssertEqual(decision.action, .commitAndClearModifier(.option))
        XCTAssertEqual(decision.edit, .endSession)
    }

    func testHoldingTheModifierChangesNothing() {
        let decision = decide(.flagsChanged, key: 0, flags: [.maskAlternate],
                              state: openSession(modifier: .option))

        XCTAssertEqual(decision, .pass)
    }

    func testALatchedSessionOnlyClearsTheModifierState() {
        var state = openSession(modifier: .option)
        state.isLatched = true

        let decision = decide(.flagsChanged, key: 0, flags: [], state: state)

        XCTAssertTrue(decision.swallow)
        XCTAssertEqual(decision.action, .clearModifier(.option))
        XCTAssertEqual(decision.edit, .none, "a latch is what keeps the session alive")
    }

    func testNoSessionMeansModifierChangesAreNotOurs() {
        XCTAssertEqual(decide(.flagsChanged, key: 0, flags: [], state: HotKeySnapshot()), .pass)
    }

    // MARK: - Delay calibration

    func testCalibrationClaimsTheTriggerAndTheRelease() {
        var state = HotKeySnapshot()
        state.isCalibrating = true

        let trigger = decide(.keyDown, key: KeyCodes.tab, flags: [.maskAlternate],
                             timestamp: 1_000, state: state)
        XCTAssertTrue(trigger.swallow)
        XCTAssertEqual(trigger.action, .calibrationTrigger(timestamp: 1_000))

        state.isMeasuring = true
        let release = decide(.flagsChanged, key: 0, flags: [], timestamp: 2_000, state: state)
        XCTAssertTrue(release.swallow)
        XCTAssertEqual(release.action,
                       .calibrationRelease(timestamp: 2_000, modifier: .option))
    }

    /// Calibration must not begin measuring from a release it never saw the start of.
    func testCalibrationIgnoresAReleaseItIsNotMeasuring() {
        var state = HotKeySnapshot()
        state.isCalibrating = true
        state.isMeasuring = false

        XCTAssertEqual(decide(.flagsChanged, key: 0, flags: [], state: state), .pass)
    }

    // MARK: - The tap's own backstop

    /// What stands in for the property that moving off the main thread gave up: a wedged
    /// main actor used to get the tap disabled by the WindowServer, which handed the
    /// keyboard back. Now nothing external will, so the policy has to.
    func testASessionNothingEverClosedStopsSwallowing() {
        var state = openSession(modifier: .option)
        state.sessionOpenedAt = ProcessInfo.processInfo.systemUptime - 31

        let decision = decide(.keyDown, key: KeyCodes.tab, flags: [.maskAlternate],
                              state: state)

        XCTAssertFalse(decision.swallow, "the keyboard has to come back")
        XCTAssertEqual(decision.action, .cancel)
        XCTAssertEqual(decision.edit, .endSession)
    }

    /// A latched session is one the user is deliberately keeping open, so 30 s is far too
    /// tight for it — it gets the controller's own absolute ceiling instead.
    func testALatchedSessionIsGivenMuchLonger() {
        var state = openSession(modifier: .option)
        state.isLatched = true
        state.sessionOpenedAt = ProcessInfo.processInfo.systemUptime - 60

        let decision = decide(.keyDown, key: KeyCodes.tab, flags: [], text: "", state: state)

        XCTAssertTrue(decision.swallow)
        XCTAssertEqual(decision.action,
                       .sessionKey(keyCode: KeyCodes.tab, flags: [], text: ""))
    }

    func testAFreshSessionIsNotAffectedByTheBackstop() {
        var state = openSession(modifier: .option)
        state.sessionOpenedAt = ProcessInfo.processInfo.systemUptime

        let decision = decide(.keyDown, key: KeyCodes.tab, flags: [.maskAlternate],
                              state: state)

        XCTAssertTrue(decision.swallow)
    }

    // MARK: - The optimistic edit

    /// The reason the edit exists: ⌘Tab⇥⇥ arrives faster than the main actor is scheduled,
    /// so the second Tab has to see a session that the first one has not yet actually
    /// opened. Without this the second press re-triggers instead of stepping.
    func testBeginningASessionInTheStoreMakesTheNextKeyASessionKey() {
        let store = HotKeyState.shared
        defer { store.apply(.endSession) }

        store.apply(.beginSession(.command))

        let snapshot = store.current
        XCTAssertTrue(snapshot.isActive)
        XCTAssertEqual(snapshot.activeModifier, .command)
        XCTAssertFalse(snapshot.isLatched)

        let decision = decide(.keyDown, key: KeyCodes.tab, flags: [.maskCommand],
                              state: snapshot)
        XCTAssertEqual(decision.action,
                       .sessionKey(keyCode: KeyCodes.tab, flags: [.maskCommand], text: ""))
    }

    func testEndingASessionInTheStoreClearsTheModifierAndLatch() {
        let store = HotKeyState.shared
        store.apply(.beginSession(.option))
        store.apply(.endSession)

        let snapshot = store.current
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.activeModifier, [])
        XCTAssertFalse(snapshot.isLatched)
    }

    // MARK: - Helpers

    private func openSession(modifier: ModifierCombo) -> HotKeySnapshot {
        var state = HotKeySnapshot()
        state.isActive = true
        state.activeModifier = modifier
        return state
    }

    private func decide(_ type: CGEventType,
                        key: CGKeyCode,
                        flags: CGEventFlags,
                        text: String = "",
                        timestamp: UInt64 = 0,
                        state: HotKeySnapshot) -> HotKeyDecision {
        HotKeyPolicy.decide(type: type, keyCode: key, flags: flags,
                            text: text, timestamp: timestamp, state: state)
    }
}
