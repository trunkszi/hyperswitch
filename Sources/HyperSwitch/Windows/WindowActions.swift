import AppKit
import CoreGraphics

/// Actions that act on an application rather than on one specific window.
///
/// Window-level control — raise, close, minimise — belongs to ``AXCore``, because it has
/// to go through Accessibility. Everything here is reachable through `NSRunningApplication`
/// or a synthetic key event, neither of which needs the AX queue.
@MainActor
enum WindowActions {

    /// Brings an application forward, optionally giving it a window to come forward to.
    ///
    /// This is what committing a selection in the ⌘Tab application row does.
    static func activate(pid: pid_t, openDefaultWindow: Bool) {
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            Log.windows.error("activate: no running application for pid \(pid)")
            return
        }

        // Unhidden here, brought forward through Accessibility below.
        //
        // `NSRunningApplication.activate` used to be the whole of this method and it does
        // not work from here. Activation has been cooperative since macOS 14: a request
        // from a process that is not itself frontmost is ignored, and HyperSwitch is an
        // agent that never is. Measured — ⌘Tab to TextEdit, release, and the front
        // application had not changed. `AXCore.activate` sets `AXFrontmost`, which is the
        // route an accessibility client is allowed to use, and is what `raise` already did
        // for the window case.
        application.unhide()

        // Who was in front when the user let go. Read here, because the fallback below
        // decides a second later and has to tell "nothing has moved since" from "somebody
        // else has taken the front in the meantime".
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier

