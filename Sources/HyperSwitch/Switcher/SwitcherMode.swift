import AppKit
import SwiftUI

/// Which of the three switchers a session is running.
///
/// One panel and one state machine serve all three; the mode is what decides which rows
/// exist and what committing means. Keeping them as one type rather than three parallel
/// controllers is what makes "hold ⌥ and press Tab twice, then press ↓" a single,
/// testable sequence instead of three near-identical ones.
///
/// `nonisolated` because the event tap resolves a keystroke to a mode before anything
/// hops to the main actor — under `-default-isolation MainActor` this enum would
/// otherwise be main-actor-isolated and unreadable from the tap callback.
nonisolated enum SwitcherMode: String, Sendable, CaseIterable, Identifiable {
    /// Modifier + Tab: every window on the system, one row of cards.
    case allWindows
    /// Modifier + `§`/`` ` ``: the windows of whichever application is frontmost.
    case currentApp
    /// ⌘Tab intercepted: a row of application icons over a row of that application's
    /// window previews.
    case appSwitcher

    var id: String { rawValue }
}

/// Which of the two rows the keyboard is driving.
///
/// Only `.appSwitcher` ever has two, but the other modes still carry a value rather than
/// an optional: `step(_:)` then has exactly one thing to move and no "which row did they
/// mean" case to get wrong.
nonisolated enum FocusRow: Sendable, Equatable {
    case apps
    case windows
}

