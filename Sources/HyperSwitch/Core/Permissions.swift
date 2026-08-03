import AppKit
import CoreGraphics
import Observation

nonisolated enum PermissionLaunchAction: Equatable, Sendable {
    case none
    case showIntroduction
}

/// Launch guidance is deliberately separate from the system permission request. A Debug
/// or XCTest build has a different code signature often enough that prompting at launch
/// becomes a prompt on every verification run.
nonisolated enum PermissionLaunchPolicy {
    static func action(hasAccessibility: Bool,
                       hasShownIntroduction: Bool,
                       isRunningTests: Bool) -> PermissionLaunchAction {
        guard !hasAccessibility, !hasShownIntroduction, !isRunningTests else { return .none }
        return .showIntroduction
    }
}

/// Tracks the two system permissions HyperSwitch cannot work without.
///
/// Both are granted in System Settings and neither can be requested silently, so the
/// app has to keep watching for them to appear rather than checking once at launch.
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    /// Required twice over: `CGEvent.tapCreate` on a session tap refuses to hand back a
    /// port unless the process is trusted, so without this the hotkeys never fire at
    /// all — and raising, closing or minimising the selected window is AX as well.
    private(set) var hasAccessibility = false

    /// Required for window thumbnails, and also for window *titles* — on modern macOS
    /// `kCGWindowName` comes back empty without it, which is why the switcher would
    /// otherwise show a row of application names with no way to tell two documents
    /// apart.
    private(set) var hasScreenRecording = false

    var allGranted: Bool { hasAccessibility && hasScreenRecording }

    private var pollTimer: Timer?

    /// Gates the broadcast out of ``refresh()`` until `shared` exists.
    private var isReady = false

    private init() {
        refresh()
        isReady = true
    }

    /// Re-reads both grants, announcing any change, and reports whether either moved.
    ///
    /// The comparison is per-grant rather than on ``allGranted``. Screen Recording is
    /// optional — its absence degrades the switcher instead of disabling it — and with it
    /// missing the conjunction reads false both while Accessibility is granted and while
    /// it is revoked, so the event tap was neither built nor torn down. That was a dead
    /// end rather than a delay: on a fresh install the launch path never calls
    /// `HotKeyMonitor.start()`, and ``didChangeNotification`` is the only thing that ever
    /// calls it afterwards, so the hotkeys stayed inert until the app was relaunched.
    ///
    /// The post belongs here and not in the poll block because this method has other
    /// callers — the About pane refreshes when it appears — and a transition observed by
    /// one of them is a transition the poll block can no longer see. An edge that any
    /// caller can consume is an edge that eventually gets consumed by the wrong one.
    @discardableResult
    func refresh() -> Bool {
        let accessibility = AXCore.isTrusted
        // Preflight checks the grant *without* showing a prompt, unlike
        // CGRequestScreenCaptureAccess.
        let screenRecording = CGPreflightScreenCaptureAccess()

        let accessibilityChanged = accessibility != hasAccessibility
        let screenRecordingChanged = screenRecording != hasScreenRecording

        // Only log transitions. This runs once a second while anything is missing, and a
        // line per tick would bury whatever else is being traced at the time.
        if accessibilityChanged {
            Log.permissions.info("accessibility: \(accessibility, privacy: .public)")
        }
        if screenRecordingChanged {
            Log.permissions.info("screen recording: \(screenRecording, privacy: .public)")
        }

        hasAccessibility = accessibility
        hasScreenRecording = screenRecording

        // `isReady` silences the one call `init()` makes: it runs inside the swift_once
        // that creates `shared`, and an observer reaching for `Permissions.shared` from
        // the callback would re-enter that same once token and deadlock. No transition is
        // lost — the launch path reads the initial state directly rather than waiting for
        // a notification.
        let changed = accessibilityChanged || screenRecordingChanged
        if changed, isReady {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
        return changed
    }

    /// Posted whenever either grant changes, in either direction.
    ///
    /// The event tap cannot be rebuilt from in here — that belongs to `HotKeyMonitor` —
    /// so the change is announced and `AppDelegate` acts on it.
    static let didChangeNotification = Notification.Name("com.hyperswitch.HyperSwitch.permissionsDidChange")

    /// Watches both grants for as long as the app runs.
    ///
    /// There is no notification for a TCC grant, and the user leaves the app to toggle a
    /// switch in System Settings, so polling is the only way to notice.
    ///
    /// It used to stop the moment everything was granted, which reads as an optimisation
    /// and is actually a trap: revoking Accessibility in System Settings kills the event
    /// tap outright, and with the watcher gone nothing noticed. The hotkeys were dead for
    /// the rest of the session while the About pane still said "Granted" and the status
    /// menu showed no warning — the interface actively denied the thing that was wrong.
    ///
    /// So it never stops; it only slows down. Five seconds once everything is in place is
    /// two `AXIsProcessTrusted`/`CGPreflight` calls per tick, which is nothing, and one
    /// second while something is missing keeps the "grant it and come back" flow feeling
    /// immediate.
    func beginWatching() {
        scheduleWatch(interval: allGranted ? Self.idleInterval : Self.urgentInterval)
    }

    private static let urgentInterval: TimeInterval = 1.0
    private static let idleInterval: TimeInterval = 5.0

    private func scheduleWatch(interval: TimeInterval) {
        pollTimer?.invalidate()
        // `.common`: a timer left in `.default` stops while a menu is tracking or an alert
        // is up, which is exactly when the user is most likely to be granting something.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasAllGranted = self.allGranted
                // `refresh()` announces the change itself; this block owns only the
                // cadence. Announcing from here instead meant comparing conjunctions,
                // which is blind to a single grant moving while the other one is missing.
                self.refresh()
                // The cadence does key off the conjunction: there are two speeds,
                // "everything is in place" and "something is still missing", so re-arming
                // is worth doing only when that flips. A single grant changing would
                // otherwise rebuild the timer at the interval it already had.
                guard self.allGranted != wasAllGranted else { return }
                self.scheduleWatch(interval: self.allGranted ? Self.idleInterval
                                                             : Self.urgentInterval)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Requests

    /// Shows the system Accessibility prompt. This is called only from an explicit user
    /// action; launch-time checks must remain silent.
    ///
    /// Only the first call for a given code signature actually presents it; afterwards
    /// TCC remembers the decision and this is a silent no-op, so the panes pair it with
    /// ``openAccessibilitySettings()`` rather than relying on it alone.
    func requestAccessibility() {
        AXCore.requestTrust()
    }

    /// Triggers the Screen Recording prompt.
    ///
    /// Apple documents that the grant only takes effect after a relaunch, so the UI
    /// tells the user that rather than leaving them wondering why nothing changed.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    /// Asks first, *then* opens the pane.
    ///
    /// The order is the whole point. macOS only lists an application under Accessibility
    /// once that application has asked for it, and nothing here was asking — so on a clean
    /// machine "Open Settings" sent the user to a list their app was not in, and the only
    /// way forward was to find the "+" button and hunt for HyperSwitch in a file dialog.
    /// Requesting first puts the row there, switched off, ready to be flipped.
    ///
    /// The request is silent after the first time for a given code signature, so pairing
    /// the two is safe to repeat.
    func openAccessibilitySettings() {
        requestAccessibility()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        requestScreenRecording()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
