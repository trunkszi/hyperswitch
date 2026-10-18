import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Keeps a current picture of every window on the system, and answers the three
/// questions the switcher asks: what is open everywhere, what is open in one
/// application, and how many windows each application has.
///
/// Enumeration comes from `CGWindowListCopyWindowInfo`, not from ScreenCaptureKit or
/// Accessibility, for three reasons:
///
///   * It sees every Space. `kAXWindowsAttribute` is filtered to the *current* Space and
///     returns an empty array for an application whose windows are all elsewhere —
///     exactly the windows this feature exists to show.
///   * It is cheap: ~4 ms, against 46–57 ms for a full `SCShareableContent` listing.
///     The switcher must be on screen within the user's 80 ms activation delay.
///   * It works without Screen Recording permission. Titles do not, which is why the
///     ScreenCaptureKit listing is still consulted — but as an *enrichment*. If that
///     permission is missing the switcher still opens, showing application names in
///     place of window titles, instead of silently doing nothing.
actor WindowIndex {
    static let shared = WindowIndex()

    /// Injectable only so the latency contract can be tested with a deliberately slow
    /// provider. Production always uses ``loadTitles()`` below.
    typealias TitleLoader = @Sendable () async throws -> [CGWindowID: String]

    /// Window titles keyed by id, from the last ScreenCaptureKit listing.
    ///
    /// Emptied when a listing fails — see ``noteTitlesUnavailable()``; the "a window with
    /// no title is a helper surface" rule downstream reads `titles.isEmpty` as "we have
    /// nothing to compare against", and that only holds if failure clears the table.
    private var titles: [CGWindowID: String] = [:]
    private var titlesRefreshed: Date = .distantPast
    private var titleTask: Task<Void, Never>?
    private let titleLoader: TitleLoader

    private let titlesStaleAfter: TimeInterval = 2.0

    /// Consecutive failed listings, driving the backoff below.
    private var titleFailures = 0

    /// How long to wait before another listing is attempted.
    ///
    /// A `SCShareableContent` listing costs 46–57 ms and, without Screen Recording
    /// permission, fails every single time — and it is consulted on the query path,
    /// inside the 80 ms the switcher has to be on screen. An unrecorded failure meant
    /// every hotkey press re-ran a listing that could not succeed, paying that cost each
    /// time. Failures therefore double the wait — 4 s, 8 s, 16 s — capped at 30 s, which
    /// is short enough that a grant given in System Settings is picked up on its own
    /// rather than needing a relaunch. One success resets it.
    private var titlesRetryInterval: TimeInterval {
        guard titleFailures > 0 else { return titlesStaleAfter }
        return min(30, titlesStaleAfter * TimeInterval(1 << min(titleFailures, 8)))
    }

    /// Windows a caller believes it closed, which the window server has not stopped
    /// reporting. Provisional: see ``noteClosed(_:)``.
    ///
    /// `kCGWindowIsOnscreen` lags the actual close by longer than it takes to rebuild the
    /// switcher: measured on HyperDock, the reconcile that follows a close still sees the
    /// window as on screen, so the ghost check below has nothing to be suspicious about
    /// and the tile the user just dismissed comes straight back. Recording the id at the
    /// moment of the close closes that window of time.
    private var closedIDs: [CGWindowID: Date] = [:]

    /// The longest a close is believed without confirmation.
    ///
    /// Was 5 s, which was too generous for a record that is only a *guess*: an entry here
    /// hides its window from every query — ⌥Tab, ⌥`, and the ⌘Tab count badges alike — so
    /// a window that did not actually close vanishes for the whole interval while the
    /// user is looking at the save sheet that kept it alive. 1.5 s still covers the
    /// window-server lag this exists for, and ``reconcileClosedIDs(listing:)`` usually
    /// retracts a wrong entry well before it expires.
    private let closedIDGrace: TimeInterval = 1.5

    /// Ceiling on the table. It is normally emptied within `closedIDGrace`, but a bound
    /// is what makes "cannot grow without limit" a property of the type rather than of
    /// the code paths that happen to prune it.
    private let closedIDLimit = 64

    init(titleLoader: @escaping TitleLoader = WindowIndex.loadTitles) {
        self.titleLoader = titleLoader
    }

    // MARK: - Titles

    /// Refreshes the title table and waits for it. Overlapping calls coalesce onto one
    /// listing. Startup and permission-change callers use this eager form to warm the
    /// cache before the first switch; the hot query path only starts the same work in the
    /// background through ``startTitleRefresh()``.
    func refresh() async {
        startTitleRefresh()
        await titleTask?.value
    }

    /// Starts stale-while-revalidate work without putting ScreenCaptureKit's 46–57 ms
    /// listing in front of a switcher query. Keeping the task in the actor coalesces a
    /// burst of key presses onto one refresh.
    private func startTitleRefresh() {
        guard titleTask == nil else { return }
        let loader = titleLoader
        titleTask = Task { [weak self] in
            do {
                let fresh = try await loader()
                await self?.finishTitleRefresh(fresh)
            } catch {
                await self?.finishTitleRefreshFailure()
            }
        }
    }

    private func finishTitleRefresh(_ fresh: [CGWindowID: String]) {
        storeTitles(fresh)
        titleTask = nil
    }

    private func finishTitleRefreshFailure() {
        noteTitlesUnavailable()
        titleTask = nil
    }

    private nonisolated static func loadTitles() async throws -> [CGWindowID: String] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false)
        var fresh: [CGWindowID: String] = [:]
        for window in content.windows {
            if let title = window.title, !title.isEmpty { fresh[window.windowID] = title }
        }
        return fresh
    }

    private func storeTitles(_ fresh: [CGWindowID: String]) {
        titles = fresh
        titlesRefreshed = Date()
        titleFailures = 0
    }

    /// A failed listing has to be recorded, and it has to empty the table.
    ///
    /// Two separate faults come from leaving it alone. The timestamp is the only thing
    /// rate-limiting the next attempt, so without it a missing Screen Recording grant put
    /// a doomed 46–57 ms listing on the front of every query. And keeping the old titles
    /// is worse than having none: revoking the grant leaves the table populated while
    /// `kCGWindowName` goes empty, at which point the "no title means helper surface"
    /// rule in ``collect(_:workspace:matching:)`` matches nearly every window on the
    /// system and the switcher opens empty.
    private func noteTitlesUnavailable() {
        titles = [:]
        titlesRefreshed = Date()
        titleFailures += 1
        // Once per outage, not once per query: the backoff can still fire every 30 s for
        // as long as the permission is missing, and a log line per attempt would bury
        // everything else.
        if titleFailures == 1 {
            Log.windows.error("window title listing failed; falling back to application names")
        }
    }

    /// Records that a caller pressed a window's close button.
    ///
    /// **Provisional, not confirmed.** The call site can only observe that the press
    /// *returned* success, and an application that answers ⌘W with a save sheet keeps its
    /// window — so this is a suppression on probation. ``reconcileClosedIDs(listing:)``
    /// retracts it on the next query if the window is demonstrably still alive, and it
    /// expires after ``closedIDGrace`` regardless.
    func noteClosed(_ id: CGWindowID) {
        if closedIDs[id] == nil, closedIDs.count >= closedIDLimit,
           let oldest = closedIDs.min(by: { $0.value < $1.value })?.key {
            closedIDs[oldest] = nil
        }
        closedIDs[id] = Date()
    }

    // MARK: - Queries

    /// Every ordinary window on the system, ordered the way the switcher shows them.
    ///
    /// The frontmost application's windows lead, in stacking order, so the first Tab
    /// press lands on the window the user most recently left — the behaviour ⌘Tab and
    /// ⌥Tab share and the reason a single press is a "flick back". Everything else
    /// follows by descending window id, which is descending creation time: ids increase
    /// monotonically, so the newest window of each other application floats to the top
    /// instead of the list being ordered by whatever the window server happens to have
    /// composited most recently.
    func allWindows(_ query: WindowQuery) async -> [WindowInfo] {
        let workspace = await Self.workspaceSnapshot()
        let windows = await collect(query, workspace: workspace, matching: nil)

        // CGWindowList already hands back on-screen windows front-to-back, so the
        // frontmost application's slice is in stacking order as it stands; re-sorting it
        // by id would put its *newest* window first rather than its *current* one.
        let front = windows.filter { $0.pid == workspace.frontmostPID }
        let rest = windows.filter { $0.pid != workspace.frontmostPID }
            .sorted { $0.id > $1.id }
        return front + rest
    }

    /// Every window belonging to one application.
    ///
    /// Left in `CGWindowListCopyWindowInfo`'s own order, which is the stacking order
    /// front-to-back. That is what the current-application switcher wants: cycling walks
    /// from the window in front backwards through the ones behind it, which is how the
    /// system's own ⌘` behaves.
    func windows(forPID pid: pid_t, _ query: WindowQuery) async -> [WindowInfo] {
        guard pid != Self.ownPID else { return [] }
        let workspace = await Self.workspaceSnapshot()
        return await collect(query, workspace: workspace, matching: pid)
    }

    /// How many windows each application owns under this query.
    ///
    /// Exists so the ⌘Tab application row can carry a count badge without every tile
    /// running its own query — and so an application with a count of zero can be told
    /// apart from one whose windows are merely on another Space, which is the difference
    /// between synthesising ⌘N on activation and not.
    func windowCounts(_ query: WindowQuery) async -> [pid_t: Int] {
        let workspace = await Self.workspaceSnapshot()
        let windows = await collect(query, workspace: workspace, matching: nil)
        var counts: [pid_t: Int] = [:]
        for window in windows { counts[window.pid, default: 0] += 1 }
        return counts
    }

    // MARK: - Collection

    /// `nonisolated`, like everything static here: a `static` member of an actor is not
    /// actor-isolated, so under `-default-isolation=MainActor` it would land on the main
    /// actor and be unreachable from the actor's own methods.
    private nonisolated static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// The one enumeration every query is built on.
    ///
    /// - Parameter matching: restricts the result to a single owner; `nil` takes every
    ///   application. Filtering here rather than afterwards keeps the Space lookup and
    ///   the title join off windows nobody asked about.
    private func collect(_ query: WindowQuery,
                         workspace: WorkspaceSnapshot,
        matching target: pid_t?) async -> [WindowInfo] {
        if Date().timeIntervalSince(titlesRefreshed) > titlesRetryInterval {
            // Titles enrich a window row; they must never gate it. Use the last good
            // snapshot (or application names when none exists) and refresh for the next
            // query. This removes a periodic 46–57 ms stall from the 80 ms presentation
            // budget without changing filtering or capture semantics.
            startTitleRefresh()
        }

        // .optionAll rather than .optionOnScreenOnly: minimised windows and windows on
        // other Spaces are absent from the on-screen list, and they are the point.
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        await reconcileClosedIDs(listing: raw)
        let closed = Set(closedIDs.keys)
        let spaceMap = Self.buildSpaceMap()

        var results: [WindowInfo] = raw.compactMap { entry -> WindowInfo? in
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t,
                  // Our own switcher panel is a window like any other and must never
                  // appear in its own list.
                  owner != Self.ownPID,
                  target == nil || owner == target,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  !closed.contains(id),
                  // Layer 0 is the ordinary document/window layer; anything else is a
                  // panel, menu, tooltip or shadow.
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }

            let frame = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                               width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)

            // Tool palettes, tooltips and stray shadows are never what a person means
            // by "a window".
            guard frame.width >= 80, frame.height >= 60 else { return nil }
            guard query.matchesScreen(frame) else { return nil }

            let applicationName = entry[kCGWindowOwnerName as String] as? String ?? ""
            let title = Self.title(live: entry[kCGWindowName as String] as? String,
                                   cached: titles[id])

            // Without a title this is usually a helper surface — but only drop it when we
            // actually had titles to consult, or a missing Screen Recording grant would
            // empty the switcher entirely. That test is only sound because a failed
            // listing *empties* the table rather than leaving the last good one in place:
            // with stale titles kept, revoking the grant satisfies both halves of this
            // condition at once — non-empty table, empty `kCGWindowName` — and takes the
            // whole switcher with it.
            if title.isEmpty && !titles.isEmpty { return nil }

            let onScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            let placement = spaceMap.placement(of: id)

            // The third class of window, which neither flag below can express: still in
            // the window list, on no Space at all. Measured on macOS 26.5.2, these are
            // windows an application built and never ordered in — Termius' settings
            // window, WeChat's 280×380 window — with real titles and real bounds that
            // survive for the life of the process, so nothing above filters them out and
            // the tile looks exactly like a working one. `kAXWindowsAttribute` never vends
            // them, so choosing one costs ``AXCore.raise`` all twelve attempts before it
            // gives up and merely activates the application. They cannot be caught later
            // either: ``dropClosedWindows(from:)`` judges only current-Space windows, on
            // purpose, so this is the one place that can stop them.
            //
            // The `onScreen` half is not redundant: a visible window is never dropped, no
            // matter what the Space SPI says about it.
            guard onScreen || placement.isInAnySpace else { return nil }

            let applicationHidden = workspace.hiddenPIDs.contains(owner)

            // A window belonging to the current Space that is not on screen is either
            // minimised into the Dock or owned by an application the user hid with ⌘H.
            // Those are *not* the same thing and must not be conflated: measured on
            // macOS 26.5.2, a hidden application's windows keep their Space membership
            // and every other field, and lose `kCGWindowIsOnscreen` — which is missing
            // from the dictionary entirely rather than present and false, exactly as for
            // a minimised window. Nothing in the window list separates them. The owning
            // application's own hidden flag does, which is why it rides along in the
            // workspace snapshot; calling both "minimised" made the default settings
            // filter away every window of every hidden application, and "I hid it, now
            // get it back" is the first thing a switcher is for.
            //
            // Scope note, and it is deliberate: this judgement is only made on the
            // current Space. Every window on another Space also lacks
            // `kCGWindowIsOnscreen`, so there is no signal over there that separates
            // "minimised" from "sitting on desktop 3" — and labelling them all minimised
            // would make "include windows from other spaces" do nothing whenever
            // "include minimised windows" is off, collapsing two independent settings
            // into one. So off-Space windows are never labelled minimised and the
            // minimised filter below is a current-Space rule. Someone switching that
            // setting off is asking not to be offered windows stowed in the Dock; a
            // window on another desktop is not stowed, and the other setting governs it.
            let minimized = !onScreen && placement.isOnCurrentSpace && !applicationHidden

            return WindowInfo(
                id: id,
                pid: owner,
                title: title,
                applicationName: applicationName,
                bundleIdentifier: workspace.bundleIdentifiers[owner],
                frame: frame,
                spaceNumber: placement.spaceNumber,
                isOnCurrentSpace: placement.isOnCurrentSpace,
                isMinimized: minimized,
                isApplicationHidden: applicationHidden,
                isOnScreen: onScreen
            )
        }

        results = results.filter { window in
            // A hidden application's windows are exempt from this without a clause of
            // their own: `minimized` is false for them by construction above. Hiding is
            // a state you get out of *through* a switcher, so filtering those windows
            // away would leave ⌘H with no undo except the Dock.
            if window.isMinimized && !query.includeMinimized { return false }
            if !window.isOnCurrentSpace && !query.includeOtherSpaces { return false }
            return true
        }

        return await Self.dropClosedWindows(from: results)
    }

    /// The title to show for a window: the window server's, unless it has none.
    ///
    /// The order used to be the other way round, and that put a stale title on the card.
    /// `kCGWindowName` is read in the same `CGWindowListCopyWindowInfo` call as everything
    /// else, so it is as current as the query; the ScreenCaptureKit table is a snapshot up
    /// to two seconds old — longer while its listing is backing off. Switch a browser tab
    /// or a Finder folder and press ⌥Tab, and the card still named the page that was there
    /// a moment ago, which in a row of same-application windows is the only thing telling
    /// them apart.
    ///
    /// The table still earns its place: without Screen Recording `kCGWindowName` is empty
    /// for every window but our own, and the cached title is then the only one there is.
    nonisolated static func title(live: String?, cached: String?) -> String {
        if let live, !live.isEmpty { return live }
        return cached ?? ""
    }

    /// Confirms, retracts and expires the provisional close records.
    ///
    /// Runs before the suppression list is applied, so a window that turned out *not* to
    /// have closed is back in the very query that discovered it, rather than after the
    /// grace period has run out.
    private func reconcileClosedIDs(listing raw: [[String: Any]]) async {
        guard !closedIDs.isEmpty else { return }

        let now = Date()
        closedIDs = closedIDs.filter { now.timeIntervalSince($0.value) <= closedIDGrace }
        guard !closedIDs.isEmpty else { return }

        // Who owns each still-listed id. Presence in the listing proves nothing by itself
        // — a closed window's entry lingers there indefinitely — but the pid is what
        // Accessibility has to be asked about.
        var owners: [CGWindowID: pid_t] = [:]
        for entry in raw {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  closedIDs[id] != nil,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            owners[id] = pid
        }

        // An id the window server has stopped listing needs no suppressing. This is also
        // what stops the table growing: its only previous exit was the id turning up
        // *on screen* again, a condition an id reused by an off-screen window never
        // meets, so entries accumulated for the life of the process.
        closedIDs = closedIDs.filter { owners[$0.key] != nil }
        guard !closedIDs.isEmpty else { return }

        var live: [pid_t: Set<CGWindowID>] = [:]
        for (id, pid) in owners {
            if live[pid] == nil { live[pid] = await AXCore.shared.liveWindowIDs(pid: pid) ?? [] }
            // Accessibility drops a window within a frame of it closing, so it still
            // answering for this one means the close never happened — an application that
            // met the close button with a save sheet, most likely. Note the asymmetry:
            // being listed retracts the suppression, being absent does not confirm it,
            // because `kAXWindowsAttribute` routinely returns only a subset of an
            // application's windows.
            if live[pid]?.contains(id) == true { closedIDs[id] = nil }
        }
    }

    /// Removes windows that no longer exist but are still being reported.
    ///
    /// A closed window does not leave `CGWindowListCopyWindowInfo`. Measured on TextEdit,
    /// its entry survives indefinitely — same title, same bounds, same alpha — losing only
    /// `kCGWindowIsOnscreen`, which is precisely what a *minimised* window loses too. The
    /// rule above therefore relabels every closed window "minimised", and the switcher
    /// goes on offering a preview of something the user just got rid of.
    ///
    /// Accessibility is the tiebreaker, so this asks it — but only about the applications
    /// in doubt, and only when there are any. On the default settings there rarely are:
    /// minimised windows are excluded and the filter above has already removed them, so
    /// this costs one dictionary build and nothing else.
    ///
    /// **Accessibility may only deny the windows it actually enumerated.** Its answer is
    /// routinely a *subset*: measured on macOS 26.5.2, Sublime Text vends 1 of its 7
    /// windows, Ghostty 1 of 6, and WeChat, Surge Dashboard and Chrome Canary omit even
    /// their focused window — partial answers are the norm on this machine, not an edge
    /// case. Guarding only against an outright unreadable list (`!ids.isEmpty`), as this
    /// did before, therefore deleted real minimised windows as soon as "include minimised
    /// windows" was switched on: one vended id was enough to condemn six real ones. So an
    /// application's answer is used only when it is demonstrably complete — see
    /// ``ClosedWindowEvidence`` for what that means and why a plain count was not enough —
    /// and an answer that is not is evidence of nothing and is dropped, leaving its
    /// windows in place.
    ///
    /// The other guard still holds: only windows already believed to be on the current
    /// Space are ever judged, so `kAXWindowsAttribute`'s Space filtering cannot make an
    /// off-Space window look closed.
    private nonisolated static func dropClosedWindows(
        from windows: [WindowInfo]
    ) async -> [WindowInfo] {
        var suspects: [pid_t: Set<CGWindowID>] = [:]
        var visible: [pid_t: Set<CGWindowID>] = [:]
        for window in windows where window.isOnCurrentSpace {
            if window.isOnScreen {
                visible[window.pid, default: []].insert(window.id)
            } else {
                suspects[window.pid, default: []].insert(window.id)
            }
        }
        guard !suspects.isEmpty else { return windows }

        var live: [pid_t: Set<CGWindowID>] = [:]
        for (pid, doubted) in suspects {
            guard let ids = await AXCore.shared.liveWindowIDs(pid: pid),
                  ClosedWindowEvidence.isTrustworthy(vended: ids,
                                                     visible: visible[pid] ?? [],
                                                     suspects: doubted)
            else { continue }
            live[pid] = ids
        }
        guard !live.isEmpty else { return windows }

        return windows.filter { window in
            guard !window.isOnScreen, window.isOnCurrentSpace,
                  let ids = live[window.pid] else { return true }
            return ids.contains(window.id)
        }
    }

    // MARK: - Workspace snapshot

    /// The two things only AppKit can answer, read where AppKit expects to be read.
    nonisolated struct WorkspaceSnapshot: Sendable {
        /// `nil` when the frontmost application is this one, or none is.
        let frontmostPID: pid_t?
        let bundleIdentifiers: [pid_t: String]

        /// Applications hidden with ⌘H. The window list cannot tell their windows from
        /// minimised ones, so this is the only thing that can.
        let hiddenPIDs: Set<pid_t>
    }

    /// Taken on the main actor and handed over as plain scalars.
    ///
    /// `NSWorkspace`'s application properties are documented to change only as the main
    /// run loop turns, so a reading taken here is the one the user is currently looking
    /// at; taken from the actor it could be a run loop behind. Nothing AppKit owns
    /// crosses the boundary — only a pid and a dictionary of strings.
    @MainActor
    private static func workspaceSnapshot() -> WorkspaceSnapshot {
        var identifiers: [pid_t: String] = [:]
        var hidden: Set<pid_t> = []
        for application in NSWorkspace.shared.runningApplications {
            let pid = application.processIdentifier
            if let bundle = application.bundleIdentifier { identifiers[pid] = bundle }
            // Collected in the same pass rather than asked per window later: reaching for
            // `NSRunningApplication(processIdentifier:)` from inside the actor would be a
            // hop back to the main actor for every window in the list.
            if application.isHidden { hidden.insert(pid) }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return WorkspaceSnapshot(frontmostPID: front == ownPID ? nil : front,
                                 bundleIdentifiers: identifiers,
                                 hiddenPIDs: hidden)
    }

    // MARK: - Space mapping

    /// Where a window sits, in the terms the UI cares about.
    nonisolated struct Placement: Sendable {
        let spaceNumber: Int?
        let isOnCurrentSpace: Bool

        /// The third case the two flags above cannot express: still listed by
        /// `CGWindowListCopyWindowInfo`, but claimed by no Space at all.
        let isInAnySpace: Bool
    }

    /// A reverse index from window to Space.
    ///
    /// Built by asking each Space for its windows rather than each window for its
    /// Spaces: the per-Space direction sees Spaces the user is not currently viewing,
    /// and one call per Space is far cheaper than one per window.
    nonisolated struct SpaceMap: Sendable {
        let windowToNumber: [CGWindowID: Int]
        let currentSpaceWindows: Set<CGWindowID>

        /// Every window claimed by *any* Space, full-screen Spaces included. Kept
        /// separately from `windowToNumber` for the reason spelled out in
        /// ``buildSpaceMap()``: that table only covers numbered desktops.
        let anySpaceWindows: Set<CGWindowID>
        let available: Bool

        func placement(of window: CGWindowID) -> Placement {
            guard available else {
                // Without the Space SPI the app still works; it just cannot label or
                // distinguish off-Space windows, so everything is treated as here.
                // `isInAnySpace` must say true for a sharper reason: the rule it feeds
                // *deletes* windows, so a private selector going quiet has to cost badges
                // and nothing else — never the switcher's contents.
                return Placement(spaceNumber: nil, isOnCurrentSpace: true, isInAnySpace: true)
            }
            return Placement(spaceNumber: windowToNumber[window],
                             isOnCurrentSpace: currentSpaceWindows.contains(window),
                             isInAnySpace: anySpaceWindows.contains(window))
        }
    }

    nonisolated static func buildSpaceMap() -> SpaceMap {
        let displays = CGS.managedDisplaySpaces()
        guard !displays.isEmpty else {
            return SpaceMap(windowToNumber: [:], currentSpaceWindows: [],
                            anySpaceWindows: [], available: false)
        }

        var numbers: [CGWindowID: Int] = [:]
        var current: Set<CGWindowID> = []
        var everywhere: Set<CGWindowID> = []
        var sawWindow = false

        for display in displays {
            for space in display.spaces {
                let windows = CGS.windows(onSpace: space.id)
                if !windows.isEmpty { sawWindow = true }
                if space.isCurrent { current.formUnion(windows) }
                // Accumulated *above* the type filter, deliberately. A full-screen window
                // lives on a type 4 Space and is therefore absent from `numbers`, so
                // reading "has a desktop number" as "lives on some Space" would condemn
                // every full-screen window on another desktop as a ghost below — which is
                // exactly the window "include windows from other spaces" exists to show.
                everywhere.formUnion(windows)
                // A full-screen Space has no user-visible desktop number.
                guard space.type == 0 else { continue }
                for window in windows where numbers[window] == nil {
                    numbers[window] = space.number
                }
            }
        }

        // Spaces that exist but contain no window at all, anywhere, is not a state a
        // running desktop can be in — it means the per-Space window SPI stopped
        // answering. Its selector mask is measured rather than documented (see
        // `CGS.windows(onSpace:)`) and a macOS update can move it. Believing the empty
        // answer would mark every window "not on the current Space" and, on the default
        // settings, filter the switcher down to nothing — the whole feature gone because
        // of a private selector. Falling back to "everything is here" costs only the
        // Space badges, which is what a machine without the SPI already gets.
        guard sawWindow else {
            Log.windows.error("""
                space SPI returned no windows for any of \(displays.count) displays; \
                treating every window as on the current Space
                """)
            return SpaceMap(windowToNumber: [:], currentSpaceWindows: [],
                            anySpaceWindows: [], available: false)
        }

        return SpaceMap(windowToNumber: numbers, currentSpaceWindows: current,
                        anySpaceWindows: everywhere, available: true)
    }
}

