import AppKit
import CoreGraphics

/// The keyboard side of the switcher: one `CGEventTap` that both recognises the three
/// activation hotkeys and, once a session is running, feeds every subsequent keystroke to
/// the controller instead of to the frontmost application.
///
/// A tap is the only mechanism that can do this. `NSEvent.addGlobalMonitorForEvents`
/// observes but cannot swallow, so ⌥Tab would still reach the application underneath, and
/// Carbon `RegisterEventHotKey` cannot see the *release* of a modifier — which is how the
/// switcher commits. Both are disqualified by the same requirement.
///
/// The tap carries one hard rule inherited from HyperDock: **the callback must never
/// block.** It runs on the event delivery path and the WindowServer disables any tap that
/// overruns; measured on this machine the budget is exactly 1.000 s.
///
/// **The tap runs on its own thread.** It used to be attached to `CFRunLoopGetMain()`, and
/// that turned the rule above into one the app could not keep: "the callback must not
/// block" silently became "the *main thread* must never be busy for a second", and this
/// app's own full-size hover preview breaks that regularly — an ~8 MB capture landing on
/// the main actor forces a synchronous SwiftUI layout pass. The symptom was precise and
/// reproducible: rest the pointer on the panel, press ⌘Tab four or five times, and the
/// *system* switcher appears, because our disabled tap passed the keystroke straight
/// through. The unified log showed the health check re-enabling the tap nineteen times in
/// six minutes, never the callback's own re-enable path — proof that the callback was not
/// being called at all rather than being called and running slowly.
///
/// On its own thread the callback is unaffected by whatever the main actor is doing. It
/// decides from ``HotKeyState``'s lock-protected snapshot, applies the session-level
/// consequence of its own decision to that snapshot, and hands the actual work to the main
/// actor asynchronously.
@MainActor
final class HotKeyMonitor {
    private let controller: SwitcherController
    private let tap = HotKeyTap()

    /// Drives ``ensureAlive()``, which is the only thing that can notice a tap the system
    /// has killed outright.
    private var healthTimer: Timer?

    /// True while a failure to install the tap has already been reported.
    ///
    /// The retry loop below runs `start()` on every tick for as long as the tap is missing,
    /// so an unconditional `error` on the failure paths would write a line per tick forever
    /// on a machine that is never granted Accessibility — trading a dead watchdog for a log
    /// flood.
    private var loggedTapFailure = false

    init(controller: SwitcherController) {
        self.controller = controller
    }

    /// True only when a tap exists **and** the system still has it enabled.
    ///
    /// The enabled half matters as much as the first: a tap that has been disabled out
    /// from under us delivers nothing, so reporting `true` for it would put "hotkeys do
    /// nothing" and "hotkey monitor is running" in the same bug report and send the reader
    /// looking in the wrong place.
    var isRunning: Bool { tap.isEnabled }

    // MARK: - Lifecycle

    func start() {
        // First statement, ahead of every early return below. The health timer is the only
        // thing that turns a failed install into "try again shortly" rather than "dead
        // until the app is relaunched", so it must not be conditional on the very thing it
        // exists to retry: starting it at the end meant an install that failed on a missing
        // grant or a nil tapCreate left nothing behind to try again.
        startHealthChecks()

        // Not `guard !tap.exists`: that made start() idempotent *and* a dead end, because a
        // tap object that still exists but no longer works would turn every later call into
        // a no-op. Route that case through the repair path instead.
        if tap.exists {
            ensureAlive()
            return
        }

        // Checked up front rather than relying on tapCreate's nil return, because that
        // return value is indistinguishable from every other failure mode and this is by
        // far the most common one: an untrusted process gets no keyboard tap at all.
        guard AXCore.isTrusted else {
            logTapFailure("no keyboard tap: Accessibility is not granted, so hotkeys are inert")
            // Without a tap there is nothing to displace the system switcher with, so the
            // shortcut has to go back — otherwise ⌘Tab is a dead key with no explanation.
            SystemHotKeys.restore()
            return
        }

        guard tap.install() else {
            logTapFailure("CGEvent.tapCreate returned nil; Accessibility may have just been revoked")
            SystemHotKeys.restore()
            return
        }

        loggedTapFailure = false
        Log.hotkeys.debug("keyboard tap installed on its own run loop")
        syncSystemHotKeys()
    }

