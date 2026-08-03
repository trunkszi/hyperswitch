import CoreGraphics
import Foundation

/// Everything the tap callback needs in order to answer "swallow or pass", in a form that
/// can be read from a thread that is not the main one.
///
/// This exists because of where the tap now runs. A `CGEventTap` callback has a hard budget
/// — measured on this machine at exactly 1.000 s — and the WindowServer disables any tap
/// that overruns it. While the tap's run loop source lived on the main thread, "overran"
/// did not mean "the callback was slow"; it meant "the main thread was busy", and the
/// switcher's own full-size hover preview is more than capable of making it busy: an ~8 MB
/// capture landing on the main actor triggers a synchronous SwiftUI layout pass through
/// `NSHostingView.layoutSubtreeIfNeeded`. The tap was collateral damage of the app's own
/// rendering, and every disabled tap is a window in which ⌘Tab reaches the system.
///
/// Moving the tap to its own thread fixes that only if the callback can decide without
/// touching main-actor state. Hence a snapshot: the main actor writes it whenever anything
/// in it changes, and the tap thread reads a consistent copy under a lock.
nonisolated struct HotKeySnapshot: Sendable, Equatable {

    // MARK: Session

    var isActive = false
    var activeModifier: ModifierCombo = []
    var isLatched = false

    /// `ProcessInfo.systemUptime` when the session opened, for ``HotKeyPolicy``'s own
    /// backstop. See ``HotKeyPolicy/sessionHasOutlivedItsWelcome(_:)``.
    var sessionOpenedAt: TimeInterval?

    // MARK: Delay calibration

    var isCalibrating = false
    var isMeasuring = false

    // MARK: Preferences

    var appSwitcherPreviewsEnabled = true
    var windowSwitcherEnabled = true
    var windowSwitcherModifier: ModifierCombo = .option
    var currentAppSwitcherEnabled = true
    var currentAppSwitcherKeyCode = Int(KeyCodes.graveAccent)
    var currentAppSwitcherModifier: ModifierCombo = .option
    var shiftCyclesBackwards = false
}

/// The main-actor work a keystroke asks for, named rather than performed.
///
/// The tap thread produces one of these and hands it to the main actor. Nothing here
/// carries a reference — only value types — so there is no object whose isolation the
/// callback would have to violate to build it.
nonisolated enum HotKeyAction: Sendable, Equatable {
    case begin(mode: SwitcherMode, modifier: ModifierCombo, backwards: Bool)
    /// A key pressed while a session is open. The main actor owns what it means.
    case sessionKey(keyCode: CGKeyCode, flags: CGEventFlags, text: String)
    /// The modifier that opened the session was released: commit, then tell the front
    /// application the modifier is no longer held.
    case commitAndClearModifier(ModifierCombo)
    /// Latched sessions survive the release, but the world still has to be told about it.
    case clearModifier(ModifierCombo)
    case cancel
    case calibrationTrigger(timestamp: UInt64)
    case calibrationRelease(timestamp: UInt64, modifier: ModifierCombo)
}

/// How the snapshot must change *before* the action it accompanies has run.
///
/// The reason this cannot wait for the main actor: the keystrokes that matter arrive
/// milliseconds apart. ⌘Tab⇥⇥⇥ is four events, and if the second one is decided against a
/// snapshot that still says "no session" — because the main actor has not got round to
/// `begin` yet — it is treated as a fresh trigger rather than as a step, and the selection
/// resets on every press. So the tap thread applies the session-level consequence of its own
/// decision immediately, and the main actor re-publishes the full truth once it has caught
/// up.
nonisolated enum HotKeyStateEdit: Sendable, Equatable {
    case none
    case beginSession(ModifierCombo)
    case endSession
}

nonisolated struct HotKeyDecision: Sendable, Equatable {
    /// True to consume the event so nothing downstream — including the system's own ⌘Tab —
    /// ever sees it.
    var swallow: Bool
    var action: HotKeyAction?
    var edit: HotKeyStateEdit = .none

    static let pass = HotKeyDecision(swallow: false, action: nil, edit: .none)
}