/// When an application's Accessibility window list can be believed about what it omits.
///
/// ``WindowIndex``'s closed-window filter deletes every doubted window — current Space,
/// not on screen — that this list does not contain, so the question is never "what did it
/// vend" but "would it have vended a real minimised window if there were one".
///
/// The rule this replaced compared the *whole* answer's size with the number of doubts,
/// which mixes two populations. The visible windows are in that count too, and they say
/// nothing about minimised ones: an application with three windows on screen and two
/// minimised that vends only the three it is showing passed `3 >= 2`, and both real
/// minimised windows were deleted the moment "include minimised windows" was switched on.
///
/// What the answer has to show instead, both of it:
///
///   * **every visible window** — an answer that already misses a window the user can
///     see is a partial one, and partial answers are the norm on this machine;
///   * **at least one of the doubted windows** — the only proof available that this
///     application reports off-screen windows at all. Without it, "not listed" cannot be
///     told apart from "never listed", and only the first means closed.
///
/// The cost is deliberate and one-sided: a closed window whose application has nothing
/// else minimised keeps its tile until the window server forgets it. That is a tile that
/// activates its application when chosen; the alternative was deleting windows the user
/// still has, which no amount of choosing gets back.
nonisolated enum ClosedWindowEvidence {
    static func isTrustworthy(vended: Set<CGWindowID>,
                              visible: Set<CGWindowID>,
                              suspects: Set<CGWindowID>) -> Bool {
        visible.isSubset(of: vended) && !vended.isDisjoint(with: suspects)
    }
}
