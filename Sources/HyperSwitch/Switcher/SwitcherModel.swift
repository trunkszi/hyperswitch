import CoreGraphics
import Observation

/// Everything the switcher panel draws, and the only place the selection moves.
///
/// The controller owns the session — hotkeys, timers, committing — and this owns the
/// *state* of that session. Keeping the two apart is what makes the switcher testable:
/// `dumpSwitcher` reads this object, and every assertion about "which card is selected
/// after two Tabs" is an assertion about ``step(_:)`` rather than about an event tap.
///
/// The two selection indices are `-1` when their row is empty and never index out of
/// range, whatever the caller assigns. That is enforced on *read*, not on write, so the
/// controller can set the list and the index in either order — a window vanishing under
/// an open panel (the user closed it with `W`, or an application quit) shrinks `windows`
/// without the controller having to remember to re-clamp anything.
@MainActor
@Observable
final class SwitcherModel {
    var mode: SwitcherMode = .allWindows
    var windows: [WindowInfo] = []
    var apps: [AppEntry] = []
    var focusRow: FocusRow = .windows
    var thumbnails: [CGWindowID: Thumbnail] = [:]
    var isVisible = false

    /// Interaction session state projected by the controller for the view.
    var isLatched = false
    var isSearching = false
    var isSearchLoading = false
    var query = ""
    var showsUsageHints = false
    var statusMessage: String?
    var visibleWindowRange: Range<Int> = 0..<0
    var windowGroups: [WindowGroup] = []

    /// The card under the pointer. Written by the tiles themselves; the controller reads
    /// it to decide what a click or a full-size preview refers to.
    var hoveredWindow: CGWindowID?

    /// Set while the keyboard is driving and the pointer has not moved since.
    ///
    /// It exists to break a feedback loop, not to express a preference. `step` clears the
    /// full-size preview because the keyboard has just spoken, clearing it re-fits the
    /// panel, and re-fitting moves every card out from under a pointer that never went
    /// anywhere — which SwiftUI reports as a fresh `onHover`. That hover requests another
    /// ~8 MB capture, the capture re-fits the panel again, and the pointer is "moved" onto
    /// another card once more. Holding ⌘ and pressing Tab a few times with the pointer
    /// resting on the panel was enough to keep the main thread in that loop indefinitely:
    /// the switcher stopped responding and the cursor became a spinner.
    ///
    /// So a hover only counts when the pointer actually moved. ``SwitcherController``
    /// raises this on every keyboard move and drops it as soon as its watchdog sees the
    /// pointer somewhere else.
    var ignoresPointer = false

    /// The window currently blown up over the panel, or `nil` for none.
    var fullSizeWindow: CGWindowID?

    /// The one high-resolution capture behind that preview, tagged with the window it
    /// belongs to.
    ///
    /// A single slot rather than an entry in ``thumbnails``. The full-size capture is
    /// requested at up to half the screen's width — measured at 1800 × 1126 px, roughly
    /// 8 MB — and it used to be written straight back into the thumbnail dictionary, where
    /// nothing ever swapped the small image back in. Hovering five cards in one session
    /// therefore left five 8 MB images alive until the *next* session's `reset`, which for
    /// a switcher the user is browsing slowly is exactly when they are least wanted. One
    /// slot means the previous one is released the moment another card is hovered, and the
    /// id keeps it honest: a stale image can never be drawn under a different window.
    var fullSizeImage: (id: CGWindowID, thumbnail: Thumbnail)?

    /// Snapshotted once per session so the panel's geometry and its contents cannot
    /// disagree halfway through.
    var appearance: SwitcherAppearance

    init() {
        appearance = SwitcherAppearance.current()
    }

    // MARK: - Selection

    private var storedSelectedWindow = -1
    private var storedSelectedApp = -1

    var selectedWindow: Int {
        get { resolve(storedSelectedWindow, count: windows.count) }
        set { storedSelectedWindow = newValue }
    }