    /// The explicit, permanent stop: the tap *and* the loop that would rebuild it.
    ///
    /// Only for teardown at termination and for a grant the user has taken away, where
    /// polling `AXIsProcessTrusted()` buys nothing. Everything that tears down in order to
    /// rebuild uses ``HotKeyTap/uninstall()`` directly.
    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        tap.uninstall()
        // So the next start() reports its first failure rather than staying silent about an
        // outage that began before this stop.
        loggedTapFailure = false
        // Nothing left to intercept ⌘Tab with.
        SystemHotKeys.restore()
    }

    /// Reports a failed install once per outage instead of once per retry.
    private func logTapFailure(_ reason: String) {
        guard !loggedTapFailure else { return }
        loggedTapFailure = true
        Log.hotkeys.error("\(reason, privacy: .public)")
    }

    /// Rebuilds the tap when the system has taken it away.
    ///
    /// Three things can kill a tap and only one of them announces itself. A timeout or
    /// secure input sends `tapDisabledBy…`, which the callback handles. But revoking
    /// Accessibility while the app runs kills the port outright with no event at all, and
    /// `start()`'s old `guard tap == nil` then made every later call a no-op — the hotkeys
    /// were dead for the rest of the session while `isRunning` cheerfully reported true.
    ///
    /// Re-enabling is tried first because it is free and covers the common case; only a
    /// port that will not come back is torn down and rebuilt.
    func ensureAlive() {
        guard tap.exists else {
            start()
            return
        }
        guard !tap.isEnabled else {
            syncSystemHotKeys()
            return
        }

        Log.hotkeys.error("keyboard tap was disabled; attempting to re-enable")
        tap.reenable()
        guard !tap.isEnabled else {
            syncSystemHotKeys()
            return
        }

        Log.hotkeys.error("re-enable failed; rebuilding the tap")
        // `uninstall()`, not `stop()`: this is the timer's own repair path, and stopping
        // outright here would have it invalidate the timer that is calling it — one failed
        // rebuild and there is nothing left to attempt the next one.
        tap.uninstall()
        start()
    }

    /// Polls for a tap that has died silently — or that never got installed in the first
    /// place, since `start()` arms this before it can fail.
    ///
    /// **A quarter of a second, not two.** The interval is not a politeness setting, it is
    /// the length of the outage: for as long as a disabled tap goes unnoticed, every ⌘Tab
    /// reaches the system switcher. At two seconds a single timeout was worth up to eight
    /// stray presses, which is exactly what the user saw. The check itself is one
    /// `CGEvent.tapIsEnabled` against our own port — a Mach message to our own process —
    /// plus, at most, one comparison against the system shortcut's state.
    private func startHealthChecks() {
        // Idempotent rather than invalidate-and-rebuild, because `start()` now calls this on
        // every attempt including the ones the timer itself provoked. Rebuilding would let a
        // run of failed installs push the next check out by a full interval each time —
        // through its own callback (timer → ensureAlive → start → startHealthChecks), which
        // is precisely the retry this timer exists to guarantee.
        guard healthTimer == nil else { return }

        // `.common`, for the same reason the session watchdog uses it: a timer registered
        // only in `.default` stops while a menu is tracking or an alert is up.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureAlive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    // MARK: - The system's own ⌘Tab

    /// Keeps the native shortcut off for exactly as long as we can answer for it.
    ///
    /// Driven from the health check rather than from each of the places that could change
    /// the answer — the settings toggle, a revoked permission, a tap that had to be rebuilt
    /// — because those are three separate call sites that all have to be remembered, and
    /// the one that gets forgotten leaves either a dead ⌘Tab or a system switcher popping
    /// up over ours. One place that re-asserts the truth four times a second cannot be
    /// forgotten, and `setSuppressed` writes only when the state actually differs.
    private func syncSystemHotKeys() {
        SystemHotKeys.setSuppressed(Preferences.shared.appSwitcherPreviewsEnabled && tap.isEnabled)
    }
}

