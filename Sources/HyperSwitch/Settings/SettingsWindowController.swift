import AppKit
import SwiftUI

/// The panes of the settings window.
///
/// The original had four tabs in a segmented strip across the top; the four panes survive
/// but the strip does not — see ``SettingsView`` for why. What each case carries is
/// everything the sidebar and the AppKit surfaces need to draw a row for it.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appSwitcher, interaction, appearance, about
    var id: String { rawValue }

    /// For SwiftUI. This must be a `LocalizedStringKey` rather than a
    /// `String(localized:)` result: only a key is resolved through the environment's
    /// locale, so `String(localized:)` here would leave the sidebar stuck in the source
    /// language while the rest of the pane translates.
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .appSwitcher: "App Switcher"
        case .interaction: "Interaction"
        case .appearance: "Appearance"
        case .about: "About"
        }
    }

    /// For AppKit surfaces, which resolve against an explicit bundle instead.
    var titleKey: String.LocalizationValue {
        switch self {
        case .general: "General"
        case .appSwitcher: "App Switcher"
        case .interaction: "Interaction"
        case .appearance: "Appearance"
        case .about: "About"
        }
    }

    /// An SF Symbol per tab. Icons give the sidebar a second, language-independent cue,
    /// which matters more than usual here: the Chinese labels are two or three characters
    /// against much longer English ones, so the list's shape changes entirely between
    /// languages while the icon column stays constant.
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appSwitcher: "square.stack.3d.up.fill"
        case .interaction: "hand.raised.fill"
        case .appearance: "paintpalette.fill"
        case .about: "info"
        }
    }

    /// System semantic colours only — nothing bespoke to re-audit under Increase Contrast.
    var tint: Color {
        switch self {
        case .general: .gray
        case .appSwitcher: .blue
        case .interaction: .green
        case .appearance: .pink
        case .about: .gray
        }
    }

    /// The three panes that hold actual settings.
    static var primary: [SettingsTab] { [.general, .appSwitcher, .interaction, .appearance] }

    /// Demoted into a second group: About is not part of daily use, and separating it
    /// says so without needing a header that would outweigh the single row beneath it.
    static var secondary: [SettingsTab] { [.about] }
}

/// Shared, observable tab selection so the window controller can deep-link into a pane.
@MainActor
@Observable
final class TabSelection {
    var current: SettingsTab = .general
}

/// Hosts the settings window.
///
/// An agent app has no windows of its own by default, so this is created on demand and
/// kept alive between openings to preserve the selected tab and the window's position.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let selection = TabSelection()

    private override init() { super.init() }

    /// Whether the window exists *and* is on screen. A closed window is kept alive, so
    /// `window != nil` is not the same question.
    var isOpen: Bool { window?.isVisible ?? false }

    /// The CoreGraphics window number, for `screencapture -l <id>` during testing.
    /// `nil` while the window is closed, since capturing an off-screen window yields a
    /// stale or empty image rather than an error.
    var windowNumber: Int? {
        guard let window, window.isVisible else { return nil }
        return window.windowNumber
    }

    func show(selecting tab: SettingsTab) {
        selection.current = tab

        if window == nil {
            let root = SettingsView(selection: selection)
            let hosting = NSHostingController(rootView: root)

            let created = NSWindow(contentViewController: hosting)
            // Resizable, and with a full-size content view plus a unified toolbar so the
            // sidebar's material runs up behind the title bar. That continuous strip is
            // most of what distinguishes a current macOS window from the 2018 one this
            // replaces — and the window must resize because General is considerably
            // taller than any fixed height that also suits About.
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable,
                                 .fullSizeContentView]
            created.titlebarAppearsTransparent = false
            created.toolbarStyle = .unified
            // An empty toolbar, not no toolbar: `.unified` only takes effect when one
            // exists, and without it the title bar draws as a separate opaque bar with a
            // hairline under it, which is exactly the look being avoided.
            created.toolbar = NSToolbar()
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.setContentSize(NSSize(width: 780, height: 580))
            created.center()
            window = created
        }
        // Retitled on every open so a live language change is reflected; the title is set
        // once at creation and would otherwise keep the language it was born with.
        window?.title = Localization.string("HyperSwitch")

        // The settings window is the one place the app legitimately comes forward.
        // Presence owns the activation policy — it is a user setting here, not something
        // this controller may decide — but it knows the window needs keyboard focus, and
        // an app that stays an agent never gets any: macOS 14's cooperative activation
        // ignores `activate` from an accessory app, which leaves every number field in
        // here visible, clickable and impossible to type into.
        Presence.settingsOpened()
        // `activate(ignoringOtherApps:)` is deprecated as of macOS 14; plain `activate()`
        // does the same thing now that the policy above has made us a regular app.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the window without discarding it, so reopening lands on the same tab.
    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Deferred: the window is still closing, and dropping the activation policy out
        // from under it leaves the app frontmost with nothing to show.
        Task { @MainActor in
            Presence.settingsClosed()
        }
    }
}