/// The subset of the user's preferences that the panel actually draws with, snapshotted
/// at the moment a session begins.
///
/// A snapshot rather than a live read of `Preferences.shared` for two reasons. The panel's
/// geometry is computed once, before it is shown, so a preference changing mid-session
/// would leave the drawn cards disagreeing with the window that contains them. And this
/// has to be readable from the thumbnail actor, which needs `thumbnailWidth` to size its
/// captures — `Preferences` is main-actor-isolated and cannot be read from there at all.
///
/// The background is carried as raw sRGB components instead of an `NSColor` precisely so
/// this type can be `Sendable`: `NSColor` is not, and wrapping it in `@unchecked` here
/// would be claiming a guarantee that four `Double`s give for free.
nonisolated struct SwitcherAppearance: Sendable, Equatable {
    /// Width in points of one window thumbnail box.
    let thumbnailWidth: CGFloat
    let showAppIcons: Bool
    /// Edge length of the icon overlaid on a thumbnail, already resolved from the
    /// small/medium/large preference.
    let appIconPoints: CGFloat
    /// sRGB `r, g, b, a` of the panel's background tint.
    let backgroundComponents: [Double]
    let blurBackground: Bool
    let theme: AppearanceTheme
    let showFullSizePreviewOnHover: Bool
    /// Milliseconds the pointer must rest on a card before it is blown up.
    let fullSizePreviewDelay: Int
    let latchedModeEnabled: Bool
    let showUsageHints: Bool
    let searchThreshold: Int
    let keepSelectionCentered: Bool
    let groupLongLists: Bool
    let quitProtectionEnabled: Bool
    let comfortMode: Bool

    /// The visible bounds of the screen this session was pinned to.
    ///
    /// Part of the snapshot rather than something the view resolves for itself. The view
    /// uses it to decide how many cards fit on a row and how large a full-size preview may
    /// be, and `switcherScreen` can name "the screen with the mouse" — so a view asking
    /// `Preferences` again mid-session could measure against a display the panel is not on,
    /// and the full-size preview would be drawn at a size the capture was never requested
    /// at. The controller pins one screen at `begin`; this is that screen.
    let screenFrame: CGRect

    @MainActor
    static func current(screen: NSScreen? = nil) -> SwitcherAppearance {
        let preferences = Preferences.shared
        let srgb = preferences.backgroundColor.usingColorSpace(.sRGB)
            ?? Preferences.defaultBackgroundColor
        return SwitcherAppearance(
            thumbnailWidth: CGFloat(preferences.thumbnailSize),
            showAppIcons: preferences.showAppIcons,
            appIconPoints: preferences.appIconSize.points,
            backgroundComponents: [srgb.redComponent, srgb.greenComponent,
                                   srgb.blueComponent, srgb.alphaComponent],
            blurBackground: preferences.blurBackground,
            theme: preferences.theme,
            showFullSizePreviewOnHover: preferences.showFullSizePreviewOnHover,
            fullSizePreviewDelay: preferences.fullSizePreviewDelay,
            latchedModeEnabled: preferences.latchedModeEnabled,
            showUsageHints: preferences.showUsageHints,
            searchThreshold: preferences.searchThreshold,
            keepSelectionCentered: preferences.keepSelectionCentered,
            groupLongLists: preferences.groupLongLists,
            quitProtectionEnabled: preferences.quitProtectionEnabled,
            comfortMode: preferences.comfortMode,
            // `visibleFrame`, not `frame`: the row must not be sized to run under the menu
            // bar or the Dock. A machine with no screens at all is not a state this can
            // recover from, but it must not crash on the event-tap path either, so it
            // falls back to a plausible rectangle and the session simply looks wrong.
            screenFrame: (screen ?? preferences.switcherScreen.screen)?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
    }

    /// The panel tint as SwiftUI sees it.
    ///
    /// The fallback repeats `Preferences.defaultBackgroundColor`'s value rather than
    /// reading it, because that static lives on a main-actor-isolated class and this
    /// property has to stay reachable from anywhere the snapshot travels. Only a
    /// hand-edited `defaults write` can reach it — ``current()`` always produces four
    /// components — and a switcher drawn in the shipping grey beats one that traps.
    var background: Color {
        guard backgroundComponents.count == 4 else {
            // Keep this in step with `Preferences.defaultBackgroundColor`. It is duplicated
            // rather than read because that static lives on a main-actor-isolated class and
            // this property must stay reachable wherever the snapshot travels.
            return Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.22)
        }
        return Color(.sRGB,
                     red: backgroundComponents[0],
                     green: backgroundComponents[1],
                     blue: backgroundComponents[2],
                     opacity: backgroundComponents[3])
    }

    /// Height of the uniform box each thumbnail is fitted into.
    ///
    /// The row needs one common box height even though the windows in it have wildly
    /// different shapes: sizing each card to its own window puts every title on a
    /// different baseline, and the row of titles is what the eye scans. 16:10 is the
    /// shape of a typical Mac window and of the display itself, so most thumbnails fill
    /// their box and only the outliers — a tall terminal, a wide timeline — get letterboxed.
    var thumbnailHeight: CGFloat {
        (thumbnailWidth / 1.6).rounded()
    }

    /// The central slice is intentionally small enough to scan without head movement,
    /// and must still fit the display when the user has chosen very large thumbnails.
    var visibleWindowCapacity: Int {
        let cap = comfortMode ? 5 : 7
        let inset: CGFloat = comfortMode ? 13 : 9
        let outerWidth = thumbnailWidth + inset * 2 + 10
        let fits = max(1, Int((screenFrame.width * 0.88) / outerWidth))
        return min(cap, fits)
    }
}

/// Application icons, resolved once per process for the life of a switcher session.
///
/// `NSRunningApplication(processIdentifier:)` followed by `.icon` reaches into Launch
/// Services and, the first time for a given application, off the bundle on disk. A single
/// Tab press re-renders every card in the row, so doing that per card per frame is work
/// paid repeatedly for an answer that cannot change while the panel is up.
///
/// ``reset()`` is called from `SwitcherModel.reset()`, which bounds staleness to one
/// session: a recycled pid could otherwise keep serving the dead process's icon.
@MainActor
enum AppIcons {
    private static var cache: [pid_t: NSImage] = [:]

    static func icon(for pid: pid_t) -> NSImage? {
        if let cached = cache[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        cache[pid] = icon
        return icon
    }

    static func reset() {
        cache.removeAll(keepingCapacity: true)
    }
}