/// The tap itself, its thread, and the callback — none of which are main-actor state.
///
/// Split out of ``HotKeyMonitor`` because the callback runs on the tap's own thread and
/// therefore cannot touch a `@MainActor` object at all. What crosses back to the main actor
/// is a ``HotKeyAction``, which is a value.
private nonisolated final class HotKeyTap: @unchecked Sendable {

    /// Guards `port` alone. Held for a single pointer read in the callback and for one
    /// assignment on the main actor, so neither side can hold up the other meaningfully.
    private let lock = NSLock()
    private var port: CFMachPort?

    private var source: CFRunLoopSource?
    private var thread: TapThread?

    var exists: Bool {
        lock.lock(); defer { lock.unlock() }
        return port != nil
    }

    var isEnabled: Bool {
        lock.lock()
        let port = self.port
        lock.unlock()
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    func reenable() {
        lock.lock()
        let port = self.port
        lock.unlock()
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Builds the tap and parks its run loop source on a thread of its own.
    func install() -> Bool {
        // tapDisabledByTimeout and tapDisabledByUserInput are listed for the record, not
        // because listing them has any effect: their raw values are 0xFFFFFFFE and
        // 0xFFFFFFFF, so `1 << rawValue` shifts clean off the end of a 64-bit mask and
        // contributes zero. The WindowServer delivers them to the tap regardless of the
        // mask, which is what makes the re-enable path below reachable.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        // .cgSessionEventTap, not .cghidEventTap: the HID location requires root and
        // CGEvent.tapCreate simply returns nil without it.
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<HotKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            // Unretained is safe: the tap cannot outlive this object, because the only
            // thing that removes the run loop source is its own uninstall().
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let thread = TapThread()
        thread.start()
        guard let loop = thread.waitUntilReady() else {
            thread.cancel()
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        // The thread is parked in a timed `CFRunLoopRunInMode`, so a source added from
        // outside is not picked up until the current wait returns. Waking it makes the tap
        // live now rather than up to a quarter of a second from now.
        CFRunLoopWakeUp(loop)

        lock.lock()
        port = created
        lock.unlock()
        self.source = source
        self.thread = thread
        return true
    }

    /// Drops the tap and its thread. Safe to call when nothing is installed.
    func uninstall() {
        lock.lock()
        let port = self.port
        self.port = nil
        lock.unlock()

        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source, let loop = thread?.loop {
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        source = nil
        // The thread's loop returns from its timed wait, sees the cancellation and exits.
        thread?.cancel()
        if let loop = thread?.loop { CFRunLoopWakeUp(loop) }
        thread = nil
    }

    // MARK: - Callback

    /// Runs on the tap's thread. Everything it touches is either a value or lock-protected.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            // The budget was overrun. Since the callback moved off the main thread this
            // should be rare, and when it does happen it is worth a line at error level:
            // every occurrence is a window in which the hotkeys did nothing.
            Log.hotkeys.error("tap disabled: the callback overran its budget; re-enabling")
            reenable()
            endSessionAfterOutage()
            return Unmanaged.passUnretained(event)

        case .tapDisabledByUserInput:
            // Secure input — a password field anywhere on the system, including the login
            // window and SecurityAgent. Nothing to fix here; it comes back on its own.
            // Kept distinct from the timeout above because the two have entirely different
            // causes and merging them made the log unable to say which had happened.
            Log.hotkeys.error("tap disabled by secure input; re-enabling")
            reenable()
            endSessionAfterOutage()
            return Unmanaged.passUnretained(event)

        default:
            break
        }

        // Only scalars leave this scope. `CGEvent` is not Sendable, so handing it to the
        // main actor would be a data race by construction — and reading a few fields is
        // also the whole point of keeping the callback inside its budget.
        let keyCode = CGKeyCode(truncatingIfNeeded:
            event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let text = type == .keyDown ? copiedKeyboardText(from: event) : ""
        let timestamp = event.timestamp

        let state = HotKeyState.shared
        let decision = HotKeyPolicy.decide(type: type, keyCode: keyCode, flags: flags,
                                           text: text, timestamp: timestamp,
                                           state: state.current)
        // Applied before the action is dispatched, not after it runs: the next keystroke can
        // arrive before the main actor has even been scheduled. See `HotKeyStateEdit`.
        state.apply(decision.edit)

        if let action = decision.action {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SwitcherController.shared.perform(action)
                }
            }
        }

        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// A session that was open during an outage has almost certainly lost the modifier
    /// release that would have committed it, and would otherwise leave the panel on screen
    /// swallowing every key. Cancel rather than commit: acting on a selection whose
    /// keystrokes we may have missed is the worse of the two.
    private func endSessionAfterOutage() {
        HotKeyState.shared.apply(.endSession)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if SwitcherController.shared.isActive { SwitcherController.shared.cancel() }
            }
        }
    }
}

/// A thread whose only job is to own a run loop the tap can live on.
///
/// `Thread` rather than a `DispatchQueue`: a `CGEventTap` needs a `CFRunLoop`, and a queue
/// has none of its own that outlives a single block.
private nonisolated final class TapThread: Thread, @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let loopLock = NSLock()
    private var storedLoop: CFRunLoop?

    /// The loop, once the thread has published it. Read from the main actor.
    var loop: CFRunLoop? {
        loopLock.lock(); defer { loopLock.unlock() }
        return storedLoop
    }

    override func main() {
        Thread.current.name = "com.hyperswitch.HyperSwitch.hotkey-tap"
        loopLock.lock()
        storedLoop = CFRunLoopGetCurrent()
        loopLock.unlock()
        ready.signal()

        // A bare `CFRunLoopRun()` returns immediately while the loop has no sources, and the
        // source is added by the installer *after* this signals — so the thread would exit
        // in the gap. A timed wait in a loop has no such race and gives `cancel()` a
        // guaranteed point at which it is noticed.
        while !isCancelled {
            _ = CFRunLoopRunInMode(.defaultMode, 0.25, false)
        }
    }

    /// Blocks until the thread has a run loop to hand out. Called once, from the installer.
    func waitUntilReady() -> CFRunLoop? {
        // 2 seconds is a formality — the thread publishes its loop as its first statement —
        // but it means a scheduler pathology degrades to "no hotkeys" rather than to a
        // permanently blocked launch.
        guard ready.wait(timeout: .now() + 2) == .success else { return nil }
        return loop
    }
}

/// Copies a small text value while the event is still valid inside the tap callback.
///
/// File-level rather than a member of the tap: Swift 6.3's SendNonSendable pass crashes
/// when the non-Sendable CGEvent crosses that particular member boundary, even though the
/// call is synchronous; the free function expresses the real isolation and keeps strict
/// concurrency enabled.
private nonisolated func copiedKeyboardText(from event: CGEvent) -> String {
    var units = [UniChar](repeating: 0, count: 16)
    var length = 0
    units.withUnsafeMutableBufferPointer { buffer in
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: buffer.baseAddress
        )
    }
    guard length > 0 else { return "" }
    return String(decoding: units.prefix(min(length, units.count)), as: UTF16.self)
}
