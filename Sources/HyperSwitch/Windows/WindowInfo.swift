import AppKit
import CoreGraphics
import Foundation

/// One window, flattened into plain values so it can cross isolation boundaries.
///
/// Assembled from three sources, because no single one can answer everything:
///
/// | need                        | source                                          |
/// |-----------------------------|-------------------------------------------------|
/// | id, owner, frame, on-screen | `CGWindowListCopyWindowInfo`                    |
/// | title                       | `SCShareableContent`                            |
/// | which Space it lives on     | CGS per-Space enumeration                       |
/// | raise / close / minimise    | Accessibility, resolved lazily at action time   |
///
/// In particular the Accessibility API cannot *enumerate* these: `kAXWindowsAttribute`
/// is filtered to the current Space and returns an empty array for an application whose
/// windows are all elsewhere — exactly the windows a switcher exists to reach.
nonisolated struct WindowInfo: Identifiable, Sendable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let applicationName: String

    /// `nil` for processes LaunchServices does not know as applications — some helper
    /// processes own real windows without a bundle.
    let bundleIdentifier: String?

    /// Global, **top-left origin** coordinates, the way `CGWindowListCopyWindowInfo`
    /// reports them. Not AppKit's bottom-left space; see ``WindowQuery/current(screen:)``.
    let frame: CGRect

    /// The Mission Control desktop number this window sits on, if known.
    /// `nil` when the Space SPI is unavailable or the window belongs to none.
    let spaceNumber: Int?
    let isOnCurrentSpace: Bool

    /// True when the window is minimised into the Dock.
    ///
    /// Derived rather than asked for: a minimised window keeps its Space membership, so a
    /// window that belongs to the *current* Space yet is not on screen is either minimised
    /// or owned by a hidden application — ``isApplicationHidden`` separates those two, and
    /// this is false for the hidden case. A window on another Space is simply elsewhere,
    /// not minimised.
    let isMinimized: Bool

    /// True when the owning application is hidden (⌘H).
    ///
    /// Tracked separately from ``isMinimized`` because the window list cannot tell them
    /// apart — a hidden application's windows lose `kCGWindowIsOnscreen` exactly as
    /// minimised ones do — and because the two must not be treated alike: these windows
    /// ignore the "include minimised windows" setting, since getting back to something you
    /// hid is one of the reasons to open a switcher at all.
    let isApplicationHidden: Bool

    /// Whether the window is currently composited, and so whether a fresh thumbnail
    /// will show live content.
    let isOnScreen: Bool

    /// True when the window cannot currently be seen — the case the original shades and
    /// stamps with a Space number.
    var isInvisible: Bool { !isOnScreen }

    var aspectRatio: CGFloat {
        guard frame.height > 0 else { return 16.0 / 10.0 }
        return frame.width / frame.height
    }

    /// What the tile caption shows.
    ///
    /// Titles are empty without Screen Recording permission, and empty for a handful of
    /// windows even with it. A blank caption under a thumbnail reads as a rendering bug,
    /// so the application name stands in — it is never empty, since it comes from
    /// `kCGWindowOwnerName`.
    var displayTitle: String { title.isEmpty ? applicationName : title }
}

/// One running application, as the ⌘Tab row shows it.
///
/// Identified by pid rather than bundle identifier because the same bundle can be
/// running twice (two copies of an app, or one relaunched while the old instance
/// lingers), and because pid is what every action here — activate, quit, count windows —
/// actually addresses.
nonisolated struct AppEntry: Identifiable, Sendable, Equatable {
    var id: pid_t { pid }

    let pid: pid_t
    let name: String
    let bundleIdentifier: String?

    /// How many windows the application owns under the *current* query. Zero is a real
    /// answer, not a missing one: an application with no windows is exactly the case
    /// "open the default window" exists for.
    let windowCount: Int
}

/// The subset of user preferences that shapes a window query, snapshotted so the index
/// actor never reaches back to the main actor mid-query.
nonisolated struct WindowQuery: Sendable {
    let includeOtherSpaces: Bool
    let includeOtherScreens: Bool
    let includeMinimized: Bool

    /// Global, **top-left origin** — the same space `WindowInfo.frame` is in.
    /// `nil` means "do not filter by screen".
    let screenFrame: CGRect?

    @MainActor
    static func current(screen: NSScreen) -> WindowQuery {
        let preferences = Preferences.shared
        let includeOtherScreens = preferences.includeOtherScreens
        return WindowQuery(
            includeOtherSpaces: preferences.includeOtherSpaces,
            includeOtherScreens: includeOtherScreens,
            includeMinimized: preferences.includeMinimized,
            // Resolved here rather than in the actor: `NSScreen` is main-actor territory,
            // and once converted the rectangle is a plain Sendable value.
            screenFrame: includeOtherScreens ? nil : topLeftFrame(of: screen)
        )
    }

    /// `NSScreen.frame` expressed in the coordinate space `CGWindowListCopyWindowInfo`
    /// reports window bounds in.
    ///
    /// AppKit's origin is the *primary* display's bottom-left corner and CoreGraphics'
    /// is its top-left, so the flip mirrors around that display's height and nothing
    /// else. Mirroring around the top of the whole desktop instead is wrong the moment a
    /// secondary display sits higher than the primary one: measured on HyperDock with a
    /// 2560×1440 primary and a 1728×1117 secondary placed at y = 360, the union's top is
    /// 1477 while the true mirror line is 1440, and the 37 pt error was enough to put
    /// windows on the wrong screen.
    @MainActor
    private static func topLeftFrame(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        let frame = screen.frame
        return CGRect(x: frame.minX,
                      y: primaryHeight - frame.maxY,
                      width: frame.width,
                      height: frame.height)
    }

    /// Whether a window counts as living on the queried screen.
    ///
    /// Decided by the window's centre, not by intersection: a window straddling two
    /// displays intersects both and would otherwise appear twice, once per screen, in a
    /// switcher the user opened on one of them. The centre picks the display the window
    /// mostly occupies, which is also the one macOS itself considers it to be on.
    func matchesScreen(_ frame: CGRect) -> Bool {
        guard let screenFrame else { return true }
        return screenFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }
}