    var selectedApp: Int {
        get { resolve(storedSelectedApp, count: apps.count) }
        set { storedSelectedApp = newValue }
    }

    var selectedWindowInfo: WindowInfo? {
        let index = selectedWindow
        guard windows.indices.contains(index) else { return nil }
        return windows[index]
    }

    var selectedAppEntry: AppEntry? {
        let index = selectedApp
        guard apps.indices.contains(index) else { return nil }
        return apps[index]
    }

    /// Brings a stored index back into range for the row it points into.
    ///
    /// A too-large index snaps to the last item rather than to `-1`: when the frontmost
    /// window of the row closes the user is still pointing at *something*, and dropping
    /// the selection entirely would make the next Tab start over from the beginning.
    /// A negative index stays negative, because "nothing selected" is a state the app
    /// switcher's window row genuinely has before an application is picked.
    private func resolve(_ index: Int, count: Int) -> Int {
        guard count > 0, index >= 0 else { return -1 }
        return min(index, count - 1)
    }

    // MARK: - Movement

    /// Moves the selection along the focused row, wrapping at both ends.
    ///
    /// Wrapping is not a nicety: the whole interaction is "hold the modifier and keep
    /// tapping Tab", and a selection that stops dead at the last card makes the user let
    /// go and start again to reach the first one.
    func step(_ delta: Int) {
        switch focusRow {
        case .apps:
            selectedApp = stepped(selectedApp, by: delta, count: apps.count)
        case .windows:
            selectedWindow = stepped(selectedWindow, by: delta, count: windows.count)
        }
    }

    private func stepped(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return -1 }
        // Nothing selected yet: forward lands on the first card, backward on the last —
        // which is what ⇧Tab means when you have not moved off the start of the row.
        guard index >= 0 else { return delta >= 0 ? 0 : count - 1 }
        return ((index + delta) % count + count) % count
    }

    /// Moves between the application row and the window row. Only `.appSwitcher` has both.
    ///
    /// Positive is downwards, matching the arrow key that produces it, and the rows are
    /// stacked applications-over-windows. Deliberately does *not* wrap: with two rows,
    /// wrapping makes ↓↓ return to where it started, which reads as the key not working.
    func moveRow(_ delta: Int) {
        guard mode == .appSwitcher, delta != 0 else { return }
        let target: FocusRow = delta > 0 ? .windows : .apps
        guard target != focusRow else { return }

        switch target {
        case .windows:
            // Refuse rather than land on an empty row: the selected application may have
            // no windows at all, and a focus ring on nothing leaves Return doing nothing.
            guard !windows.isEmpty else { return }
            if selectedWindow < 0 { selectedWindow = 0 }
        case .apps:
            guard !apps.isEmpty else { return }
            if selectedApp < 0 { selectedApp = 0 }
        }
        focusRow = target
    }

    // MARK: - Lifecycle

    /// Drops everything a finished session was holding.
    ///
    /// `mode` is left alone on purpose: it belongs to the session that is starting, and
    /// `begin(mode:…)` assigns it before anything is drawn. Clearing it here would only
    /// make a dump taken between sessions misreport which one just ended.
    ///
    /// Thumbnails are released here rather than kept warm for the next invocation. They
    /// are megabytes of `CGImage` per window and they go stale the moment the user does
    /// anything, so holding them buys a first frame that is often *wrong*.
    func reset() {
        windows = []
        apps = []
        storedSelectedWindow = -1
        storedSelectedApp = -1
        focusRow = .windows
        thumbnails = [:]
        isVisible = false
        isLatched = false
        isSearching = false
        isSearchLoading = false
        query = ""
        showsUsageHints = false
        statusMessage = nil
        visibleWindowRange = 0..<0
        windowGroups = []
        hoveredWindow = nil
        fullSizeWindow = nil
        fullSizeImage = nil
        // A new session starts listening to the pointer again: the user may well have
        // opened this one intending to browse with the mouse.
        ignoresPointer = false
        AppIcons.reset()
    }
}
