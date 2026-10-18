import AppKit
import CoreGraphics
import Foundation
import Observation

/// The switcher's session state machine.
///
/// One session runs from the hotkey going down to the modifier coming up. Everything that
/// makes that feel instant lives here, and all of it exists because of one measurement:
/// enumerating windows is asynchronous (an actor hop plus `CGWindowListCopyWindowInfo`),
/// while the user's second Tab can arrive within a few milliseconds of the first.
///
/// So the session is split in two. **Selection advances immediately**, against an offset
/// that is allowed to be out of range because nothing knows the range yet; the window list
/// is folded in when it lands and the offset is wrapped into it then. And **presentation is
/// delayed** by the user's chosen number of milliseconds, so releasing the modifier inside
/// that window is a "quick switch" that acts without ever drawing anything — which is the
/// entire meaning of the original's `window_switcher_delay = 80`.
///
/// Every asynchronous continuation is guarded by `session`, a counter bumped on both
/// `begin` and end. A capture, a window query or an auto-activation belonging to a session
/// the user has already left must not touch the model, and comparing tokens is cheaper and
/// harder to get wrong than trying to cancel every task individually.
@MainActor
final class SwitcherController {
    static let shared = SwitcherController()

    /// One model for the app's lifetime; sessions reset it rather than replace it, so the
    /// panel's hosting view never has to be rebuilt.
    let model = SwitcherModel()

    private lazy var panel = SwitcherPanel(model: model)

    private(set) var isActive = false
    private(set) var activeModifier: ModifierCombo = []

    private var session = 0

    /// When the previous session ended, for the app switcher's first/subsequent delays.
    private var lastSessionEnded: Date?

    /// The screen this session is drawn on. Resolved once at `begin`, because the
    /// preference can name "the screen with the mouse" and the pointer must not be able to
    /// move the panel out from under itself mid-session.
    private var currentScreen: NSScreen?

    /// True once the window row's contents are known. Until then `step` accumulates into
    /// `pendingOffset` instead of moving a selection through an array that is still empty.
    private var windowsLoaded = false
    private var pendingOffset = 0

    /// The unfiltered window set for the current row/session.
    private var sourceWindows: [WindowInfo] = []
    /// The app switcher's all-window search source. Kept separate so clearing a query can
    /// restore the selected application's ordinary preview row without another query.
    private var searchWindows: [WindowInfo] = []
    private var interaction = SwitcherInteractionState()
    private var quitConfirmation = QuitConfirmationState()
    private var searchSourceLoaded = false

    /// True between a `relayout()` request and the coalesced pass that satisfies it.
    private var relayoutScheduled = false

    /// Whether *this* session has drawn the panel yet.
    ///
    /// Deliberately not `panel.isVisible`: the previous session's 0.12 s fade leaves that
    /// true, so a new session whose window list happened to arrive early would relayout —
    /// and therefore order the panel back in — before its own activation delay had run,
    /// making every quick switch that followed another one flash a panel it never asked
    /// for. It also stops a late relayout resurrecting a panel that is on its way out.
    private var hasPresented = false

    /// Enough to re-run this session's window query after the session has ended.
    ///
    /// The quick switch — press and release inside the activation delay, which at the
    /// shipping 80 ms is the *common* case rather than an edge one — commits before the
    /// list has arrived. Without these, `commit` found an empty array and did nothing at
    /// all: measured, a 250 ms press left the front window exactly where it was.
    private var pendingQuery: WindowQuery?
    private var pendingPID: pid_t?

    private var showTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var autoActivateTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchApplyTask: Task<Void, Never>?
    private var quitConfirmationTask: Task<Void, Never>?

    /// The raise a commit dispatched, held only so the *next* commit can cancel it.
    ///
    /// A finished raise is not a finished operation. `AXCore.raise` hunts for the window
    /// for up to 12 × 60 ms and then `confirmFrontmost` re-asserts `kAXFrontmost` over
    /// three rounds of ~320 ms, so it keeps writing to the front-most attribute for
    /// roughly 1.6 s after it was asked to. Switch twice inside that window and the first
    /// raise pulls its own target back over the second one's — measured as "the app I just
    /// picked loses focus a second later". Cancelling collapses the old one's sleeps and
    /// the token check in ``raise(_:token:)`` stops its fallback firing after the fact.
    private var raiseTask: Task<Void, Never>?

    /// Ends a session whose modifier was released without us being told.
    ///
    /// Reported by a user and reproduced: swipe up with three fingers while a session is
    /// running and Mission Control takes over event routing, so the `flagsChanged` that
    /// would have ended the session never arrives. `isActive` then stays true forever —
    /// and because `HotKeyMonitor` swallows *every* key while a session is active, the
    /// keyboard goes completely dead, with no visible panel to explain why. The same hole
    /// is reachable any way the event stream can be interrupted: a Space switch, the
    /// screen locking, secure input starting.
    ///
    /// So the end of a session cannot depend on receiving an event. This polls the actual
    /// hardware modifier state, which `NSEvent.modifierFlags` reports whether or not any
    /// event reached us.
    private var watchdog: Timer?

    /// Consecutive polls that found the modifier released. See ``checkStillHeld()``.
    private var modifierMisses = 0

    /// Where the pointer was when the keyboard last took over.
    ///
    /// Paired with ``SwitcherModel/ignoresPointer``: hovers are ignored until the pointer is
    /// found somewhere other than here, which is what distinguishes a person moving the
    /// mouse from the panel re-fitting itself underneath a stationary one.
    private var pointerAnchor: CGPoint?

    /// How far the pointer must travel to start counting again.
    ///
    /// The same 6 pt as `HoverIntentTracker.stableRadius`, and for the same reason: below
    /// that, a reading is hand tremor or the pointer being nudged by the cursor's own
    /// hot-spot, not an intention to look at something.
    private static let pointerWakeDistance: CGFloat = 6

    /// How long after `begin` the modifier poll is not consulted at all.
    ///
    /// The watchdog and `handleTrigger` do not share a source of truth: the trigger
    /// matches the flags carried *on the event*, the watchdog reads the real HID state.
    /// A hotkey synthesised by a remapper (Karabiner-Elements, Keyboard Maestro,
    /// BetterTouchTool) carries modifier flags on an event whose modifier was never
    /// physically pressed, so the two disagree from the first poll onwards and the
    /// session was cancelled ~120 ms in — the hotkey simply did nothing. A modifier a
    /// human is actually holding is still held 250 ms later, so nothing real is lost.
    private static let watchdogGracePeriod: TimeInterval = 0.25

    /// When `begin` ran. Consulted by the grace period above and by the absolute ceiling
    /// below, and by nothing else.
    private var sessionStarted: Date?

    /// When the user last did anything. A second field rather than a rolling
    /// `sessionStarted`, because the two answer different questions and merging them
    /// breaks the other one: `watchdogGracePeriod`'s contract is "250 ms from `begin`", so
    /// renewing that timestamp on every pointer move would hold the modifier poll off for
    /// the whole of a mouse browse — and that poll is the only thing that ends a session
    /// whose release event never arrived.
    private var lastInteraction: Date?

    /// A backstop for the case where even the modifier state lies — a stuck physical key,
    /// or a session begun by a synthetic event that never had a modifier to release.
    ///
    /// Measured from the last input rather than from `begin`. What both of those cases
    /// have in common is that *nothing arrives at all*, and a wall clock started at
    /// `begin` cannot tell them apart from someone actually reading the panel: the
    /// full-size preview delay alone goes up to 5 s, so three or four hovered cards used
    /// to cross this line. The session was then cancelled under the user's fingers — the
    /// panel faded out unprompted and the release that was meant to commit switched
    /// nothing, because `HotKeyMonitor` found `isActive` already false.
    private static let maximumIdleLifetime: TimeInterval = 20
    private static let maximumLatchedIdleLifetime: TimeInterval = 60

    /// And a ceiling that no amount of input can renew, because hover renews on every
    /// pointer twitch and a stuck physical modifier leaves the panel sitting under the
    /// pointer. Without it, making the limit idle-based would delete the backstop rather
    /// than narrow it.
    private static let maximumSessionLifetime: TimeInterval = 300

    private var spaceObserver: (any NSObjectProtocol)?

    /// Watches for a click anywhere outside the panel while the session is latched.
    ///
    /// A latched session has, by design, no modifier whose release can end it, and the
    /// event tap goes on swallowing every key for as long as it is open. Its exits were
    /// Escape, Return, a Space change and the 60 s idle backstop — none of which is what
    /// a person does when they simply walk away from the panel and click into another
    /// application, or into the Dock. The panel then sat there and ate everything they
    /// typed for up to a minute.
    ///
    /// A global monitor is exactly the right shape: it is told about events bound for
    /// *other* processes only, so a click on one of our own cards — which is how the
    /// pointer picks a window — never reaches it. Only while latched, because an unlatched
    /// session is held open by a modifier the user is pressing and ends when they let go.
    ///
    /// Clicks rather than activation changes: this app's own actions activate other
    /// applications mid-session — the auto-activate preview, quitting the selected
    /// application — and reacting to those would close the panel under the very key that
    /// was meant to keep it open.
    private var outsideClickMonitor: Any?