        Task {
            // An application that vends no window to Accessibility cannot be driven through
            // Accessibility at all — not by `kAXFrontmost` and not by a window raise. Take
            // the cooperative route straight away rather than spending ~960 ms asserting an
            // attribute nobody is reading. WeChat is the case this was written for; see
            // `AXCore.vendsAnyWindow`.
            guard await AXCore.shared.vendsAnyWindow(pid: pid) else {
                await MainActor.run {
                    Log.windows.debug("pid \(pid) vends no AX window; activating cooperatively")
                    activateCooperatively(application)
                }
                guard openDefaultWindow else { return }
                try? await Task.sleep(for: .milliseconds(250))
                await MainActor.run {
                    guard !hasWindows(pid: pid) else { return }
                    postKey(keyCode: newWindowKeyCode, flags: .maskCommand, to: pid)
                }
                return
            }

            let outcome = await AXCore.shared.activate(pid: pid)

            // Retired by a newer raise or activate: a second ⌘Tab committed inside the
            // ~960 ms this takes against an application that ignores `AXFrontmost`, or a
            // commit landing on top of an auto-activate preview. Nothing below may run for a
            // target the user has already replaced — neither the fallback, which would drag
            // the abandoned application and every one of its windows back over the chosen
            // one, nor the ⌘N further down, which never looked at the AX result at all.
            //
            // This `Task` is unnamed and uncancellable by design (`AXCore.raise` explains
            // why cancelling a raise is worse than letting it run: `try?` swallows the
            // `CancellationError`, so a cancelled one races through its remaining rounds
            // with no delays and steals focus *faster*). The epoch is therefore the only
            // thing that can retire it — and it is the right signal rather than a stand-in
            // for the switcher's session counter: a session that opens and is cancelled
            // without committing leaves this activation still the last thing the user
            // asked for, and it should be allowed to finish.
            guard outcome != .superseded else {
                Log.windows.debug("activate: pid \(pid) was superseded while settling")
                return
            }

            // Belt and braces, in that order and only in that order.
            //
            // `AXFrontmost` is the route that works from an agent, but not every
            // application honours it — measured, Termius came forward every time and Lark
            // did not, and an Electron app that ignores it leaves the user pressing ⌘Tab
            // and watching nothing happen. `NSRunningApplication.activate` is the reverse:
            // usually ignored for us, but free to try and occasionally the one that lands.
            //
            // Sequenced rather than fired together on purpose. `AXCore.raise` documents
            // the failure from doing both at once for a *window*: the asynchronous
            // activation arrives after the AX one has settled and the WindowServer resolves
            // it by handing focus back. Waiting for the AX attempt to be confirmed first
            // means the second only ever runs when the first has already failed.
            if outcome == .gaveUp {
                await MainActor.run {
                    // ~960 ms have gone by. Clicking another application or swiping to
                    // another Space in that second bumps no epoch, so `superseded` cannot
                    // see it, and this attempt would then haul the front off whatever the
                    // user has just opened. So it fires only while nothing has moved. That
                    // also covers the target arriving late off the loop's last
                    // re-assertion: the front is the target itself rather than who it was,
                    // and there is nothing left to do.
                    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    guard front == frontBefore else {
                        Log.windows.debug("activate: the front moved on; leaving pid \(pid) behind")
                        return
                    }
                    Log.windows.debug("AXFrontmost did not take for pid \(pid); yielding to it")
                    activateCooperatively(application)
                }
            }

            guard openDefaultWindow else { return }

            // Asked *after* the application is forward, not before, and both halves matter.
            // Many applications open a window in response to being activated — the reopen
            // behaviour — so asking beforehand would see zero windows, synthesise ⌘N, and
            // leave the user with two. And a key event sent to an application that is not
            // yet frontmost is simply dropped.
            await MainActor.run {
                guard !hasWindows(pid: pid) else { return }
                postKey(keyCode: newWindowKeyCode, flags: .maskCommand, to: pid)
            }
        }
    }

    /// Asks an application to open a new window.
    ///
    /// Sent as a synthetic ⌘N to the target rather than driven through its File menu:
    /// menu structure and item titles vary per application and per language, whereas
    /// ⌘N is near-universal for this.
    static func newWindow(for application: NSRunningApplication) {
        application.activate(options: [.activateAllWindows])

        // A short hop lets activation land first; a key event sent to an application
        // that is not yet frontmost is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            postKey(keyCode: newWindowKeyCode,
                    flags: .maskCommand,
                    to: application.processIdentifier)
        }
    }

    /// Quits an application the way ⌘Q does.
    ///
    /// `terminate()` sends the Apple event, so an application with unsaved work puts up
    /// its save sheet and stays alive. That is the intended outcome: the switcher's Q
    /// shortcut must not be able to destroy work.
    static func quit(pid: pid_t) {
        // Never ourselves. `AppList` and `WindowIndex` both filter our own pid out already,
        // so reaching here means one of those filters has a hole — and the symptom of that
        // hole is the switcher vanishing mid-use with no crash report and nothing in the
        // log to say why, which is close to undiagnosable after the fact. The guard costs
        // a comparison and leaves a line saying exactly what happened.
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            Log.windows.error("refused to quit HyperSwitch itself; a pid filter has a hole")
            return
        }
        guard let application = NSRunningApplication(processIdentifier: pid) else { return }
        application.terminate()
    }

    // MARK: - Internals

    /// Brings an application forward through macOS 14's cooperative activation.
    ///
    /// **All three calls are required, in this order.** The obvious two are not enough, and
    /// the reason the missing one is easy to overlook is that it looks like a no-op:
    ///
    ///   * `NSApp.activate()` — an agent that has never been active holds no activation, so
    ///     it has none to give away and `yieldActivation` silently does nothing. Measured
    ///     directly: yield-then-activate against WeChat left the front unchanged after two
    ///     seconds; the same sequence with this line in front brought it forward in 200 ms.
    ///     It does not visibly front this process — the front application was unchanged a
    ///     moment later — it only establishes the activation there is to yield.
    ///   * `NSApp.yieldActivation(to:)` — the entitlement itself. Since macOS 14 an
    ///     `activate()` from a process that is not frontmost is ignored, and this is the
    ///     supported way to say "I am not competing for the front".
    ///   * `activate()` — the request, now that it will be honoured.
    ///
    /// This is the only route left for an application that vends nothing to Accessibility.
    /// For everything else it is the fallback after `kAXFrontmost` has been measured not to
    /// take, which is where a bare `activate()` used to sit and do nothing.
    private static func activateCooperatively(_ application: NSRunningApplication) {
        NSApp.activate()
        NSApp.yieldActivation(to: application)
        _ = application.activate(options: [.activateAllWindows])
    }

    /// Virtual key code for `n`. Not in ``KeyCodes``, which lists the keys the switcher
    /// *reads*; this is the only one it ever writes.
    private static let newWindowKeyCode: CGKeyCode = 45

    /// Whether the application currently owns an ordinary window.
    ///
    /// Asked of `CGWindowListCopyWindowInfo` directly rather than through ``WindowIndex``
    /// because the question is both narrower and wider than any query the index answers:
    /// narrower in that it needs no titles, Space lookup or ordering, and wider in that a
    /// window on another Space, on another screen or minimised still counts — the user
    /// has one, and a second must not be conjured up.
    ///
    /// An unreadable list answers `true`, so an unexpected failure does nothing rather
    /// than opening a window nobody asked for.
    private static func hasWindows(pid: pid_t) -> Bool {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return true }

        let spaces = WindowIndex.buildSpaceMap()
        return raw.contains { entry in
            countsAsWindow(entry, of: pid) { spaces.placement(of: $0).isInAnySpace }
        }
    }

    /// Whether one window-list entry is a window the user has, for ``hasWindows(pid:)``.
    ///
    /// Split out so the rule can be tested against plain dictionaries; everything around
    /// it needs a live window server.
    nonisolated static func countsAsWindow(_ entry: [String: Any],
                                           of pid: pid_t,
                                           isInAnySpace: (CGWindowID) -> Bool) -> Bool {
        guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
              (entry[kCGWindowLayer as String] as? Int) == 0,
              let id = entry[kCGWindowNumber as String] as? CGWindowID,
              let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
        else { return false }

        // Layer 0 alone is not enough, which is what made this answer "yes" for an
        // application with no windows at all. Measured against Finder with every
        // window closed: it still owns five layer-0 windows — one 64×64 and four
        // 2056×39 — none of which is a document. AppKit gives ordinary applications
        // these too. So the same floor `WindowIndex` uses to tell a window from a
        // palette or a stray strip applies here.
        guard (bounds["Width"] ?? 0) >= minimumWindowSize.width,
              (bounds["Height"] ?? 0) >= minimumWindowSize.height
        else { return false }

        // The size floor is not enough either. Applications keep windows they built and
        // never ordered in — measured on this machine, a 500×500 layer-0 window that
        // survives with no window open at all, which is comfortably above the floor and
        // made every such application look like it already had one, so "open a window
        // when the app has none" never fired. `WindowIndex` throws the same windows out
        // of the switcher with this same test: off screen *and* claimed by no Space is a
        // window nobody can see or reach. A minimised window, or one on another desktop,
        // still belongs to a Space and still counts.
        let onScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
        guard onScreen || isInAnySpace(id) else { return false }

        // Fully transparent is the other shape of the same thing: present, sized, and
        // invisible by construction.
        if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 { return false }
        return true
    }

    /// The smallest thing a person would call a window. Shared with `WindowIndex`'s own
    /// filter so "the switcher shows it" and "the app has one" can never disagree.
    private nonisolated static let minimumWindowSize = CGSize(width: 80, height: 60)

    private static func postKey(keyCode: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags

        // postToPid rather than posting to the session tap: the event goes straight to
        // the target application and is never seen by our own event tap, which is
        // watching for exactly this kind of modifier-plus-key combination.
        down?.postToPid(pid)
        up?.postToPid(pid)
    }
}
