import AppKit
import ApplicationServices
import CoreGraphics
import Dispatch
import Foundation

/// `_AXUIElementGetWindow` maps an accessibility element to the `CGWindowID` that
/// `CGWindowListCopyWindowInfo` and ScreenCaptureKit speak. It is private but has been
/// exported by HIServices for many releases and is confirmed present on macOS 26.5.2.
///
/// It usefully returns `kAXErrorIllegalArgument` (-25201) with `wid == 0` for Finder's
/// desktop pseudo-window, which doubles as a filter for that junk entry.
///
/// `nonisolated` is required: this project builds with `-default-isolation=MainActor`,
/// which would otherwise place this declaration on the main actor and make it
/// uncallable from the AX queue.
@_silgen_name("_AXUIElementGetWindow")
private nonisolated func _AXUIElementGetWindow(_ element: AXUIElement,
                                               _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Serialised, timeout-bounded access to the Accessibility API.
///
/// **This type exists because of how HyperDock 1.8 died.** Its crash reports show
/// `SIGSEGV` on the main thread inside
/// `AXUIElementCopyAttributeValue → _AXMIGCopyAttributeValue → mach_msg`.
/// That call is a *synchronous MIG RPC*: it blocks the caller until the **target
/// application's** main thread replies, with a 1.5 s default timeout. Issued from your
/// own main thread, a busy or wedged target stalls your entire run loop, and the
/// blocking call re-enters that run loop — which is the reentrancy fault behind the
/// second crash signature, inside `NSWindow _startLiveResize`. For a switcher this is
/// not a theoretical risk: every commit raises a window belonging to an application we
/// know nothing about, while the user is watching.
///
/// Two rules follow, and both are enforced here:
///   1. No AX call ever runs on the main thread.
///   2. A process-global messaging timeout is installed at startup.
///
/// It is an actor **with a custom executor** rather than a plain actor. The default
/// cooperative pool is a fixed, small set of threads shared with the thumbnail engine
/// and the window index; a single wedged application blocking one of them for the
/// timeout would stall unrelated work that has nothing to do with Accessibility.
/// Binding the actor to its own `DispatchSerialQueue` keeps the actor syntax — isolated
/// state, `await` at the boundary, no manual continuations — while confining every stall
/// to a thread nobody else needs. It also serialises AX calls, which matters because
/// `AXUIElement` is a non-`Sendable` CFType: elements never leave this actor, callers
/// receive plain values.
actor AXCore {
    /// `nonisolated` so the window index and the switcher's key handler can reach it
    /// without a main-actor hop; under `-default-isolation=MainActor` a bare `static let`
    /// would be main-actor isolated.
    nonisolated static let shared = AXCore()

    private let queue = DispatchSerialQueue(label: "com.hyperswitch.HyperSwitch.ax",
                                            qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Application elements are expensive to recreate and safe to keep.
    private var applicationCache: [pid_t: AXUIElement] = [:]

    /// Window elements that were successfully resolved once, kept so a later write can
    /// address the same window directly.
    ///
    /// This is not a speed optimisation. `kAXWindowsAttribute` is filtered to the
    /// **current Space**, so once the user moves to another desktop the window they were
    /// just looking at has no reachable element at all — and with "include windows from
    /// other spaces" on, those are precisely the windows the switcher offers. An element
    /// obtained while its Space was showing keeps working afterwards, so remembering it
    /// is the difference between a close that lands and one that silently does nothing.
    ///
    /// The list is unreliable in a second way that makes keeping elements worthwhile:
    /// measured on macOS 26.5.2, Sublime Text owns seven windows and advertises **one**
    /// there, and WeChat, Surge Dashboard and Chrome Canary omit even their focused
    /// window.
    private var windowElements: [CGWindowID: (element: AXUIElement, pid: pid_t)] = [:]

    /// Bounded so a long session cannot accumulate elements for windows that are gone.
    private let windowElementLimit = 64

    private init() {}

    // MARK: - Startup

    /// Installs the process-wide AX messaging timeout.
    ///
    /// Measured: `AXUIElementSetMessagingTimeout` is strictly **per element instance**
    /// and is *not* inherited by children — setting 0.5 s on an application element left
    /// its own child window at 1507 ms. Only the system-wide element sets a real process
    /// default, and that one applies retroactively to elements already created as well
    /// as to new ones. So this single call bounds every request the app ever makes.
    ///
    /// 0.25 s sits well under the 1 s event-tap timeout, so even a wedged target cannot
    /// cascade into the input system and get our hotkey tap disabled.
    nonisolated static func installGlobalTimeout(_ seconds: Float = 0.25) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// Whether this process currently holds Accessibility permission.
    ///
    /// Note: merely calling this from a bundled app creates a TCC row for our bundle id,
    /// denied if the user has not granted it. That is why the bundle id is fixed forever.
    nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt offering to open Privacy & Security.
    @discardableResult
    nonisolated static func requestTrust() -> Bool {
        // The SDK exposes kAXTrustedCheckOptionPrompt as a mutable global, which Swift 6
        // rejects as shared mutable state. Its value is a stable, documented constant.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Caches

    /// Drops a terminated application's cached elements.
    ///
    /// `nonisolated` because it is called from the workspace-notification observer on the
    /// main actor, which must not block; the cleanup is fire-and-forget and its ordering
    /// against in-flight AX calls does not matter — a stale element for a dead process
    /// only ever produces an error, which every caller here already handles.
    nonisolated func forget(pid: pid_t) {
        Task { await self.drop(pid: pid) }
    }

    private func drop(pid: pid_t) {
        applicationCache.removeValue(forKey: pid)
        windowElements = windowElements.filter { $0.value.pid != pid }
    }

    private func cachedApplication(_ pid: pid_t) -> AXUIElement {
        if let cached = applicationCache[pid] { return cached }
        let created = AXUIElementCreateApplication(pid)
        applicationCache[pid] = created
        return created
    }

    private func remember(_ element: AXUIElement, id: CGWindowID, pid: pid_t) {
        guard id != 0 else { return }
        if windowElements.count >= windowElementLimit, windowElements[id] == nil {
            // Cheapest possible eviction, and the contents are a cache either way: a
            // dropped entry costs one fall back to the window list, nothing more.
            windowElements.removeAll(keepingCapacity: true)
        }
        windowElements[id] = (element, pid)
    }

    // MARK: - Window control

    /// Brings a window forward and its application with it.
    ///
    /// Unhides the application first. A hidden application (⌘H) still owns its windows
    /// and they still appear in the switcher, but its window elements are not raisable
    /// while it is hidden — so without this the most visible thing the app does would
    /// quietly fail for exactly the windows the user could not otherwise get back to.
    ///
    /// Then retries: `kAXWindowsAttribute` is filtered to the current Space, and
    /// activating an application drags the display to the Space its window is on, but the
    /// switch is animated and the window does not become enumerable the instant it is
    /// asked for. Issuing that activation is `raise`'s own job — this was lifted from a
    /// sibling project whose callers switched the Space themselves first, and none of ours
    /// does, so without it the loop hands `findWindow` identical inputs twelve times over
    /// and is certain to fail.
    ///
    /// `kAXFocusedAttribute` proved non-settable on every window tested, so focus is
    /// established with `AXRaise` plus an explicit activation rather than by setting it.
    /// Bumped by every `raise`, so an older one can tell it has been superseded.
    ///
    /// Cancelling the caller's `Task` is *not* enough, and is in fact worse than nothing:
    /// every sleep in this file is `try? await Task.sleep`, and `try?` swallows the
    /// `CancellationError`. A cancelled raise therefore does not stop — it races through
    /// its remaining attempts and all three `confirmFrontmost` rounds with no delays at
    /// all, firing its `kAXFrontmost` writes back to back. It steals focus *faster*.
    ///
    /// So supersession is checked explicitly, immediately before each write.
    private var raiseEpoch = 0

    /// True while `epoch` is still the most recent raise.
    private func isCurrentRaise(_ epoch: Int) -> Bool { epoch == raiseEpoch }

    /// Brings an application forward without naming a window.
    ///
    /// This is what ⌘Tab's application row commits to, and it cannot use
    /// `NSRunningApplication.activate`. Since macOS 14 activation is cooperative: a
    /// request from a process that is not itself frontmost is ignored, and HyperSwitch is
    /// an agent that is never frontmost. Measured — selecting TextEdit on the application
    /// row and releasing ⌘ left the front application exactly where it was, every time.
    /// Setting `AXFrontmost` is the supported route for an accessibility client and is not
    /// subject to that rule, which is why `raise` already uses it.
    ///
    /// The outcome is handed back whole rather than flattened to a Bool, and the caller is
    /// expected to branch on it. Only ``FrontmostOutcome/gaveUp`` means "measured to have
    /// failed": it is the one outcome that may lead to a second attempt by another route.
    /// ``FrontmostOutcome/superseded`` must never lead to one — the user has chosen
    /// something else since, and acting on this pid now is precisely the "the application I
    /// just picked lost focus a second later" fault the epoch exists to prevent. Collapsing
    /// the two into one Bool is what left the fallback in `WindowActions.activate` firing
    /// on exactly the wrong half of them.
    @discardableResult
    func activate(pid: pid_t) async -> FrontmostOutcome {
        raiseEpoch &+= 1
        let epoch = raiseEpoch

        let application = cachedApplication(pid)
        AXUIElementSetAttributeValue(application, kAXHiddenAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return await confirmFrontmost(pid: pid, window: 0, epoch: epoch)
    }

    /// Whether the application exposes any window to Accessibility at all.
    ///
    /// Not every application does, and one that does not cannot be driven through this
    /// class by any route: `findWindow` has nothing to match against, and `kAXFrontmost` is
    /// ignored by the same applications for the same reason. Measured on WeChat —
    /// `kAXWindows` returns an empty array and `kAXMainWindow` answers `kAXErrorNoValue`
    /// (-25212) even while thirteen of its windows are listed by `CGWindowList` and while
    /// the user is standing on the very desktop one of them lives on. Every ⌘Tab to it
    /// therefore spent twelve attempts looking for a window that was never going to appear,
    /// then ~960 ms asserting an attribute nobody was reading, and did nothing.
    ///
    /// Callers use this to pick a route *before* paying for the one that cannot work.
    func vendsAnyWindow(pid: pid_t) -> Bool {
        let application = cachedApplication(pid)
        if let windows = Self.value(application, kAXWindowsAttribute) as? [AXUIElement],
           !windows.isEmpty {
            return true
        }
        return Self.value(application, kAXMainWindowAttribute) != nil
    }

    /// Marks a window as its application's main one, without raising anything.
    ///
    /// Needed before the Dock's activation follow-through can be relied on: the Dock
    /// decides which Space to slide to from the application's *main* window, so activating
    /// without setting this first sends the display to whichever window the application
    /// happened to consider main — usually not the one the user picked.
    @discardableResult
    func designateMain(window id: CGWindowID, pid: pid_t) -> Bool {
        guard let element = findWindow(id: id, pid: pid) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXMainAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Brings one window forward, retrying while its Space settles.
    ///
    /// - Parameter crossSpaces: Whether a window that turns out to live on another Space may
    ///   pull the display over to it. False for a *preview* raise made while the switcher
    ///   panel is still up: the Space change posts `activeSpaceDidChangeNotification`, which
    ///   `SwitcherController` observes and answers by cancelling the session — the panel
    ///   would vanish with the user's finger still on the modifier.
    @discardableResult
    func raise(window id: CGWindowID, pid: pid_t, attempts: Int = 12,
               crossSpaces: Bool = true) async -> Bool {
        raiseEpoch &+= 1
        let epoch = raiseEpoch

        AXUIElementSetAttributeValue(cachedApplication(pid), kAXHiddenAttribute as CFString,
                                     kCFBooleanFalse)

        for attempt in 0..<max(1, attempts) {
            // A newer raise started while this one was sleeping between attempts. Stop
            // before touching anything: the user has chosen something else since.
            guard isCurrentRaise(epoch) else { return false }

            if let element = findWindow(id: id, pid: pid) {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                             kCFBooleanFalse)
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString,
                                             kCFBooleanTrue)

                // Bring the owning application forward through Accessibility rather than
                // `NSRunningApplication.activate`. Since macOS 14, activation is
                // cooperative: a background agent that is not itself frontmost has its
                // activate() request ignored, so the window would rise within its app
                // while the app stayed behind — measured as `raised=true` with the
                // frontmost application never changing. Setting AXFrontmost is the
                // supported route for an accessibility client and is not subject to that
                // rule.
                //
                // And deliberately NOT both: adding activate() on top made the app come
                // forward and then lose focus again a moment later, because that request
                // is delivered asynchronously and lands after the AX activation has
                // settled, which the WindowServer resolves by handing focus back to
                // whatever was frontmost before.
                AXUIElementSetAttributeValue(cachedApplication(pid),
                                             kAXFrontmostAttribute as CFString, kCFBooleanTrue)

                switch await confirmFrontmost(pid: pid, window: id, epoch: epoch) {
                case .superseded:
                    return false
                case .confirmed, .gaveUp:
                    // `gaveUp` still counts as success *here*: the window did come forward
                    // inside its own application, which is a better outcome than the caller
                    // falling back to a blind activate() of the whole application.
                    return true
                }
            }

            // Nothing found on the first look, which for a window the switcher is offering
            // means it is on another Space — `kAXWindowsAttribute` is filtered to the one
            // being displayed (measured across 13 applications: the intersection of what AX
            // vends with the windows CGS lists for other Spaces was empty every time, and
            // `windowElements` can only hold an element for a window this process already
            // resolved while its Space was up). Every later attempt would ask the identical
            // question, so the loop cannot get there on its own: something has to move the
            // display, and for an agent that can only be `AXFrontmost` — a plain
            // `NSRunningApplication.activate` is ignored for us (see above).
            //
            // After the first miss rather than before the loop, because a window on the
            // current Space is found on attempt 0: activating first would raise whatever
            // that application had in front and only then swap in the target, costing a
            // frame of the wrong window on every ordinary switch.
            //
            // Honest about its reach: this only crosses when the application has no window
            // on the current Space at all. With windows on both, the system activates the
            // local one and the loop still runs out — the same failure as before, just
            // reached in ~60 ms instead of 660 ms.
            if attempt == 0, crossSpaces {
                AXUIElementSetAttributeValue(cachedApplication(pid),
                                             kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }

            // ~60 ms per attempt: a Space switch animates for roughly a third of a second.
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(60))
            }
        }

        // A preview raise must never change Space. The caller deliberately keeps the
        // switcher session open, and a Space transition posts
        // `activeSpaceDidChangeNotification`, which cancels that session. Respect the
        // same `crossSpaces` decision on the fallback path as on attempt zero; otherwise
        // the parameter only delays the forbidden activation until the retry loop ends.
        guard crossSpaces else {
            Log.windows.debug("raise: preview window \(id) stayed unreachable; not crossing Spaces")
            return false
        }

        // The window never became reachable — most likely it is on a Space we could not
        // reach, or its application never vended it to Accessibility at all. Activating
        // the application is the best remaining approximation for a committed switch.
        Log.windows.error("raise: window \(id) never became reachable after \(attempts) attempts")
        await MainActor.run {
            _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        }
        return false
    }

    /// Verifies the application really *stayed* forward, re-asserting if it did not.
    ///
    /// Becoming frontmost once is not enough. The switcher panel is key-capable — it has
    /// to be, or clicks never reach its content — and when a key-capable window is
    /// ordered out AppKit reassigns key status, which can hand focus straight back to the
    /// application that had it before. That undoes the raise a beat after it succeeded,
    /// so a single early check reports success for a window the user never sees.
    ///
    /// Hence: check, wait past the window in which the hand-back happens, check again,
    /// and only then assert a second time if needed.
    ///
    /// Three outcomes, not two. "A newer raise took over" and "three rounds of asserting
    /// `kAXFrontmost` and it never came" are opposite instructions to the caller — the
    /// first says stop touching anything, the second says this route is exhausted, try
    /// another — and a Bool had to map one of them onto the other.
    private func confirmFrontmost(pid: pid_t, window id: CGWindowID,
                                  epoch: Int) async -> FrontmostOutcome {
        for round in 0..<3 {
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(40))
                // The user picked something else while this was settling. Re-asserting now
                // is exactly the "the app I just chose lost focus a second later" bug.
                guard isCurrentRaise(epoch) else { return .superseded }
                let frontmost = await MainActor.run {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier
                }
                if frontmost == pid { break }
            }

            // Settle, then verify it *stuck* rather than merely happened.
            try? await Task.sleep(for: .milliseconds(120))
            guard isCurrentRaise(epoch) else { return .superseded }
            let settled = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            }
            if settled == pid {
                if round > 0 {
                    Log.windows.debug("raise: frontmost re-asserted after \(round) retries")
                }
                return .confirmed
            }

            guard isCurrentRaise(epoch) else { return .superseded }
            AXUIElementSetAttributeValue(cachedApplication(pid),
                                         kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }

        let front = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        }
        // Split by caller: `activate` passes window 0 and raised nothing, so the old
        // wording reported it as a failed raise of a window with id 0 and sent anyone
        // reading the log afterwards looking for a window that never existed.
        if id == 0 {
            Log.windows.error("activate: pid \(pid) stayed behind \(front, privacy: .public)")
        } else {
            Log.windows.error("raise: \(id) raised but front stayed \(front, privacy: .public)")
        }
        return .gaveUp
    }

    /// What ``confirmFrontmost(pid:window:epoch:)`` observed.
    ///
    /// Kept apart because they call for opposite things and used to share `false`/`true`
    /// with the mapping inverted: the real failure returned `true` and only supersession
    /// returned `false`, so `WindowActions.activate`'s second attempt could never run for
    /// the applications it was written for and ran only for targets the user had abandoned.
    nonisolated enum FrontmostOutcome: Sendable {
        /// The target is frontmost and stayed there.
        case confirmed
        /// A newer raise or activate has taken over. This one must touch nothing further.
        case superseded
        /// Three rounds of asserting `kAXFrontmost` and the target never came forward —
        /// measured on Electron applications that ignore the attribute outright.
        case gaveUp
    }

    /// Presses a window's close button, retrying while its Space settles.
    ///
    /// Like ``raise(window:pid:attempts:crossSpaces:)`` this has to poll, for the same reason:
    /// `kAXWindowsAttribute` is filtered to the current Space, so a window living
    /// elsewhere has no reachable element until its Space is showing.
    ///
    /// Note what this deliberately does *not* attempt. Some windows the switcher can show
    /// are unreachable through Accessibility entirely: measured on Ghostty, CGWindowList
    /// reported six windows while `kAXWindowsAttribute` listed one, and the missing five
    /// appeared nowhere else either — not under a different attribute, and not as
    /// minimised tiles in the Dock. Those are an application's own off-screen surfaces
    /// (background terminal tabs and the like), which it never vends to Accessibility.
    /// Closing them is not possible by this route, so this reports failure rather than
    /// pretending.
    @discardableResult
    func close(window id: CGWindowID, pid: pid_t, attempts: Int = 12) async -> Bool {
        for attempt in 0..<max(1, attempts) {
            // The type is checked rather than asserted. This was the one force-cast in the
            // project, on a path driven by a real keystroke against an arbitrary third-party
            // application — and what comes back is whatever *that* application's
            // accessibility implementation chose to vend under `AXCloseButton`. A wrong
            // type there would take HyperSwitch down with it.
            if let element = findWindow(id: id, pid: pid),
               let button = Self.value(element, kAXCloseButtonAttribute),
               CFGetTypeID(button) == AXUIElementGetTypeID(),
               AXUIElementPerformAction(unsafeDowncast(button, to: AXUIElement.self),
                                        kAXPressAction as CFString) == .success {
                return true
            }

            // Unhide once, in case the window is merely hidden rather than genuinely
            // unreachable.
            if attempt == 0 {
                AXUIElementSetAttributeValue(cachedApplication(pid),
                                             kAXHiddenAttribute as CFString, kCFBooleanFalse)
            }

            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        Log.windows.error("could not close window \(id)")
        return false
    }

    /// Minimises or restores a window, retrying while the window server is busy.
    ///
    /// The retry is what makes "restore all windows" restore more than one of them.
    /// Un-minimising plays the genie animation, and a write aimed at a second window
    /// while the first is still animating comes back `cannotComplete`. Without a retry
    /// that window is simply left minimised, silently — measured on two minimised
    /// TextEdit windows, where only the first ever came back.
    @discardableResult
    func setMinimized(_ minimized: Bool, window id: CGWindowID, pid: pid_t) async -> Bool {
        let attempts = 8
        for attempt in 0..<attempts {
            let result: AXError
            if let element = findWindow(id: id, pid: pid) {
                // Settability varies per window — a utility panel reported AXMinimized as
                // non-settable — so ask before setting rather than assuming.
                var settable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable)
                result = settable.boolValue
                    ? AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                                   minimized ? kCFBooleanTrue : kCFBooleanFalse)
                    : .attributeUnsupported
            } else {
                result = .invalidUIElement
            }

            if result == .success { return true }
            // A window that cannot carry the attribute at all will not start doing so.
            if result == .attributeUnsupported { return false }
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
        Log.windows.error("could not set minimized=\(minimized) on window \(id)")
        return false
    }

    /// The window ids this application still vends to Accessibility.
    ///
    /// Exists to tell a *minimised* window from a *destroyed* one, which
    /// `CGWindowListCopyWindowInfo` cannot: measured on TextEdit, a closed document window
    /// stays in the `.optionAll` listing indefinitely, keeping its title, bounds, alpha,
    /// sharing state and store type — every field identical to a minimised window's, with
    /// only `kCGWindowIsOnscreen` absent, exactly as when minimised. Accessibility does
    /// draw the distinction: a minimised window is still listed (carrying
    /// `kAXMinimizedAttribute`), a closed one is gone within a frame. Without this the
    /// switcher keeps offering windows the user closed from inside it.
    ///
    /// Returns `nil` when the list cannot be read at all — a caller should then trust
    /// CGWindowList rather than discard windows on the strength of a failed query.
    /// `kAXWindowsAttribute` is filtered to the current Space, so only ever narrow
    /// windows already believed to be *on* the current Space with this.
    func liveWindowIDs(pid: pid_t) async -> Set<CGWindowID>? {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(cachedApplication(pid),
                                                  kAXWindowsAttribute as CFString, &raw)
        guard error == .success, let windows = raw as? [AXUIElement] else { return nil }

        var ids: Set<CGWindowID> = []
        for window in windows {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(window, &id) == .success { ids.insert(id) }
        }
        return ids
    }

    // MARK: - Internals

    /// Finds the `AXUIElement` for a `CGWindowID`.
    ///
    /// Consults ``windowElements`` first — see there for why the application's own window
    /// list cannot be relied on. Re-reading the id off a remembered element confirms it is
    /// still the window it was: a dead element answers with an error, and the window
    /// server reuses ids.
    ///
    /// Resolves to `nil` for a window whose Space is not currently showing, and every
    /// caller treats that as "cannot control this one right now" and retries.
    private func findWindow(id: CGWindowID, pid: pid_t) -> AXUIElement? {
        if let cached = windowElements[id], cached.pid == pid {
            var found: CGWindowID = 0
            if _AXUIElementGetWindow(cached.element, &found) == .success, found == id {
                return cached.element
            }
            windowElements[id] = nil
        }

        guard let windows = Self.value(cachedApplication(pid), kAXWindowsAttribute) as? [AXUIElement]
        else { return nil }

        let match = windows.first { candidate in
            var found: CGWindowID = 0
            return _AXUIElementGetWindow(candidate, &found) == .success && found == id
        }
        if let match { remember(match, id: id, pid: pid) }
        return match
    }

    /// The single choke point for reading an attribute. Returns `nil` on any error,
    /// including `kAXErrorCannotComplete` (-25204), which is what a timeout looks like.
    private nonisolated static func value(_ element: AXUIElement,
                                          _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success
        else { return nil }
        return result
    }
}