    private init() {
        // Mission Control and a Space switch both end the session outright rather than
        // committing it: we may have missed keystrokes in between, and raising a window
        // the user did not choose is worse than doing nothing.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard SwitcherController.shared.isActive else { return }
                Log.switcher.debug("space changed while a session was open; cancelling")
                SwitcherController.shared.cancel()
            }
        }
    }

    var panelWindowNumber: Int? { panel.windowNumber }

    /// Whether the panel is on screen and, if so, whether it is swallowing clicks.
    var panelState: (onScreen: Bool, clickThrough: Bool, alpha: Double) {
        (panel.isVisible, panel.isClickThrough, panel.alpha)
    }

    var isLatched: Bool { interaction.isLatched }
    var isSearching: Bool { interaction.isSearching }

    // MARK: - Session

    /// Starts a session. Returns immediately; the panel appears later, or never.
    func begin(mode: SwitcherMode, modifier: ModifierCombo, backwards: Bool) {
        // Two hotkeys can overlap — ⌥Tab held while ⌘Tab is pressed. Retiring the old
        // session rather than ignoring the new one keeps the panel showing whatever the
        // user last asked for, and `.none` because a fade between two live sessions reads
        // as a glitch rather than as an animation.
        if isActive { endSession(animation: .none) }

        session &+= 1
        let token = session
        isActive = true
        activeModifier = modifier
        windowsLoaded = false
        hasPresented = false
        sourceWindows = []
        searchWindows = []
        interaction.reset()
        quitConfirmation.reset()
        searchSourceLoaded = mode != .appSwitcher

        // No display at all — a clamshell closing mid-hotkey, a dock dropping out, screen
        // sharing tearing down. There is nowhere to draw and nothing to switch between, so
        // the session is abandoned rather than started against a fabricated screen. It
        // must also not be left half-open: `isActive` is already true by this point and
        // would otherwise have the event tap swallowing every key.
        guard let screen = Preferences.shared.switcherScreen.screen else {
            Log.switcher.error("no screen available; abandoning the session")
            isActive = false
            activeModifier = []
            return
        }
        currentScreen = screen

        model.reset()
        model.mode = mode
        model.appearance = SwitcherAppearance.current(screen: screen)

        switch mode {
        case .appSwitcher:
            beginAppSwitcher(token: token, backwards: backwards, screen: screen)
        case .allWindows, .currentApp:
            beginWindowSwitcher(mode: mode, token: token, backwards: backwards, screen: screen)
        }

        scheduleShow(mode: mode, token: token)
        scheduleAutoActivate(mode: mode, token: token)
        watchHover(token: token)
        startWatchdog()
        publishHotKeyState()

        Log.switcher.debug("begin mode=\(mode.rawValue, privacy: .public) backwards=\(backwards)")
    }

    private func beginWindowSwitcher(mode: SwitcherMode,
                                     token: Int,
                                     backwards: Bool,
                                     screen: NSScreen) {
        model.focusRow = .windows

        // The advance happens now, on the keypress, not when the list arrives. Index 1 is
        // "the window after the frontmost one", which is what a single Tab means; -1 wraps
        // to the last once the count is known.
        pendingOffset = backwards ? -1 : 1
        model.selectedWindow = pendingOffset

        let query = WindowQuery.current(screen: screen)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // There is no current application to ask about. `frontmostApplication` is
        // documented to go nil while the front application terminates and nothing has
        // replaced it yet, so ⌘Q followed immediately by ⌥` lands in exactly that gap.
        //
        // Leaving `pendingQuery` set here is what made that gap dangerous: it handed
        // `commit`'s unresolved branch a non-nil query with a nil pid, and that pair is
        // precisely how `.allWindows` is encoded. The release then resolved the offset
        // against *every window on the system* and raised one the user had never seen,
        // under a panel that was reading "No Windows". Clearing both is the same rule
        // `loadWindowsForSelectedApp` already applies to an empty row.
        guard mode != .currentApp || frontmost != nil else {
            Log.switcher.debug("current-app switcher: no frontmost application")
            pendingQuery = nil
            pendingPID = nil
            // Known-empty rather than still loading, so `commit` takes the resolved path
            // and finds nothing to raise. It changes nothing on screen: `windowsLoaded` is
            // private to the controller and the panel draws its empty row off
            // `model.windows` either way.
            windowsLoaded = true
            loadTask?.cancel(); loadTask = nil
            return
        }

        // nil means "every window on the system", which is what `.allWindows` wants. The
        // load below branches on this same value rather than on `mode`, so what was stored
        // for `commit` and what was actually enumerated cannot drift apart.
        let pid: pid_t? = mode == .currentApp ? frontmost : nil
        pendingQuery = query
        pendingPID = pid

        loadTask?.cancel()
        loadTask = Task {
            let windows: [WindowInfo]
            if let pid {
                windows = await WindowIndex.shared.windows(forPID: pid, query)
            } else {
                windows = await WindowIndex.shared.allWindows(query)
            }
            guard !Task.isCancelled, self.session == token, self.isActive else { return }
            self.adopt(windows: windows)
        }
    }

    private func beginAppSwitcher(token: Int, backwards: Bool, screen: NSScreen) {
        // The application row is available synchronously — `AppList` keeps it in MRU order
        // from workspace notifications — so ⌘Tab draws its top row with no latency at all
        // and only the previews below it wait on anything.
        let apps = AppList.shared.switcherApps()
        model.apps = apps
        model.focusRow = .apps
        model.selectedApp = apps.isEmpty
            ? -1
            : (backwards ? apps.count - 1 : min(1, apps.count - 1))

        let query = WindowQuery.current(screen: screen)
        Task {
            let counts = await WindowIndex.shared.windowCounts(query)
            guard self.session == token, self.isActive else { return }
            // `switcherApps()` cannot know the counts: they depend on the include-other-
            // Spaces / other-screens preferences, which are a window-index question.
            self.model.apps = self.model.apps.map { entry in
                AppEntry(pid: entry.pid,
                         name: entry.name,
                         bundleIdentifier: entry.bundleIdentifier,
                         windowCount: counts[entry.pid] ?? 0)
            }
        }

        loadWindowsForSelectedApp(token: token)
    }

    // MARK: - Content

    /// Folds a freshly enumerated window list into the model and resolves the selection
    /// that was made before the list existed.
    private func adopt(windows: [WindowInfo]) {
        sourceWindows = windows
        let candidates = interaction.isSearching
            && model.mode == .appSwitcher
            && searchSourceLoaded
            ? searchWindows
            : windows
        let visible = interaction.isSearching
            ? SwitcherSearch.filter(candidates, query: interaction.query)
            : windows
        model.windows = visible
        model.selectedWindow = wrapped(pendingOffset, count: visible.count)
        windowsLoaded = true
        refreshDerivedContent()

        // `hasPresented`, not `panel.isVisible`: the latter is still true throughout the
        // previous session's fade, and capturing plus relaying out then would put the
        // panel on screen ahead of this session's activation delay — the delay whose
        // whole purpose is that a quick switch draws nothing at all.
        if hasPresented {
            captureThumbnails()
            relayout()
        }
    }

    /// Refills the lower row with the currently selected application's windows.
    ///
    /// Runs on every move along the application row: the row *is* "the selected app's
    /// windows", so keeping a previous app's previews under a new icon would be a lie.
    private func loadWindowsForSelectedApp(token: Int) {
        // Every move along the application row starts the lower row over at its first
        // window, so ↓ always lands on something predictable.
        pendingOffset = 0

        guard let app = model.selectedAppEntry else {
            sourceWindows = []
            model.windows = []
            model.selectedWindow = -1
            refreshDerivedContent()
            windowsLoaded = true
            // Nothing for `commit` to re-run: this row is known to be empty, and leaving a
            // previous application's pid behind would have it resolve against that.
            pendingQuery = nil
            pendingPID = nil
            return
        }

        windowsLoaded = false
        // `currentScreen` was pinned at `begin`, which refuses to start without one, so
        // this can only be nil for a session that no longer exists.
        guard let screen = currentScreen else { return }
        let query = WindowQuery.current(screen: screen)

        // What `commit` re-runs when the modifier is released before this lands. ⌘Tab
        // never recorded them, so a release taken while the row was still refilling fell
        // back to `model.selectedWindowInfo` — which at that instant still holds the
        // *previous* application's windows, and raised one of those instead.
        pendingQuery = query
        pendingPID = app.pid

        loadTask?.cancel()
        loadTask = Task {
            let windows = await WindowIndex.shared.windows(forPID: app.pid, query)
            guard !Task.isCancelled, self.session == token, self.isActive,
                  self.model.selectedAppEntry?.pid == app.pid
            else { return }
            self.adopt(windows: windows)
        }
    }

    private func captureThumbnails() {
        let range = model.visibleWindowRange.clamped(to: model.windows.indices)
        let windows = Array(model.windows[range])
        guard !windows.isEmpty else { return }

        let token = session
        // Points to pixels for the display the panel is actually on. On a mixed-density
        // setup — a Retina laptop beside a 1× external — using the wrong screen's scale
        // gives either a soft thumbnail or twice the pixels needed.
        let scale = (currentScreen ?? NSScreen.main)?.backingScaleFactor ?? 2
        let width = model.appearance.thumbnailWidth * scale
        let quality = Preferences.shared.thumbnailQuality

        thumbnailTask?.cancel()
        thumbnailTask = Task { [self] in
            await ThumbnailEngine.shared.capture(windows, targetWidth: width, quality: quality) { id, thumbnail in
                // `onReady` is called from the capture actor, four captures in flight, and
                // is deliberately not isolated — hopping here is what keeps the model
                // single-threaded while tiles still fill in one by one instead of all at
                // the end.
                Task { @MainActor in
                    guard self.session == token,
                          self.model.windows.contains(where: { $0.id == id })
                    else { return }
                    self.model.thumbnails[id] = thumbnail
                }
            }
        }
    }

    // MARK: - Presentation

    private func scheduleShow(mode: SwitcherMode, token: Int) {
        let delay = displayDelay(for: mode)

        showTask?.cancel()
        showTask = Task {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            // Released inside the delay: the session is already over and this is exactly
            // the quick switch the delay exists to allow. Drawing now would flash a panel
            // after the switch has happened.
            guard !Task.isCancelled, self.session == token, self.isActive else { return }
            self.present()
        }
    }

    private func displayDelay(for mode: SwitcherMode) -> Int {
        let preferences = Preferences.shared
        guard mode == .appSwitcher else {
            return max(0, preferences.windowSwitcherDelay)
        }
        // "Subsequent" means the user is evidently browsing rather than flicking between
        // two applications. 1.5 s is the same window the original used to decide that.
        let recent = lastSessionEnded.map { Date().timeIntervalSince($0) < 1.5 } ?? false
        return max(0, recent ? preferences.appSwitcherDelaySubsequent
                             : preferences.appSwitcherDelayFirst)
    }

    // MARK: - Watchdog

    /// Polls the real modifier state for as long as a session is open.
    ///
    /// 120 ms, and cheap enough to be irrelevant — it only runs while a switcher session is
    /// actually open, which is a few hundred milliseconds at a time. An orphaned session
    /// therefore ends within roughly half a second: the 250 ms grace period, then the two
    /// consecutive misses `checkStillHeld` insists on. Still well before a person can type
    /// a second character into the void, which is the bar this has to clear.
    private func startWatchdog() {
        sessionStarted = Date()
        lastInteraction = sessionStarted
        modifierMisses = 0
        watchdog?.invalidate()

        // Built by hand rather than with `Timer.scheduledTimer`, which installs only into
        // `.default`. The event tap runs in `.commonModes` and goes on swallowing every
        // key inside a nested run loop, so with the watchdog in `.default` alone it stalls
        // for exactly as long as a status-bar menu is tracked (NSEventTrackingRunLoopMode)
        // or an alert is up (NSModalPanelRunLoopMode) — the two places a wedged session is
        // most likely to be hiding, and the two where the keyboard being dead is least
        // explicable. It recovers when the nested loop exits, but "recovers eventually" is
        // not what a watchdog is for. `.common` covers all three modes, and the two
        // lifetime backstops ride the same timer.
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStillHeld() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkStillHeld() {
        guard isActive else {
            watchdog?.invalidate()
            watchdog = nil
            return
        }

        releasePointerSuppressionIfMoved()

        let idleLimit = interaction.isLatched
            ? Self.maximumLatchedIdleLifetime
            : Self.maximumIdleLifetime
        if let last = lastInteraction,
           Date().timeIntervalSince(last) > idleLimit {
            Log.switcher.error("session idle past its maximum lifetime; cancelling")
            cancel()
            return
        }

        if let started = sessionStarted,
           Date().timeIntervalSince(started) > Self.maximumSessionLifetime {
            Log.switcher.error("session exceeded its absolute lifetime; cancelling")
            cancel()
            return
        }

        // Mission Control, entered while the modifier is *still held*. The modifier poll
        // below cannot see this one — nothing has been released — but the panel sits at
        // `.popUpMenu` level, above Mission Control's own overlay, and takes the clicks
        // aimed at the windows it is showing.
        if panel.isVisible, Self.missionControlIsUp() {
            Log.switcher.debug("Mission Control appeared over the panel; cancelling")
            cancel()
            return
        }

        // An empty combo means the session was opened without a modifier to hold; there is
        // nothing whose release could end it, so the poll below has nothing to say.
        guard !interaction.isLatched, !activeModifier.isEmpty else { return }

        // The poll and the trigger read different things — real HID state here, the flags
        // carried on the event there — so a remapper-synthesised hotkey looks "already
        // released" from the very first sample and the session killed itself before the
        // panel could appear. See `watchdogGracePeriod`.
        if let started = sessionStarted,
           Date().timeIntervalSince(started) < Self.watchdogGracePeriod { return }

        // NSEvent.modifierFlags reads the current hardware state rather than the last
        // event we were handed, which is the entire point: the event may never arrive.
        // The two flag types share raw values for every mask used here.
        let current = CGEventFlags(rawValue: UInt64(NSEvent.modifierFlags.rawValue))
        if activeModifier.isSatisfied(by: current) {
            modifierMisses = 0
            return
        }

        // Two consecutive misses, not one — the same rule as HyperDock's presence
        // watchdog. This sample is taken asynchronously from the WindowServer and a single
        // one of them reading empty is not evidence the user let go; a genuine release
        // stays released, so the cost is one extra 120 ms tick and the benefit is that a
        // transient blip cannot tear down a live session under the user's fingers.
        modifierMisses += 1
        guard modifierMisses >= 2 else { return }

        // Reached only when the release event went missing. Cancel rather than commit:
        // whatever swallowed the release may have swallowed keystrokes too, so the
        // selection on screen is not reliably the one the user last chose.
        Log.switcher.debug("modifier released without an event; cancelling the session")
        cancel()
    }

    /// Lets the pointer start counting again, once it has actually gone somewhere.
    ///
    /// Polled rather than driven by an event because the question is "has the mouse moved?",
    /// and the events that would answer it are exactly the ones that cannot be trusted here
    /// — `onHover` fires from our own relayout. `NSEvent.mouseLocation` reads the real
    /// position, and 120 ms is far below the point at which a person notices that their
    /// pointer has taken effect.
    private func releasePointerSuppressionIfMoved() {
        guard model.ignoresPointer, let anchor = pointerAnchor else { return }
        guard PointerSuppression.shouldRelease(anchor: anchor,
                                               current: NSEvent.mouseLocation,
                                               beyond: Self.pointerWakeDistance)
        else { return }
        model.ignoresPointer = false
        pointerAnchor = nil
    }

    /// Records that a person is still driving this session, renewing the idle backstop.
    ///
    /// Every real input funnels through here rather than touching `sessionStarted`, which
    /// has to keep meaning "since `begin`" for the watchdog's grace period.
    private func noteInteraction() {
        lastInteraction = Date()
    }

    /// True while Mission Control (or Application Windows / Spaces) owns the screen.
    ///
    /// There is no notification for this and the frontmost application does not change —
    /// measured, it stayed `Finder` throughout. What does change is the Dock's own window
    /// list, since the Dock is what draws the overlay:
    ///
    ///     baseline           Dock owns only its wallpaper window (layer -2147483624)
    ///     Mission Control    …plus a full-screen window at **layer 18**, and two at 20
    ///
    /// Layer 18 is the discriminator. The Dock's ordinary strip is layer 20 and its
    /// `CGWindow` bounds are the whole display rather than the strip, so layer 20 alone
    /// cannot tell the two apart on a Mac whose Dock is not hidden.
    ///
    /// `CGWindowListCopyWindowInfo` costs ~4 ms and this only runs while a session is
    /// open, which is a few hundred milliseconds at a time.
    nonisolated static func missionControlIsUp() -> Bool {
        // `.optionOnScreenOnly` alone. Adding `.excludeDesktopElements` — which looks
        // harmless — filters the layer-18 overlay right back out again, and the check
        // silently never fires. Verified both ways.
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }

        let screen = CGDisplayBounds(CGMainDisplayID())
        let area = screen.width * screen.height
        guard area > 0 else { return false }

        for entry in raw {
            guard (entry[kCGWindowOwnerName as String] as? String) == "Dock",
                  (entry[kCGWindowLayer as String] as? Int) == 18,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let coverage = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0) / area
            if coverage > 0.9 { return true }
        }
        return false
    }

    private func present() {
        guard let screen = currentScreen else { return }
        hasPresented = true
        model.isVisible = true
        interaction.markPresented(at: ProcessInfo.processInfo.systemUptime)
        projectInteractionState()
        scheduleUsageHints(token: session)
        refreshDerivedContent()
        panel.show(on: screen)
        captureThumbnails()
    }

    /// Re-measures and re-centres the panel after the content changed shape — a window
    /// closed out of the row, a different application selected, the full-size preview
    /// appearing. Without it the panel keeps its old frame and the content is either
    /// clipped or floating in a hole.
    ///
    /// Gated on `hasPresented` and not on `panel.isVisible` alone, because `show(on:)`
    /// supersedes a hide that is still fading: a relayout arriving from a session that has
    /// not presented — or after this one ended — would order the dying panel back in at
    /// full opacity, and nothing left in the system would ever take it down again.
    /// Coalesced to one per run-loop turn.
    ///
    /// A single `step` asks for three: `clearHoverState` drops the preview, then
    /// `selectionDidChange` moves the highlight, then the window list lands in `adopt`.
    /// Each one used to run a full synchronous `layoutSubtreeIfNeeded` + `fittingSize`
    /// through `SwitcherPanel.show`, so holding Tab down paid for the panel's entire layout
    /// three times per keystroke — with an ~8 MB preview image in the tree for two of them.
    ///
    /// Deferring is safe because the alternative is not "the panel updates sooner", it is
    /// "the panel is measured against a model that is about to change again". The first
    /// appearance is unaffected: `present()` calls `panel.show` directly.
    private func relayout() {
        guard hasPresented, panel.isVisible, currentScreen != nil else { return }
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.relayoutScheduled = false
                // Re-checked rather than captured: between scheduling and running, the
                // session can have ended and the panel started fading. Ordering it back in
                // here is the "permanently visible, permanently unresponsive rectangle"
                // that `hasPresented` exists to prevent.
                guard self.hasPresented, self.panel.isVisible,
                      let screen = self.currentScreen else { return }
                self.panel.show(on: screen)
            }
        }
    }

    // MARK: - Interaction features

    /// Mirrors the pure interaction reducer into observable view state.
    private func projectInteractionState() {
        model.isLatched = interaction.isLatched
        model.isSearching = interaction.isSearching
        model.query = interaction.query
        model.showsUsageHints = interaction.showsUsageHints
    }

    private func scheduleUsageHints(token: Int) {
        hintTask?.cancel()
        guard model.appearance.showUsageHints else { return }
        hintTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, self.session == token, self.isActive,
                  self.hasPresented else { return }
            self.interaction.refreshHints(
                at: ProcessInfo.processInfo.systemUptime,
                enabled: self.model.appearance.showUsageHints
            )
            self.projectInteractionState()
            self.relayout()
        }
    }

    /// Recomputes only what the current panel frame draws.
    private func refreshDerivedContent() {
        let count = model.windows.count
        let capacity = model.appearance.visibleWindowCapacity
        if model.appearance.keepSelectionCentered {
            model.visibleWindowRange = CenteredSlice.range(
                count: count,
                selected: model.selectedWindow,
                capacity: capacity
            )
        } else if count > 0 {
            let selected = min(max(model.selectedWindow, 0), count - 1)
            let pageStart = (selected / capacity) * capacity
            model.visibleWindowRange = pageStart..<min(pageStart + capacity, count)
        } else {
            model.visibleWindowRange = 0..<0
        }

        let range = model.visibleWindowRange.clamped(to: model.windows.indices)
        let visible = Array(model.windows[range])
        let shouldGroup = model.appearance.groupLongLists
            && !interaction.isSearching
            && model.windows.count >= model.appearance.searchThreshold
        model.windowGroups = WindowGrouping.groups(
            visible,
            threshold: shouldGroup ? 1 : .max
        )
    }

    @discardableResult
    func toggleLatch() -> Bool {
        guard isActive else { return false }
        noteInteraction()
        clearHoverState()
        clearQuitConfirmation()

        let latched = interaction.toggleLatch(allowed: model.appearance.latchedModeEnabled)
        projectInteractionState()
        if latched { watchForOutsideClicks() } else { stopWatchingOutsideClicks() }
        if latched, !hasPresented { present() }
        if !latched {
            let currentFlags = CGEventFlags(rawValue: UInt64(NSEvent.modifierFlags.rawValue))
            if !activeModifier.isEmpty, !activeModifier.isSatisfied(by: currentFlags) {
                cancel()
                return false
            }
        }
        relayout()
        return latched
    }

    private func watchForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            MainActor.assumeIsolated {
                let controller = SwitcherController.shared
                guard controller.isActive, controller.isLatched else { return }
                Log.switcher.debug("clicked outside a latched panel; cancelling")
                controller.cancel()
            }
        }
    }

    private func stopWatchingOutsideClicks() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    /// Printable text is meaningful only after the session has been pinned.
    @discardableResult
    func handleSearchText(_ text: String) -> Bool {
        guard isActive else { return false }
        let candidateCount = max(
            sourceWindows.count,
            max(model.apps.count, model.apps.reduce(0) { $0 + $1.windowCount })
        )
        guard interaction.appendSearchText(
            text,
            candidateCount: candidateCount,
            threshold: model.appearance.searchThreshold
        ) else { return false }

        noteInteraction()
        clearHoverState()
        clearQuitConfirmation()
        projectInteractionState()
        prepareSearchSourceIfNeeded()
        scheduleSearchResults()
        return true
    }

    @discardableResult
    func beginSearch(explicit: Bool = false) -> Bool {
        guard isActive else { return false }
        let candidateCount = max(
            sourceWindows.count,
            max(model.apps.count, model.apps.reduce(0) { $0 + $1.windowCount })
        )
        guard interaction.beginSearch(
            candidateCount: candidateCount,
            threshold: model.appearance.searchThreshold,
            explicit: explicit
        ) else { return false }
        noteInteraction()
        clearQuitConfirmation()
        projectInteractionState()
        prepareSearchSourceIfNeeded()
        scheduleSearchResults()
        return true
    }

    func deleteSearchCharacter() {
        guard isActive, interaction.isSearching else { return }
        noteInteraction()
        clearQuitConfirmation()
        interaction.deleteSearchCharacter()
        projectInteractionState()
        if interaction.isSearching {
            scheduleSearchResults()
        } else {
            restoreNormalContentAfterSearch()
        }
    }

    func handleEscape() {
        guard isActive else { return }
        noteInteraction()
        clearQuitConfirmation()
        switch interaction.escape() {
        case .clearedSearch:
            projectInteractionState()
            restoreNormalContentAfterSearch()
        case .cancelSession:
            cancel()
        }
    }

    private func prepareSearchSourceIfNeeded() {
        guard model.mode == .appSwitcher, !searchSourceLoaded,
              searchTask == nil, let screen = currentScreen else { return }
        let token = session
        let query = WindowQuery.current(screen: screen)
        model.isSearchLoading = true
        searchTask = Task {
            let windows = await WindowIndex.shared.allWindows(query)
            guard !Task.isCancelled, self.session == token, self.isActive,
                  self.interaction.isSearching else { return }
            self.searchWindows = windows
            self.searchSourceLoaded = true
            self.model.isSearchLoading = false
            self.searchTask = nil
            self.scheduleSearchResults()
        }
    }

    /// Coalesces typing and keeps the linear filter out of the event-tap callback. The
    /// detached task receives only immutable, Sendable values; session and query checks
    /// prevent a late result from changing a newer search or a closed switcher.
    private func scheduleSearchResults() {
        guard interaction.isSearching else { return }
        searchApplyTask?.cancel()
        let token = session
        let query = interaction.query
        let candidates = model.mode == .appSwitcher && searchSourceLoaded
            ? searchWindows
            : sourceWindows
        searchApplyTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            let filtered = await Task.detached(priority: .userInitiated) {
                SwitcherSearch.filter(candidates, query: query)
            }.value
            guard !Task.isCancelled, self.session == token, self.isActive,
                  self.interaction.isSearching, self.interaction.query == query
            else { return }
            self.searchApplyTask = nil
            self.applySearchResults(filtered)
        }
    }

    private func applySearchResults(_ filtered: [WindowInfo]) {
        guard interaction.isSearching else { return }
        let selectedID = model.selectedWindowInfo?.id
        model.windows = filtered
        model.focusRow = .windows
        if let selectedID,
           let preserved = model.windows.firstIndex(where: { $0.id == selectedID }) {
            model.selectedWindow = preserved
        } else {
            model.selectedWindow = model.windows.isEmpty ? -1 : 0
        }
        windowsLoaded = true
        refreshDerivedContent()
        if hasPresented {
            captureThumbnails()
            relayout()
        }
    }

    /// Leaves search without discarding either source. In app-switcher mode this restores
    /// the two-row app view immediately; a later character can reuse an already-loaded
    /// all-window source, while an unfinished search load is cancelled and restarted only
    /// if the user searches again.
    private func restoreNormalContentAfterSearch() {
        searchApplyTask?.cancel()
        searchApplyTask = nil
        if !searchSourceLoaded {
            searchTask?.cancel()
            searchTask = nil
            searchWindows = []
        }
        model.isSearchLoading = false

        let selectedID = model.selectedWindowInfo?.id
        model.windows = sourceWindows
        if model.mode == .appSwitcher {
            model.focusRow = .apps
        } else {
            model.focusRow = .windows
        }
        if let selectedID,
           let preserved = model.windows.firstIndex(where: { $0.id == selectedID }) {
            model.selectedWindow = preserved
        } else {
            model.selectedWindow = model.windows.isEmpty ? -1 : 0
        }
        windowsLoaded = true
        refreshDerivedContent()
        if hasPresented {
            captureThumbnails()
            relayout()
        }
    }

    private func selectionDidChange() {
        let clearedStatus = clearQuitConfirmation()
        refreshDerivedContent()
        if hasPresented {
            captureThumbnails()
            if clearedStatus { relayout() }
        }
    }

    @discardableResult
    private func clearQuitConfirmation() -> Bool {
        let clearedStatus = model.statusMessage != nil
        quitConfirmation.reset()
        quitConfirmationTask?.cancel()
        quitConfirmationTask = nil
        model.statusMessage = nil
        return clearedStatus
    }

    // MARK: - Navigation

    func step(_ delta: Int) {
        guard isActive else { return }
        noteInteraction()

        // The pointer and the keyboard must not disagree about what is selected, and the
        // keyboard is what just spoke.
        clearHoverState()

        if model.mode == .appSwitcher, model.focusRow == .apps {
            clearQuitConfirmation()
            model.step(delta)
            // The lower row *is* "the selected application's windows"; leaving the previous
            // application's previews under a new icon would be a lie. The panel re-fits
            // itself when they land, not now — resizing twice per keypress reads as a
            // stutter.
            loadWindowsForSelectedApp(token: session)
            return
        }

        if windowsLoaded {
            model.step(delta)
            selectionDidChange()
        } else {
            // Still waiting on the enumeration. Accumulating here is what makes three fast
            // Tabs land three windows along instead of one.
            pendingOffset += delta
            model.selectedWindow = pendingOffset
        }
    }

    func moveRow(_ delta: Int) {
        guard isActive, model.mode == .appSwitcher else { return }
        if interaction.isSearching {
            step(delta)
            return
        }
        noteInteraction()
        clearHoverState()
        // No clamping afterwards: `SwitcherModel.moveRow` refuses to land on an empty row
        // and seeds the index itself when it does move.
        model.moveRow(delta)
        selectionDidChange()
    }

    /// Picks a card with the pointer.
    ///
    /// A click on a switcher means "this one", so it moves the selection and commits in one
    /// go rather than merely highlighting — a switcher that needed a click *and* a Return
    /// would be slower than the keyboard it replaces.
    func select(window: WindowInfo) {
        guard isActive, let index = model.windows.firstIndex(where: { $0.id == window.id })
        else { return }
        model.focusRow = .windows
        model.selectedWindow = index
        clearQuitConfirmation()
        commit()
    }

    func select(app: AppEntry) {
        guard isActive, let index = model.apps.firstIndex(where: { $0.pid == app.pid })
        else { return }
        model.focusRow = .apps
        model.selectedApp = index
        clearQuitConfirmation()
        commit()
    }

    private func clearHoverState() {
        hoverTask?.cancel()
        // Every caller is a keyboard move, and clearing the preview is about to re-fit the
        // panel — which slides the cards out from under a pointer that has not moved. Until
        // it does move, its hovers are an artefact of our own relayout and must not start
        // another capture. See `SwitcherModel.ignoresPointer`.
        model.ignoresPointer = true
        pointerAnchor = NSEvent.mouseLocation
        model.hoveredWindow = nil
        // Dropped ahead of the early return, and unconditionally: this is the megabyte-
        // sized capture, and the keyboard having taken over means nothing will draw it
        // again no matter what `fullSizeWindow` currently says.
        model.fullSizeImage = nil
        guard model.fullSizeWindow != nil else { return }
        model.fullSizeWindow = nil
        relayout()
    }

    // MARK: - Hotkey actions

    /// Performs what the tap thread decided a keystroke means.
    ///
    /// The split is the point: deciding happens inside the tap's one-second budget on a
    /// thread nothing else can stall, and *doing* happens here, whenever the main actor gets
    /// round to it. Everything below is therefore written to tolerate arriving late — the
    /// session it was meant for may already have ended by the time it runs.
    func perform(_ action: HotKeyAction) {
        switch action {
        case .begin(let mode, let modifier, let backwards):
            begin(mode: mode, modifier: modifier, backwards: backwards)

        case .sessionKey(let keyCode, let flags, let text, let isRepeat):
            handleSessionKey(keyCode, flags: flags, text: text, isRepeat: isRepeat)

        case .commitAndClearModifier(let modifier):
            commit()
            clearModifierState(forFrontmostApplication: modifier)

        case .clearModifier(let modifier):
            clearModifierState(forFrontmostApplication: modifier)

        case .cancel:
            if isActive { cancel() }

        case .calibrationTrigger(let timestamp):
            SwitcherDelayCalibrationSession.shared.registerTrigger(timestamp: timestamp)

        case .calibrationRelease(let timestamp, let modifier):
            SwitcherDelayCalibrationSession.shared.registerRelease(timestamp: timestamp)
            clearModifierState(forFrontmostApplication: modifier)
        }

        // The authoritative correction to whatever the tap thread assumed. `toggleLatch`,
        // a search that opened, a `cancel` the watchdog got to first — none of those are
        // visible to the callback until this runs.
        publishHotKeyState()
    }

    /// Mirrors the session state the tap thread decides with.
    ///
    /// Called from `begin`, from `endSession` and after every performed action, which
    /// between them cover every way these three values can change.
    func publishHotKeyState() {
        HotKeyState.shared.publish(
            session: (isActive: isActive,
                      modifier: activeModifier,
                      isLatched: interaction.isLatched)
        )
    }

    /// What a key means while the panel is up.
    ///
    /// The two cases that decide *whether* to swallow — a modifier that went missing, and
    /// ⌘Tab arriving during someone else's session — are settled on the tap thread, because
    /// they change what the frontmost application receives and so cannot wait. What is left
    /// is the meaning, and that only ever affects our own panel.
    private func handleSessionKey(_ keyCode: CGKeyCode,
                                  flags: CGEventFlags,
                                  text: String,
                                  isRepeat: Bool) {
        // The session can have ended between the decision and this call — the watchdog
        // cancels, a Space change cancels, a commit may already have run. Acting anyway
        // would step a selection in a panel that is fading out.
        guard isActive else { return }

        // The key bound to the current-app switcher is the one the user *taps to cycle*, so
        // it can never also be the key that destroys what is highlighted. W and Q are both
        // offered by that picker, and as plain cases they won the match: cycling with W
        // closed each window in turn, cycling with Q terminated the application.
        //
        // Only these two yield. Escape and Return stay unconditional — losing the cancel key
        // in every session, including ⌥Tab and ⌘Tab ones, is a worse failure than losing
        // "close window" on one unusual binding.
        let cycleKey = Preferences.shared.currentAppSwitcherKeyCode

        // Ahead of every branch below, so that what a key *does* when held is decided in
        // one place rather than case by case. See ``SessionKeyRepeat``.
        if isRepeat,
           !SessionKeyRepeat.honours(keyCode: keyCode, cycleKey: cycleKey,
                                     isSearching: isSearching) {
            return
        }

        if keyCode == KeyCodes.space, !isSearching {
            toggleLatch()
            return
        }

        if isLatched {
            if keyCode == KeyCodes.delete, isSearching {
                deleteSearchCharacter()
                return
            }
            if keyCode == KeyCodes.slash, !isSearching, beginSearch(explicit: true) {
                return
            }
            if !text.isEmpty, handleSearchText(text) {
                return
            }
        }

        switch keyCode {
        case KeyCodes.tab:
            // Shift always reverses *within* a session, independent of
            // shiftCyclesBackwards: that preference governs how the session opens, and
            // ⇧Tab is the universal "go back" once it is open.
            step(flags.contains(.maskShift) ? -1 : 1)
        case KeyCodes.leftArrow:
            step(-1)
        case KeyCodes.rightArrow:
            step(1)
        case KeyCodes.upArrow:
            moveRow(-1)
        case KeyCodes.downArrow:
            moveRow(1)
        case KeyCodes.escape:
            handleEscape()
        case KeyCodes.returnKey:
            commit()
        case KeyCodes.w where Int(keyCode) != cycleKey:
            closeSelected()
        case KeyCodes.q where Int(keyCode) != cycleKey:
            quitSelected()
        default:
            // The current-app key advances the selection too, so holding ⌥ and tapping `§`
            // repeatedly walks the application's windows the way ⌥Tab walks all of them.
            // It is configurable, so it cannot be a literal case above — and when it *is*
            // W or Q the two cases above decline, leaving the step to this arm.
            //
            // Shift reverses it for the same reason it reverses Tab: inside a session ⇧ is
            // the universal "go back". This arm used to step forwards unconditionally, so
            // ⌥⇧` walked the same way as ⌥` — and with no shifted key that steps, a
            // current-app session could only ever go round one way.
            if Int(keyCode) == cycleKey {
                step(flags.contains(.maskShift) ? -1 : 1)
            }
        }
    }

    /// Tells the front application that no modifier is held any more.
    ///
    /// The problem it solves: the modifier goes down *before* the trigger key, so at that
    /// instant there is no session and the press passes through. Swallowing only the release
    /// therefore leaves everything downstream holding a key-down that never gets its key-up.
    /// Anything translating host `flagsChanged` into state of its own — Parallels, Windows
    /// App, Citrix and the rest turn them into guest scancodes — goes on believing ⌥ is
    /// held, and every later keystroke reaches the guest modified until the user presses and
    /// releases the key by hand.
    ///
    /// But simply passing the real release through is not the fix. The Tab in between was
    /// swallowed, so what the world then sees is a bare modifier tapped and released with
    /// nothing between — which is precisely the gesture that opens the menu bar in a Windows
    /// guest, in Qt and Java Swing, and under Wine. That trades a stuck modifier for a menu
    /// bar appearing out of nowhere.
    ///
    /// Posting to the pid gets the state correction without the system-wide gesture:
    /// `postToPid` bypasses session-level taps, so no other process — and not our own tap —
    /// ever sees it.
    private func clearModifierState(forFrontmostApplication modifier: ModifierCombo) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: Self.modifierKeyCode(for: modifier),
                                  keyDown: false)
        else { return }
        event.type = .flagsChanged
        event.flags = []
        event.postToPid(pid)
    }

    /// The physical key a combo's release should be attributed to.
    ///
    /// A `flagsChanged` carries a key code, and an application that maps host modifiers to
    /// guest scancodes reads it. Reporting the left-hand key of whichever modifier opened
    /// the session is right in every case that matters; a combo of several is vanishingly
    /// rare here because the pickers offer one at a time.
    private nonisolated static func modifierKeyCode(for modifier: ModifierCombo) -> CGKeyCode {
        if modifier.contains(.option) { return 58 }     // kVK_Option
        if modifier.contains(.control) { return 59 }    // kVK_Control
        if modifier.contains(.command) { return 55 }    // kVK_Command
        if modifier.contains(.shift) { return 56 }      // kVK_Shift
        return 63                                       // kVK_Function
    }

    // MARK: - Commit

    func commit() {
        guard isActive else { return }

        // Read the target before ending the session: `endSession` bumps the token and the
        // model keeps its contents only until the next `begin`.
        let onApplicationRow = model.mode == .appSwitcher
            && model.focusRow == .apps
            && !interaction.isSearching
        let app = model.selectedAppEntry
        let window = model.selectedWindowInfo
        let openDefaultWindow = Preferences.shared.openDefaultWindow

        // Captured before `endSession` clears them.
        let unresolved = !windowsLoaded && !onApplicationRow
        let query = pendingQuery
        let pid = pendingPID
        let offset = pendingOffset

        endSession(animation: Preferences.shared.hideAnimation)

        // Retire the previous commit's raise before starting this one. Not merely
        // redundant work: it keeps re-asserting `kAXFrontmost` for its own target for
        // roughly 1.6 s after it was dispatched, so two switches in quick succession ended
        // with the *first* application back in front of the second. See `raiseTask`.
        raiseTask?.cancel()

        // `endSession` has already bumped the counter, so this token names the gap after
        // this session; the next `begin` invalidates it and every continuation below.
        let token = session

        if onApplicationRow {
            guard let app else { return }
            commitApplication(app, window: window,
                              openDefaultWindow: openDefaultWindow, token: token)
            return
        }

        // Released before the list arrived. The selection the user asked for is known —
        // it is `offset` steps from the front — so finish the query and act on it rather
        // than silently doing nothing, which is what "quick switch does not switch" was.
        if unresolved, let query {
            raiseTask = Task { [weak self] in
                // The branch is on *which pid to ask about*, not on the mode. `.appSwitcher`
                // gets here with the selected application's pid, and a mode test sent it
                // down the `allWindows` path instead — resolving the offset against every
                // window on the system rather than against the one row the user was
                // looking at. A nil pid means "every window on the system"; only
                // `.allWindows` may leave it nil, and the other two modes clear
                // `pendingQuery` outright when they have no pid to ask about, so this
                // branch is never entered with a query they produced.
                //
                // Written out rather than folded into `pid.map { await … }`: `map` takes a
                // synchronous closure, so an `await` inside it does not type-check.
                let windows: [WindowInfo]
                if let pid {
                    windows = await WindowIndex.shared.windows(forPID: pid, query)
                } else {
                    windows = await WindowIndex.shared.allWindows(query)
                }
                guard let self, !Task.isCancelled, self.session == token, !windows.isEmpty
                else { return }
                let target = windows[self.wrapped(offset, count: windows.count)]
                await self.raise(target, token: token)
            }
            return
        }

        guard let window else { return }
        raiseTask = Task { await raise(window, token: token) }
    }

    /// Commits a choice made on the ⌘Tab application row.
    ///
    /// **Raising one of the application's windows, not merely activating the application.**
    /// The two are not interchangeable, and the difference is a Space:
    /// `WindowActions.activate` ends at `AXCore.activate`, which sets `kAXFrontmost` and
    /// waits to see whether the front changed. That is all it does — it has no notion of
    /// Spaces. So for an application whose windows are *all* on another desktop, setting
    /// the attribute moves nothing, the display stays where it is, and ~960 ms later the
    /// log records `activate: pid … stayed behind …` while the user, who let go of ⌘ over
    /// the right icon, watches nothing happen.
    ///
    /// Measured on the report that prompted this: WeChat owned thirteen windows, the one
    /// on screen was on Space 3, the user was on Space 4, and ⌘Tab to it did nothing every
    /// time. It also explains why the bug looked intermittent — with a window on the
    /// current Space, `kAXFrontmost` is enough and the switch works.
    ///
    /// `AXCore.raise` is the path that already handles this: it re-asserts `kAXFrontmost`
    /// to move the display, then keeps looking for the window across twelve attempts while
    /// the Space animates, and falls back to activating the application if it never becomes
    /// reachable. Raising the application's front window is also what the system's own ⌘Tab
    /// does, so this is closer to the expected behaviour rather than a workaround for it.
    private func commitApplication(_ app: AppEntry,
                                   window: WindowInfo?,
                                   openDefaultWindow: Bool,
                                   token: Int) {
        // The window row under the selected icon *is* this application's windows, so
        // whatever is highlighted there is the one to come forward.
        //
        // The pid is checked rather than assumed. Moving along the icon row refills the
        // window row asynchronously, so a commit that lands mid-refill can still be holding
        // the *previous* application's selection — raising that would switch to an
        // application the user had already moved past.
        if let window, window.pid == app.pid {
            Log.switcher.debug("""
                commit app \(app.name, privacy: .public): raising window \(window.id) \
                on desktop \(window.spaceNumber ?? -1)
                """)
            raiseTask = Task { await self.raise(window, token: token) }
            return
        }

        // Nothing usable on the row: either it had not arrived yet, or — far more often —
        // the user's filters removed every window this application owns.
        //
        // That second case is the whole bug. `includeOtherSpaces` defaults to **false**, so
        // an application whose windows all live on another desktop has an empty window row,
        // and the empty row used to mean "fall back to activating the application" — which
        // cannot cross Spaces and therefore did nothing at all. Measured on WeChat: one
        // on-screen window, on Space 3, user on Space 4, ⌘Tab to it a no-op every time.
        //
        // Choosing the icon means "switch to this application", and where its windows
        // happen to be is not part of that sentence. So this query deliberately ignores all
        // three filters: they exist to decide what the panel *shows*, not what committing
        // is allowed to reach.
        raiseTask = Task {
            let windows = await WindowIndex.shared.windows(forPID: app.pid,
                                                           Self.unfilteredQuery)
            guard self.session == token else { return }
            guard let target = windows.first else {
                // Genuinely windowless — a menu-bar agent, or an application whose last
                // window was closed. Activation is the whole of what can be done, and
                // `openDefaultWindow` decides whether it is also asked for a new one.
                WindowActions.activate(pid: app.pid, openDefaultWindow: openDefaultWindow)
                return
            }
            Log.switcher.debug("""
                commit app \(app.name, privacy: .public): row was empty, \
                raising window \(target.id) on desktop \(target.spaceNumber ?? -1)
                """)
            await self.raise(target, token: token)
        }
    }

    /// Every window an application owns, wherever it is. See ``commitApplication``.
    private static let unfilteredQuery = WindowQuery(
        includeOtherSpaces: true,
        includeOtherScreens: true,
        includeMinimized: true,
        screenFrame: nil
    )

    /// Brings one window forward, falling back to its application.
    ///
    /// AX can refuse for an application that never answers its own accessibility requests.
    /// Bringing the application forward is a worse answer than raising the exact window,
    /// but it is a far better one than nothing happening.
    private func raise(_ window: WindowInfo, token: Int) async {
        // Before the raise, not as a fallback after it. Accessibility cannot see a window
        // on a Space that is not showing — `kAXWindowsAttribute` is filtered to the current
        // one — so a raise attempted from the wrong desktop spends its twelve attempts
        // asking a question that cannot be answered. Crossing first is what makes the raise
        // reachable at all; when no crossing is needed this returns immediately.
        let started = ProcessInfo.processInfo.systemUptime
        let reached = await SpaceSwitcher.reach(window: window.id, pid: window.pid)
        guard !Task.isCancelled, session == token else { return }
        defer {
            Log.switcher.debug("""
                switch to window \(window.id) took \
                \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms
                """)
        }
        if !reached {
            Log.switcher.error("""
                could not reach the desktop holding window \(window.id); \
                activating pid \(window.pid) instead
                """)
            WindowActions.activate(pid: window.pid, openDefaultWindow: false)
            return
        }

        // Asked *after* crossing, never before: Accessibility only vends the windows of the
        // Space currently showing, so an application read from the wrong desktop looks like
        // it vends nothing and every cross-Space switch would take the fallback.
        //
        // An application that still vends nothing from the right desktop is one this raise
        // cannot touch — twelve attempts at finding a window it does not publish, then a
        // fallback. Go there directly.
        guard await AXCore.shared.vendsAnyWindow(pid: window.pid) else {
            guard !Task.isCancelled, session == token else { return }
            Log.switcher.debug("""
                window \(window.id)'s application vends nothing to Accessibility; \
                activating pid \(window.pid) instead
                """)
            WindowActions.activate(pid: window.pid, openDefaultWindow: false)
            return
        }

        let raised = await AXCore.shared.raise(window: window.id, pid: window.pid)
        // A raise takes up to ~1.6 s, which is long enough for the user to have started
        // and finished another switch. Falling back now would activate the application
        // they just left, on top of the one they just chose.
        guard !Task.isCancelled, session == token else { return }
        guard !raised else { return }
        Log.switcher.debug("raise failed for window \(window.id); activating pid \(window.pid)")
        WindowActions.activate(pid: window.pid, openDefaultWindow: false)
    }

    func cancel() {
        guard isActive else { return }
        endSession(animation: Preferences.shared.hideAnimation)
    }

    private func endSession(animation: HideAnimation) {
        // Bumping first retires every continuation still in flight in one move.
        session &+= 1
        let token = session
        isActive = false
        activeModifier = []
        windowsLoaded = false
        hasPresented = false
        pendingQuery = nil
        pendingPID = nil
        watchdog?.invalidate(); watchdog = nil
        modifierMisses = 0
        sessionStarted = nil
        lastInteraction = nil
        pendingOffset = 0
        // The anchor belongs to a session that is over; the next one starts listening to
        // the pointer again from wherever it happens to be.
        pointerAnchor = nil
        stopWatchingOutsideClicks()

        showTask?.cancel(); showTask = nil
        loadTask?.cancel(); loadTask = nil
        thumbnailTask?.cancel(); thumbnailTask = nil
        autoActivateTask?.cancel(); autoActivateTask = nil
        hoverTask?.cancel(); hoverTask = nil
        hintTask?.cancel(); hintTask = nil
        searchTask?.cancel(); searchTask = nil
        searchApplyTask?.cancel(); searchApplyTask = nil
        quitConfirmationTask?.cancel(); quitConfirmationTask = nil
        interaction.reset()
        quitConfirmation.reset()
        sourceWindows = []
        searchWindows = []
        searchSourceLoaded = false

        model.isVisible = false
        model.hoveredWindow = nil
        model.fullSizeWindow = nil
        // Unlike the thumbnails — see the note at the end of this method — the full-size
        // capture is released now. It is megabytes on its own, and the line above has
        // already taken the preview off screen, so there is nothing left for it to draw
        // during the fade. Reaching commit with the pointer still resting on a card is the
        // ordinary way of using the mouse, and that path never goes through
        // `hoverChanged`'s clear branch.
        model.fullSizeImage = nil
        model.isLatched = false
        model.isSearching = false
        model.isSearchLoading = false
        model.showsUsageHints = false
        model.statusMessage = nil

        panel.hide(animation: animation)
        lastSessionEnded = Date()
        publishHotKeyState()

        // The engine's cache is only a fallback for a capture that fails mid-flight — the
        // panel reads from the model, and every session captures afresh — so bounding it to
        // the session that just ended costs nothing and stops it growing for the lifetime
        // of the process.
        //
        // Carrying the token matters because `live` describes *that* session and nothing
        // else. The prune is an actor hop away, and by the time it would run the user may
        // already have opened another session and cached thumbnails of its own; those are
        // not in `live`, so an untokened prune deletes them as "windows that no longer
        // exist" and leaves the next failed capture with nothing to fall back to.
        let live = Set(model.windows.map(\.id))
        Task {
            guard self.session == token else { return }
            await ThumbnailEngine.shared.prune(keeping: live)
        }

        // The model keeps its windows and images until the next `begin` calls `reset`:
        // clearing them here would blank the tiles halfway through the hide animation.
    }

    // MARK: - Auto activation

    /// Brings the highlighted application forward *without* ending the session, so the user
    /// can see what they are pointing at while still browsing.
    private func scheduleAutoActivate(mode: SwitcherMode, token: Int) {
        autoActivateTask?.cancel()

        // ⌘Tab only, because that is where the setting lives. The App Switcher pane greys
        // its whole group out with `appSwitcherPreviewsEnabled`, yet this fired for ⌥Tab
        // and ⌥` as well — so a user who turned previews off still had windows yanked to
        // the front mid-browse, with the one control that would stop it disabled. A
        // setting the user cannot reach must not keep acting.
        guard mode == .appSwitcher, Preferences.shared.autoActivateEnabled else { return }

        let delay = max(0, Preferences.shared.autoActivateDelay)
        autoActivateTask = Task {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, self.session == token, self.isActive else { return }
            self.activateSelectionInPlace()
        }
    }

    private func activateSelectionInPlace() {
        if model.mode == .appSwitcher, model.focusRow == .apps, let app = model.selectedAppEntry {
            // `openDefaultWindow: false` regardless of the preference: this is a preview,
            // not a commitment, and spawning a document window in an application the user
            // is merely scrolling past is not something they can undo.
            WindowActions.activate(pid: app.pid, openDefaultWindow: false)
        } else if let window = model.selectedWindowInfo {
            // Parked in `raiseTask` so the commit that follows cancels it. This raise is a
            // preview of a selection the user is still moving through, and it must not
            // outlive the choice that replaces it — the same 1.6 s of front-most
            // re-assertion that made two quick switches fight each other.
            raiseTask?.cancel()
            raiseTask = Task {
                _ = await AXCore.shared.raise(window: window.id, pid: window.pid,
                                              crossSpaces: false)
            }
        }
    }

    // MARK: - Full-size preview on hover

    /// Follows `model.hoveredWindow` for as long as the session lasts.
    ///
    /// `withObservationTracking` fires once per change, so the re-arm at the end is not
    /// optional — dropping it would make the preview work exactly one time per session.
    /// The hop into a `Task` is what lets the new value be read: `onChange` runs *before*
    /// the mutation is committed.
    ///
    /// The tracking is unconditional and only the preview work sits behind the preference.
    /// Sweeping the pointer across the cards is the one way of browsing that produces no
    /// keystrokes at all, so with the preference guarding the whole method a user who has
    /// previews switched off could browse with the mouse past the idle backstop and have
    /// the session cancelled out from under them.
    private func watchHover(token: Int) {
        withObservationTracking {
            _ = model.hoveredWindow
        } onChange: {
            Task { @MainActor in
                guard self.session == token, self.isActive else { return }
                self.noteInteraction()
                if self.model.appearance.showFullSizePreviewOnHover {
                    self.hoverChanged(token: token)
                }
                self.watchHover(token: token)
            }
        }
    }

    private func hoverChanged(token: Int) {
        hoverTask?.cancel()

        guard let id = model.hoveredWindow,
              let window = model.windows.first(where: { $0.id == id })
        else {
            guard model.fullSizeWindow != nil else { return }
            model.fullSizeWindow = nil
            model.fullSizeImage = nil
            relayout()
            return
        }

        let configuredDelay = max(0, model.appearance.fullSizePreviewDelay)
        let dwell = min(Double(configuredDelay) / 1_000, 1.2)
        guard let screen = currentScreen else { return }
        // Asked for at the size the view will draw it, in pixels: `FullSizePreview` owns
        // that sum, so calling it here is what stops a capture arriving at the wrong
        // resolution when the cap changes.
        let targetWidth = FullSizePreview.size(forAspectRatio: window.aspectRatio,
                                               on: screen).width * screen.backingScaleFactor

        hoverTask = Task {
            var intent = HoverIntentTracker(stableRadius: 6, dwell: dwell, timeout: 1.2)
            while true {
                guard !Task.isCancelled, self.session == token,
                      self.model.hoveredWindow == id else { return }
                let decision = intent.update(
                    candidate: id,
                    point: NSEvent.mouseLocation,
                    time: ProcessInfo.processInfo.systemUptime
                )
                switch decision {
                case .waiting:
                    try? await Task.sleep(for: .milliseconds(50))
                case .ready:
                    break
                case .abandoned:
                    return
                }
                if decision == .ready { break }
            }

            // Captured before the panel grows, not after: presenting first and awaiting the
            // image afterwards is what made HyperDock's equivalent flash the *previous*
            // window's picture for a frame.
            let thumbnail = await ThumbnailEngine.shared.fullSize(window, targetWidth: targetWidth)
            guard !Task.isCancelled, self.session == token, self.model.hoveredWindow == id else { return }

            // Its own slot, not the tile's image. Written into `model.thumbnails` this
            // capture outlived every use it had: at `min(visibleFrame.width * 0.5, 900)`
            // pt × 2 it is roughly 1800×1126 BGRA, ~8 MB, and that dictionary is only ever
            // emptied by the next `begin` — so one hover-browse left one of these per card
            // hanging until the user opened the switcher again, or until the process died
            // if they never did. The engine's own prune cannot reach them either;
            // `ThumbnailEngine.fullSize` deliberately does not cache. Overwriting the tile
            // saved a ~340 KB copy of the small image and paid megabytes for it.
            //
            // The id travels with the image because `fullSizeWindow` is assigned even when
            // the capture came back nil; without it the view would pair a stale picture
            // with the window now under the pointer.
            self.model.fullSizeImage = thumbnail.map { (id: id, thumbnail: $0) }
            self.model.fullSizeWindow = id
            self.relayout()
        }
    }

    // MARK: - Destructive actions

    /// Closes the highlighted window and reflows the row. The panel stays up: closing
    /// several windows in a row is the point of having the key at all.
    func closeSelected() {
        guard isActive else { return }
        guard model.mode != .appSwitcher || model.focusRow == .windows else { return }
        guard let window = model.selectedWindowInfo else { return }
        // The panel deliberately stays up here, so this is an input the idle backstop has
        // to see: closing several windows in a row is otherwise a browse with no keystroke
        // the watchdog recognises.
        noteInteraction()

        let token = session
        Task {
            let closed = await AXCore.shared.close(window: window.id, pid: window.pid)
            guard self.session == token, self.isActive else { return }
            guard closed else {
                Log.switcher.debug("close refused for window \(window.id)")
                return
            }
            await WindowIndex.shared.noteClosed(window.id)
            // Re-checked after *this* await too, not only after the first. `noteClosed` is
            // a second actor hop and the modifier can be released across it — and `remove`
            // ends in `relayout`, which re-orders the panel in. Done to a session that has
            // already committed, that resurrects a panel mid-fade into a permanently
            // visible, permanently unresponsive rectangle: the hide is finished, so
            // nothing will ever take it down again.
            guard self.session == token, self.isActive else { return }
            self.remove(windowIDs: [window.id])
        }
    }

    /// Quits the highlighted application and takes it out of the switcher.
    ///
    /// Removal is optimistic — an application with unsaved work can put up a sheet and
    /// stay running — but leaving its tiles behind is worse: the user would be offered
    /// windows that are on their way out, and picking one raises a dying process.
    func quitSelected() {
        guard isActive else { return }

        let onApplicationRow = model.mode == .appSwitcher
            && model.focusRow == .apps
            && !interaction.isSearching
        guard let pid = onApplicationRow ? model.selectedAppEntry?.pid
                                         : model.selectedWindowInfo?.pid
        else { return }
        // Like `closeSelected`, this leaves the session open, so the idle backstop must
        // count it as input.
        noteInteraction()

        if model.appearance.quitProtectionEnabled {
            let now = ProcessInfo.processInfo.systemUptime
            guard quitConfirmation.request(targetPID: pid, time: now) else {
                model.statusMessage = Localization.string("Press Q again to quit the selected app")
                let token = session
                quitConfirmationTask?.cancel()
                quitConfirmationTask = Task {
                    try? await Task.sleep(for: .milliseconds(900))
                    guard !Task.isCancelled, self.session == token, self.isActive else { return }
                    if self.clearQuitConfirmation() { self.relayout() }
                }
                relayout()
                return
            }
        }
        clearQuitConfirmation()

        WindowActions.quit(pid: pid)
        // Drop the cached accessibility element too: the pid can be reused by a later
        // process, and a stale `AXUIElement` for it answers for the wrong application.
        AXCore.shared.forget(pid: pid)

        sourceWindows.removeAll { $0.pid == pid }
        searchWindows.removeAll { $0.pid == pid }
        if model.mode == .appSwitcher && !interaction.isSearching {
            // Same reasoning as `remove(windowIDs:)`: the model clamps `selectedApp` on
            // read, so dropping the entry is enough and the selection lands on the
            // application that took its place.
            model.apps.removeAll { $0.pid == pid }
            loadWindowsForSelectedApp(token: session)
            relayout()
        } else {
            remove(windowIDs: Set(model.windows.filter { $0.pid == pid }.map(\.id)))
        }
    }

    private func remove(windowIDs ids: Set<CGWindowID>) {
        guard !ids.isEmpty else { return }

        sourceWindows.removeAll { ids.contains($0.id) }
        searchWindows.removeAll { ids.contains($0.id) }
        if interaction.isSearching {
            scheduleSearchResults()
            return
        }

        model.windows.removeAll { ids.contains($0.id) }
        for id in ids { model.thumbnails[id] = nil }

        // The index is deliberately left alone: `SwitcherModel` resolves it on read, so the
        // selection stays on the same *slot* and therefore slides onto whatever moved up
        // into it — the window after the one just closed. Re-assigning it here would be
        // duplicating that rule in a second place, which is how the two end up disagreeing.
        if let hovered = model.hoveredWindow, ids.contains(hovered) { model.hoveredWindow = nil }
        if let full = model.fullSizeWindow, ids.contains(full) { model.fullSizeWindow = nil }
        // Keyed on the slot's own id rather than on `fullSizeWindow`, so closing the
        // window that is blown up releases its capture instead of stranding megabytes that
        // nothing can draw any more.
        if let slot = model.fullSizeImage, ids.contains(slot.id) { model.fullSizeImage = nil }

        refreshDerivedContent()
        captureThumbnails()
        relayout()
    }

    // MARK: - Helpers

    /// Wraps a possibly out-of-range offset into `0..<count`, which is where the deferred
    /// selection from `begin` ends up.
    private func wrapped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return -1 }
        return ((index % count) + count) % count
    }

}