/// The whole keyboard policy, as a pure function of one event and one snapshot.
///
/// Pure on purpose: this is the code that runs inside the tap's budget, and being a
/// function of its arguments is what makes it both fast and testable without a running
/// WindowServer.
nonisolated enum HotKeyPolicy {

    /// A session this old cannot be one a person is still holding a modifier down for.
    ///
    /// Moving the tap off the main thread removed a safety property nobody had asked for
    /// and everybody relied on: while the callback lived on the main run loop, a wedged main
    /// thread got the tap disabled by the WindowServer, and a disabled tap passes keystrokes
    /// through. The keyboard kept working. Now the tap is independent, so a main actor that
    /// never finishes leaves it swallowing every key against a snapshot that says a session
    /// is open — a genuinely dead keyboard, with no panel on screen to explain it.
    ///
    /// So the tap keeps its own clock. `SwitcherController`'s watchdog cancels an idle
    /// session after 20 s and any session after 300 s; these are looser than both, because
    /// this is not a second watchdog — it is the thing that runs when the first one cannot.
    private static let unlatchedSessionCeiling: TimeInterval = 30
    private static let latchedSessionCeiling: TimeInterval = 300

    private static func sessionHasOutlivedItsWelcome(_ state: HotKeySnapshot) -> Bool {
        guard state.isActive, let opened = state.sessionOpenedAt else { return false }
        let ceiling = state.isLatched ? latchedSessionCeiling : unlatchedSessionCeiling
        return ProcessInfo.processInfo.systemUptime - opened > ceiling
    }

    static func decide(type: CGEventType,
                       keyCode: CGKeyCode,
                       flags: CGEventFlags,
                       text: String,
                       timestamp: UInt64,
                       state: HotKeySnapshot) -> HotKeyDecision {
        // Ahead of everything, including the calibration branches: whatever this session
        // was for, nothing is coming to end it, and the keyboard has to be handed back.
        if sessionHasOutlivedItsWelcome(state) {
            return HotKeyDecision(swallow: false, action: .cancel, edit: .endSession)
        }

        switch type {
        case .flagsChanged:
            return state.isCalibrating
                ? calibrationFlags(flags: flags, timestamp: timestamp, state: state)
                : flagsChanged(flags: flags, state: state)

        case .keyDown:
            if state.isCalibrating {
                return calibrationKey(keyCode: keyCode, flags: flags,
                                      timestamp: timestamp, state: state)
            }
            return state.isActive
                ? sessionKey(keyCode: keyCode, flags: flags, text: text, state: state)
                : trigger(keyCode: keyCode, flags: flags, state: state)

        default:
            return .pass
        }
    }

    // MARK: - Modifier release

    /// Releasing the modifier that started the session is what commits it — the same
    /// gesture as the system's own ⌘Tab.
    private static func flagsChanged(flags: CGEventFlags,
                                     state: HotKeySnapshot) -> HotKeyDecision {
        guard state.isActive else { return .pass }

        // An empty combo means the session was opened without a modifier to hold, so there
        // is nothing whose release could end it. Every shipping caller passes a real one;
        // the guard exists because `isSatisfied(by:)` answers false for an empty combo,
        // which would otherwise read as "already released" and close such a session on the
        // very next flagsChanged.
        let modifier = state.activeModifier
        guard !modifier.isEmpty else { return .pass }
        guard !modifier.isSatisfied(by: flags) else { return .pass }

        if state.isLatched {
            return HotKeyDecision(swallow: true, action: .clearModifier(modifier))
        }
        return HotKeyDecision(swallow: true,
                              action: .commitAndClearModifier(modifier),
                              edit: .endSession)
    }

    // MARK: - Activation

    /// Matches a keystroke against the three configured hotkeys. Order is priority.
    private static func trigger(keyCode: CGKeyCode,
                                flags: CGEventFlags,
                                state: HotKeySnapshot) -> HotKeyDecision {
        // ⌘Tab is checked first and its modifier is hard-coded rather than read from
        // preferences, because it is not ours to configure — it is the system binding we
        // are displacing. The order matters for a real configuration, not a hypothetical
        // one: with the all-windows switcher also set to ⌘, ⌘Tab satisfies both rules, and
        // whichever is tested first wins. Losing the app switcher to it would be the
        // surprising outcome.
        if state.appSwitcherPreviewsEnabled,
           keyCode == KeyCodes.tab,
           flags.contains(.maskCommand) {
            // Shift is unconditionally backwards here, ignoring shiftCyclesBackwards:
            // ⇧⌘Tab has meant "previous application" since long before this app existed,
            // and a preference that broke it would just read as a bug.
            return HotKeyDecision(
                swallow: true,
                action: .begin(mode: .appSwitcher, modifier: .command,
                               backwards: flags.contains(.maskShift)),
                edit: .beginSession(.command)
            )
        }

        if state.windowSwitcherEnabled,
           keyCode == KeyCodes.tab,
           state.windowSwitcherModifier.isSatisfied(by: flags) {
            return HotKeyDecision(
                swallow: true,
                action: .begin(mode: .allWindows,
                               modifier: state.windowSwitcherModifier,
                               backwards: isBackwards(flags, state)),
                edit: .beginSession(state.windowSwitcherModifier)
            )
        }

        if state.currentAppSwitcherEnabled,
           Int(keyCode) == state.currentAppSwitcherKeyCode,
           state.currentAppSwitcherModifier.isSatisfied(by: flags) {
            return HotKeyDecision(
                swallow: true,
                action: .begin(mode: .currentApp,
                               modifier: state.currentAppSwitcherModifier,
                               backwards: isBackwards(flags, state)),
                edit: .beginSession(state.currentAppSwitcherModifier)
            )
        }

        return .pass
    }

    /// Shift only reverses the opening direction when the user asked it to; otherwise the
    /// binding is free to be, say, ⌥⇧Tab without inverting itself.
    private static func isBackwards(_ flags: CGEventFlags, _ state: HotKeySnapshot) -> Bool {
        state.shiftCyclesBackwards && flags.contains(.maskShift)
    }

    // MARK: - Keys during a session

    /// Every key is swallowed while the panel is up, whether or not it means anything.
    ///
    /// The panel is a non-activating window, so the frontmost application is still
    /// technically the key window and would receive anything we let past — typing into a
    /// document the user is not looking at, or worse, triggering one of its shortcuts with
    /// the switcher modifier still held. Consuming the lot is the only behaviour that
    /// matches what the user believes is happening.
    ///
    /// Which is why only the two escapes below need deciding here: everything else is a
    /// swallow, and *what* it does is the main actor's business.
    private static func sessionKey(keyCode: CGKeyCode,
                                   flags: CGEventFlags,
                                   text: String,
                                   state: HotKeySnapshot) -> HotKeyDecision {
        // Second line of defence behind the controller's watchdog. If the modifier that
        // opened this session is no longer in the incoming event's flags, the release went
        // missing — Mission Control, a Space switch and the lock screen all cause it — and
        // swallowing this key would be the start of a dead keyboard. End the session and
        // let the keystroke through to whatever the user is actually typing into.
        let modifier = state.activeModifier
        if !state.isLatched, !modifier.isEmpty, !modifier.isSatisfied(by: flags) {
            return HotKeyDecision(swallow: false, action: .cancel, edit: .endSession)
        }

        // ⌘Tab is the system binding we are displacing, so it has to outrank a session that
        // merely happens to be open. Under the blanket swallow described above, ⌘Tab pressed
        // during an ⌥Tab session opened neither switcher — not ours, because `trigger` is
        // consulted only when no session is running, and not the system's, because we ate
        // the keystroke. It read as a plain Tab, and the release then committed a window
        // raise where the user had asked to change application.
        //
        // Gated on the *session's* modifier not already containing ⌘ so that Tab inside a
        // ⌘Tab session keeps stepping.
        if keyCode == KeyCodes.tab,
           flags.contains(.maskCommand),
           !modifier.contains(.command) {
            guard state.appSwitcherPreviewsEnabled else {
                // With previews off, ⌘Tab belongs to the system. Retire our session and let
                // the key through rather than swallowing it, which is what made that promise
                // untrue for as long as any session was open.
                return HotKeyDecision(swallow: false, action: .cancel, edit: .endSession)
            }
            return HotKeyDecision(
                swallow: true,
                action: .begin(mode: .appSwitcher, modifier: .command,
                               backwards: flags.contains(.maskShift)),
                edit: .beginSession(.command)
            )
        }

        return HotKeyDecision(
            swallow: true,
            action: .sessionKey(keyCode: keyCode, flags: flags, text: text)
        )
    }

    // MARK: - Delay calibration

    private static func calibrationKey(keyCode: CGKeyCode,
                                       flags: CGEventFlags,
                                       timestamp: UInt64,
                                       state: HotKeySnapshot) -> HotKeyDecision {
        guard keyCode == KeyCodes.tab,
              state.windowSwitcherModifier.isSatisfied(by: flags)
        else { return .pass }
        return HotKeyDecision(swallow: true, action: .calibrationTrigger(timestamp: timestamp))
    }

    private static func calibrationFlags(flags: CGEventFlags,
                                         timestamp: UInt64,
                                         state: HotKeySnapshot) -> HotKeyDecision {
        guard state.isMeasuring else { return .pass }
        let modifier = state.windowSwitcherModifier
        guard !modifier.isSatisfied(by: flags) else { return .pass }
        return HotKeyDecision(
            swallow: true,
            action: .calibrationRelease(timestamp: timestamp, modifier: modifier)
        )
    }
}

