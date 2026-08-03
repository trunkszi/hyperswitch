import AppKit
import CoreGraphics

/// Crosses to another desktop the way the system itself would.
///
/// **Why this exists at all.** Committing a ⌘Tab selection used to end at
/// `kAXFrontmost = true`, which has no notion of Spaces. For an application whose windows
/// are all on another desktop, setting that attribute moves nothing: the display stays
/// where it is, the application never comes forward, and ~960 ms later the log records
/// `activate: pid … stayed behind …`. Measured on the report that prompted this — WeChat
/// with thirteen windows, the one on screen sitting on Space 3 while the user was on
/// Space 4 — ⌘Tab to it did nothing, every time. It also explains why the fault looked
/// intermittent: with a window on the current Space, `kAXFrontmost` is enough.
///
/// **Why not `CGSManagedDisplaySetCurrentSpace`.** That call moves the window server's
/// compositing and bookkeeping but never tells the Dock, which owns Spaces. After a quiet
/// switch the Dock still believes the user is on the old desktop, so Mission Control
/// presents the old desktop's windows — with the newly shown window visibly on screen yet
/// absent from Mission Control's model and impossible to select there.
///
/// So both routes below hand the transition to the Dock and let it animate:
///
///   1. **Activation follow-through.** Activating an application whose *main* window lives
///      on another Space makes the Dock perform the full transition itself. Since macOS 14
///      activation is cooperative, so the request has to be preceded by an explicit
///      `yieldActivation(to:)` — an agent's bare `activate()` is ignored.
///   2. **The desktop's own symbolic hotkey.** "Switch to Desktop *n*" exists for every
///      desktop whether or not the user has bound it, and unlike the Mission Control arrow
///      hotkeys it fires from a posted event. Enabled just long enough to post its own
///      combination, then restored, so a user who keeps it unbound never sees it active.
@MainActor
enum SpaceSwitcher {

    /// Brings the desktop containing `window` to the front. Returns false if it could not.
    ///
    /// Callers must treat false as "do not proceed with the raise": Accessibility cannot
    /// see a window on a Space that is not showing, so raising it would fail anyway, and
    /// the honest outcome is to leave the user where they are rather than to half-switch.
    static func reach(window: CGWindowID, pid: pid_t) async -> Bool {
        guard let destination = CGS.spaceToReach(window: window) else { return true }
        let started = ProcessInfo.processInfo.systemUptime

        // **The hotkey first, not the activation follow.**
        //
        // Both end in the same Dock-driven transition, so there is nothing to choose
        // between them on the result — but there is on how failure is detected. The hotkey
        // is deterministic: post the combination and the Dock starts animating. Activation
        // follow is conditional on a system setting the user can turn off ("When switching
        // to an application, switch to a Space with open windows for the application"), and
        // when it is off nothing happens *and nothing says so* — the only way to find out
        // is to wait for a timeout. Trying it first therefore charged every cross-desktop
        // switch a second and a half of dead time before the route that works even started,
        // which is exactly the 2–3 s pause this fixes.
        if await switchViaDesktopHotKey(to: destination) {
            Log.windows.debug("""
                crossed to desktop via hotkey in \
                \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms
                """)
            return true
        }

        // Only reachable when the hotkey cannot serve: a desktop past the sixteen macOS
        // defines, or the SPI declining to hand over a binding.
        let crossed = await activationFollow(to: destination, window: window, pid: pid)
        Log.windows.debug("""
            hotkey route unavailable; activation follow \(crossed ? "crossed" : "failed") in \
            \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms
            """)
        return crossed
    }

    /// Makes the Dock cross by activating the application whose main window lives there.
    private static func activationFollow(to destination: UInt64,
                                         window: CGWindowID,
                                         pid: pid_t) async -> Bool {
        // Activation follow only fires when activating the application gives the Dock a
        // reason to switch. An application that already has a window on a Space the user is
        // looking at gives it none: the Dock treats it as "present" and the activation just
        // raises the nearby window instead — measured on Sublime Text, four windows with
        // one on the current desktop, where every attempt at an off-desktop window
        // activated in place and went nowhere.
        guard !hasWindowOnVisibleSpace(pid: pid) else { return false }

        await AXCore.shared.designateMain(window: window, pid: pid)
        if let application = NSRunningApplication(processIdentifier: pid) {
            // Unconditionally, not only when the target is already frontmost. This process
            // is an agent whose panel never activates it, so it holds no activation — and
            // `yieldActivation` from a process with none to give is a no-op. Measured: the
            // yield-then-activate pair alone left the front unchanged; with this line in
            // front of it the target came forward in 200 ms. See
            // `WindowActions.activateCooperatively`, which carries the full account.
            NSApp.activate()
            NSApp.yieldActivation(to: application)
            application.activate()
        }
        return await settled(on: destination, within: 1_200)
    }

    // MARK: - Internals

    /// Posts the destination desktop's own "Switch to Desktop *n*" shortcut.
    private static func switchViaDesktopHotKey(to destination: UInt64) async -> Bool {
        guard let number = CGS.desktopNumber(of: destination),
              let hotKey = SystemHotKeys.desktopHotKey(number: number),
              let binding = SystemHotKeys.binding(for: hotKey)
        else { return false }

        let wasEnabled = SystemHotKeys.isEnabled(hotKey)
        if !wasEnabled { SystemHotKeys.setEnabled(hotKey, true) }
        defer { if !wasEnabled { SystemHotKeys.setEnabled(hotKey, false) } }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: binding.key, keyDown: true)
        down?.flags = binding.flags
        let up = CGEvent(keyboardEventSource: nil, virtualKey: binding.key, keyDown: false)
        up?.flags = binding.flags
        // `.cghidEventTap`, not the session tap: a desktop hotkey is matched further up the
        // stack than a session tap can reach, and posting to the session location leaves it
        // unhandled.
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        return await settled(on: destination, within: 1_200)
    }

    /// Whether the application owns an ordinary on-screen window on a Space the user is
    /// currently looking at — the topology that defeats activation follow.
    private static func hasWindowOnVisibleSpace(pid: pid_t) -> Bool {
        let visible = CGS.currentSpaces()
        guard !visible.isEmpty else { return false }
        for window in CGS.applicationWindows(pid: pid) {
            // The same floor the window index uses, so a toolbar strip or a 64×64 helper
            // surface cannot count as "the application is already here".
            guard window.frame.width >= 200, window.frame.height >= 200 else { continue }
            if CGS.spaces(forWindow: window.id).contains(where: { visible.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Polls until the destination is showing, or the budget runs out.
    ///
    /// Polled rather than driven by `activeSpaceDidChangeNotification`: that notification
    /// fires at the *start* of the transition, and Accessibility cannot see the target
    /// window until it has finished.
    private static func settled(on destination: UInt64, within milliseconds: Int) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1000
        while ProcessInfo.processInfo.systemUptime < deadline {
            if CGS.isCurrent(space: destination) { return true }
            // 20 ms rather than 50: this poll sits directly in the latency the user feels
            // between letting go of ⌘ and the window appearing, and the check is one
            // `CGSCopyManagedDisplaySpaces` — cheap enough that the finer grain is free.
            try? await Task.sleep(for: .milliseconds(20))
        }
        return CGS.isCurrent(space: destination)
    }
}