/// The one copy of ``HotKeySnapshot`` the tap thread reads and the main actor writes.
///
/// A lock rather than an actor: the reader is a `CGEventTap` callback with a one-second
/// budget and no way to `await` anything. The critical sections are a struct copy either
/// way, which is a few dozen bytes.
nonisolated final class HotKeyState: @unchecked Sendable {
    static let shared = HotKeyState()

    private let lock = NSLock()
    private var snapshot = HotKeySnapshot()

    private init() {}

    var current: HotKeySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Applies the tap thread's own optimistic edit. See ``HotKeyStateEdit``.
    func apply(_ edit: HotKeyStateEdit) {
        guard edit != .none else { return }
        lock.lock()
        defer { lock.unlock() }
        switch edit {
        case .none:
            break
        case .beginSession(let modifier):
            snapshot.isActive = true
            snapshot.activeModifier = modifier
            // A new session is never latched, and carrying the previous one's latch over
            // would leave the tap believing the modifier release does not end it.
            snapshot.isLatched = false
            snapshot.sessionOpenedAt = ProcessInfo.processInfo.systemUptime
        case .endSession:
            snapshot.isActive = false
            snapshot.activeModifier = []
            snapshot.isLatched = false
            snapshot.sessionOpenedAt = nil
        }
    }

    /// The main actor's authoritative write. Called after anything that could change what
    /// the tap decides with.
    func publish(session: (isActive: Bool, modifier: ModifierCombo, isLatched: Bool)? = nil,
                 calibration: (isCalibrating: Bool, isMeasuring: Bool)? = nil,
                 preferences: HotKeyPreferenceSnapshot? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            snapshot.isActive = session.isActive
            snapshot.activeModifier = session.modifier
            snapshot.isLatched = session.isLatched
            // Stamped only on the transition into a session, so the ceiling keeps measuring
            // from when it opened. Re-stamping on every publish would let a session that
            // simply receives keystrokes renew its own backstop indefinitely — which is
            // precisely the failure it exists to catch.
            if !session.isActive {
                snapshot.sessionOpenedAt = nil
            } else if snapshot.sessionOpenedAt == nil {
                snapshot.sessionOpenedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        if let calibration {
            snapshot.isCalibrating = calibration.isCalibrating
            snapshot.isMeasuring = calibration.isMeasuring
        }
        if let preferences {
            snapshot.appSwitcherPreviewsEnabled = preferences.appSwitcherPreviewsEnabled
            snapshot.windowSwitcherEnabled = preferences.windowSwitcherEnabled
            snapshot.windowSwitcherModifier = preferences.windowSwitcherModifier
            snapshot.currentAppSwitcherEnabled = preferences.currentAppSwitcherEnabled
            snapshot.currentAppSwitcherKeyCode = preferences.currentAppSwitcherKeyCode
            snapshot.currentAppSwitcherModifier = preferences.currentAppSwitcherModifier
            snapshot.shiftCyclesBackwards = preferences.shiftCyclesBackwards
        }
    }
}

/// The hotkey-relevant half of ``Preferences``, read on the main actor and handed over.
nonisolated struct HotKeyPreferenceSnapshot: Sendable, Equatable {
    var appSwitcherPreviewsEnabled: Bool
    var windowSwitcherEnabled: Bool
    var windowSwitcherModifier: ModifierCombo
    var currentAppSwitcherEnabled: Bool
    var currentAppSwitcherKeyCode: Int
    var currentAppSwitcherModifier: ModifierCombo
    var shiftCyclesBackwards: Bool
}
