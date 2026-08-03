import AppKit
import Observation

// MARK: - Enumerations

/// How the switcher panel picks its light/dark appearance.
enum AppearanceTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }

    /// `aqua`/`darkAqua`, not `vibrantLight`/`vibrantDark`.
    ///
    /// The vibrant appearances are the pre-Liquid-Glass mechanism for content hosted inside
    /// an `NSVisualEffectView`, and they blend what is drawn in them toward the material
    /// underneath — which desaturates colour. That is fatal to a panel whose selection is
    /// marked by an accent-coloured ring: picking Light or Dark in Appearance would have
    /// quietly bleached the one element that says which card is selected. Glass supplies the
    /// translucency here, so the appearance only needs to say which way light and dark go.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Capture resolution for window thumbnails.
///
/// `nonisolated` because `ThumbnailEngine` is an actor and reads `scale` off the main
/// actor. Without it, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes every member of
/// this enum main-actor isolated and the engine cannot touch them — and it must not hop
/// to the main actor to find out how big an image to ask for.
nonisolated enum ThumbnailQuality: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    var id: String { rawValue }

    /// Multiplier on the requested pixel size.
    ///
    /// Capture cost is dominated by the compositor rather than by pixel count, so this
    /// is less about speed than about memory: a switcher showing twenty previews at 2×
    /// Retina holds a meaningful amount of image data, and Low halves each dimension.
    var scale: CGFloat {
        switch self {
        case .low: 0.5
        case .medium: 0.75
        case .high: 1.0
        }
    }
}

/// Size of the application icon overlaid on each window preview.
enum AppIconSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large
    var id: String { rawValue }

    var points: CGFloat {
        switch self {
        case .small: 28
        case .medium: 44
        case .large: 64
        }
    }
}

/// What the panel does when it goes away.
enum HideAnimation: String, CaseIterable, Identifiable, Sendable {
    case fadeOut, scaleDown, none
    var id: String { rawValue }
}

/// Which display the switcher appears on.
enum SwitcherScreen: String, CaseIterable, Identifiable, Sendable {
    case active, withMouse, main
    var id: String { rawValue }

    /// Resolves to a concrete screen, falling back to the main one.
    @MainActor
    /// Optional, and every fallback stops at `NSScreen.main`.
    ///
    /// The previous version ended each branch with `NSScreen.screens[0]`, which traps on
    /// an empty array — and this is read synchronously from the event-tap callback, so
    /// "the display went away" (a clamshell close mid-hotkey, a docking station dropping
    /// out, screen sharing tearing down) would take the whole app with it. There is no
    /// sensible screen to substitute when there are none, so the caller is told so.
    var screen: NSScreen? {
        switch self {
        case .main:
            return NSScreen.screens.first ?? NSScreen.main
        case .withMouse:
            let point = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(point) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
        case .active:
            // "Active" means the screen holding the key window of the frontmost
            // application. NSScreen.main is exactly that — despite the name, it is the
            // screen with the active window, not the one with the menu bar.
            return NSScreen.main ?? NSScreen.screens.first
        }
    }
}

/// Language the interface is presented in, independent of the system setting.
enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    var id: String { rawValue }
}

/// A set of modifier keys, stored as our own stable raw value rather than
/// `NSEvent.ModifierFlags`'s, which is a system type we should not persist.
///
/// `nonisolated` on the type rather than on individual members: the event tap matches
/// incoming flags against these combos, and under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` even `static let option` would otherwise
/// be a main-actor property — taking the *conformance to OptionSet* with it, which is
/// what actually breaks first ("main actor-isolated conformance … cannot be used in a
/// nonisolated context").
nonisolated struct ModifierCombo: OptionSet, Sendable, Codable, Hashable {
    let rawValue: UInt
    init(rawValue: UInt) { self.rawValue = rawValue }

    static let control  = ModifierCombo(rawValue: 1 << 0)
    static let option   = ModifierCombo(rawValue: 1 << 1)
    static let command  = ModifierCombo(rawValue: 1 << 2)
    static let shift    = ModifierCombo(rawValue: 1 << 3)
    static let function = ModifierCombo(rawValue: 1 << 4)

    /// The single-modifier choices offered in the settings pickers.
    ///
    /// Shift is absent on purpose: it is the "cycle backwards" modifier, so binding the
    /// switcher itself to it would make backwards cycling unreachable.
    static let selectable: [ModifierCombo] = [.option, .control, .command, .function]

    nonisolated var eventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// True when every modifier in this combo is currently held.
    nonisolated func isSatisfied(by flags: CGEventFlags) -> Bool {
        !isEmpty && flags.contains(eventFlags)
    }

    /// `⌥ (Option)` — the symbol plus its name, as the settings pickers show it.
    var symbols: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.command) { parts.append("⌘") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.function) { parts.append("fn") }
        return parts.joined()
    }

    /// A localisation key naming this modifier, for the picker rows.
    var nameKey: String.LocalizationValue {
        if contains(.control) { return "Control" }
        if contains(.option) { return "Option" }
        if contains(.command) { return "Command" }
        if contains(.shift) { return "Shift" }
        if contains(.function) { return "Function" }
        return "None"
    }
}

// MARK: - Store

/// Every user-facing setting, persisted to `UserDefaults`.
///
/// Defaults are taken from the original HyperSwitch's own `HSDefaultPreferences.plist`
/// (kept in `docs/reference/`) so the app behaves identically on first launch rather
/// than requiring a setup pass.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let store = UserDefaults.standard
    private init() {}

    /// Bumped whenever any setting is written.
    ///
    /// Every property here is a computed pass-through to `UserDefaults`, which
    /// `@Observable` cannot see: it tracks reads and writes of *stored* properties, so a
    /// getter that reaches straight into defaults registers no dependency and a setter
    /// posts no change. Controls bound with `$preferences.x` still work, because the
    /// binding drives the control directly — which is why this is easy to miss. It only
    /// surfaces with settings that must redraw views other than their own control, of
    /// which `language` is the clearest case.
    private(set) var revision = 0

    private func write(_ value: Any?, _ key: String) {
        store.set(value, forKey: key)
        revision &+= 1
        // The event tap decides from a snapshot on its own thread and cannot read this
        // object at all. Republishing on every write is what keeps a setting the user just
        // changed from taking effect only after the next session — and it is one struct
        // copy behind a lock, on a path that runs when a human moves a control.
        HotKeyState.shared.publish(preferences: hotKeySnapshot)
    }

    /// The hotkey-relevant settings, read straight from the store.
    ///
    /// Deliberately bypasses `observed`: this is called from `write`, and registering an
    /// observation dependency there would make every setting appear to depend on every
    /// other one.
    var hotKeySnapshot: HotKeyPreferenceSnapshot {
        HotKeyPreferenceSnapshot(
            appSwitcherPreviewsEnabled: bool("appSwitcherPreviewsEnabled", default: true),
            windowSwitcherEnabled: bool("windowSwitcherEnabled", default: true),
            windowSwitcherModifier: modifiers("windowSwitcherModifier", default: .option),
            currentAppSwitcherEnabled: bool("currentAppSwitcherEnabled", default: true),
            currentAppSwitcherKeyCode: int("currentAppSwitcherKeyCode",
                                           default: Int(KeyCodes.graveAccent)),
            currentAppSwitcherModifier: modifiers("currentAppSwitcherModifier", default: .option),
            shiftCyclesBackwards: bool("shiftCyclesBackwards", default: false)
        )
    }

    /// Reads a stored value, registering an observation dependency on the way.
    private func observed<T>(_ read: () -> T) -> T {
        _ = revision
        return read()
    }

    // MARK: General

    /// Registered as a login item, so the app is running and its hotkeys live before the
    /// user needs them.
    ///
    /// Reads and writes the login item itself rather than a stored copy of the answer.
    /// A stored copy drifts: registration can fail, and the user can remove the item in
    /// System Settings, either of which leaves the switch showing "on" for something
    /// that will not happen.
    var launchAtLogin: Bool {
        get { observed { LoginItem.isEnabled } }
        set {
            switch LoginItem.setEnabled(newValue) {
            case .success:
                loginItemFailure = nil
            case .failure(let error):
                loginItemFailure = error.localizedDescription
            }
            revision &+= 1
        }
    }

    /// Why the last attempt to change the login item failed, or `nil` if it did not.
    ///
    /// A stored property, unlike everything else here, because it is not a setting — it is
    /// the outcome of the last attempt, and it must not survive a relaunch. Without it the
    /// switch springs back on the next redraw and the user is left with a control that
    /// undoes itself for no stated reason; `launchAtLogin` reads the real service, so
    /// there is nothing else for them to go on.
    private(set) var loginItemFailure: String?

    /// The all-windows switcher, bound to a modifier plus Tab.
    var windowSwitcherEnabled: Bool {
        get { observed { bool("windowSwitcherEnabled", default: true) } }
        set { write(newValue, "windowSwitcherEnabled") }
    }

    var windowSwitcherModifier: ModifierCombo {
        get { observed { modifiers("windowSwitcherModifier", default: .option) } }
        set { write(newValue.rawValue, "windowSwitcherModifier") }
    }

    /// The current-application switcher, bound to a modifier plus a chosen key.
    var currentAppSwitcherEnabled: Bool {
        get { observed { bool("currentAppSwitcherEnabled", default: true) } }
        set { write(newValue, "currentAppSwitcherEnabled") }
    }

    var currentAppSwitcherModifier: ModifierCombo {
        get { observed { modifiers("currentAppSwitcherModifier", default: .option) } }
        set { write(newValue.rawValue, "currentAppSwitcherModifier") }
    }

    /// Virtual key code. 50 is the key left of `1` on an ANSI layout — `` ` `` — which
    /// the original labelled `§ / \``, because on an ISO layout the same physical key
    /// carries `§`.
    var currentAppSwitcherKeyCode: Int {
        get { observed { int("currentAppSwitcherKeyCode", default: Int(KeyCodes.graveAccent)) } }
        set { write(newValue, "currentAppSwitcherKeyCode") }
    }

    /// Milliseconds the modifier must stay held before the panel appears. Releasing
    /// inside this window is a "quick switch": it acts without ever showing UI.
    var windowSwitcherDelay: Int {
        get { observed { int("windowSwitcherDelay", default: 80) } }
        set { write(newValue, "windowSwitcherDelay") }
    }

    var switcherScreen: SwitcherScreen {
        get { observed { enumValue("switcherScreen", default: .active) } }
        set { write(newValue.rawValue, "switcherScreen") }
    }

    var includeOtherSpaces: Bool {
        get { observed { bool("includeOtherSpaces", default: false) } }
        set { write(newValue, "includeOtherSpaces") }
    }

    var includeOtherScreens: Bool {
        get { observed { bool("includeOtherScreens", default: false) } }
        set { write(newValue, "includeOtherScreens") }
    }

    var includeMinimized: Bool {
        get { observed { bool("includeMinimized", default: false) } }
        set { write(newValue, "includeMinimized") }
    }

    var showFullSizePreviewOnHover: Bool {
        get { observed { bool("showFullSizePreviewOnHover", default: false) } }
        set { write(newValue, "showFullSizePreviewOnHover") }
    }

    /// Milliseconds the pointer must rest on a preview before it is blown up.
    var fullSizePreviewDelay: Int {
        get { observed { int("fullSizePreviewDelay", default: 800) } }
        set { write(newValue, "fullSizePreviewDelay") }
    }

    var shiftCyclesBackwards: Bool {
        get { observed { bool("shiftCyclesBackwards", default: false) } }
        set { write(newValue, "shiftCyclesBackwards") }
    }

    // MARK: Interaction

    /// Space can pin the panel so browsing no longer requires holding a modifier.
    var latchedModeEnabled: Bool {
        get { observed { bool("latchedModeEnabled", default: true) } }
        set { write(newValue, "latchedModeEnabled") }
    }

    /// Context-sensitive keyboard help shown only after the quick-switch interval.
    var showUsageHints: Bool {
        get { observed { bool("showUsageHints", default: true) } }
        set { write(newValue, "showUsageHints") }
    }

    /// Candidate count at which search and visual grouping become useful.
    var searchThreshold: Int {
        get { observed { min(max(int("searchThreshold", default: 9), 5), 30) } }
        set { write(min(max(newValue, 5), 30), "searchThreshold") }
    }

    var keepSelectionCentered: Bool {
        get { observed { bool("keepSelectionCentered", default: true) } }
        set { write(newValue, "keepSelectionCentered") }
    }

    var groupLongLists: Bool {
        get { observed { bool("groupLongLists", default: true) } }
        set { write(newValue, "groupLongLists") }
    }

    var quitProtectionEnabled: Bool {
        get { observed { bool("quitProtectionEnabled", default: true) } }
        set { write(newValue, "quitProtectionEnabled") }
    }

    /// Suppresses repeated launch-time permission guidance. The system permission prompt
    /// itself is never automatic; this tracks only the one-time in-app explanation.
    var hasShownPermissionIntroduction: Bool {
        get { observed { bool("hasShownPermissionIntroduction", default: false) } }
        set { write(newValue, "hasShownPermissionIntroduction") }
    }

    // MARK: App switcher

    /// Whether ⌘Tab is intercepted and drawn by us, with a row of window previews under
    /// the application icons. Off hands ⌘Tab back to the system untouched.
    var appSwitcherPreviewsEnabled: Bool {
        get { observed { bool("appSwitcherPreviewsEnabled", default: true) } }
        set { write(newValue, "appSwitcherPreviewsEnabled") }
    }

    /// Milliseconds before the preview row appears the first time ⌘Tab is used. The
    /// application row is immediate; only the previews wait, so a fast ⌘Tab stays fast.
    var appSwitcherDelayFirst: Int {
        get { observed { int("appSwitcherDelayFirst", default: 500) } }
        set { write(newValue, "appSwitcherDelayFirst") }
    }

    /// Shorter on subsequent uses, once the user is evidently browsing rather than
    /// flicking between two applications.
    var appSwitcherDelaySubsequent: Int {
        get { observed { int("appSwitcherDelaySubsequent", default: 300) } }
        set { write(newValue, "appSwitcherDelaySubsequent") }
    }

    var openDefaultWindow: Bool {
        get { observed { bool("openDefaultWindow", default: true) } }
        set { write(newValue, "openDefaultWindow") }
    }

    var autoActivateEnabled: Bool {
        get { observed { bool("autoActivateEnabled", default: false) } }
        set { write(newValue, "autoActivateEnabled") }
    }

    var autoActivateDelay: Int {
        get { observed { int("autoActivateDelay", default: 500) } }
        set { write(newValue, "autoActivateDelay") }
    }

    // MARK: Appearance

    var theme: AppearanceTheme {
        get { observed { enumValue("theme", default: .system) } }
        set { write(newValue.rawValue, "theme") }
    }

    /// The panel's background tint, stored as sRGB components so nothing depends on
    /// `NSKeyedArchiver`'s format surviving an OS upgrade.
    var backgroundColor: NSColor {
        get {
            observed {
                guard let components = store.array(forKey: "backgroundColor") as? [Double],
                      components.count == 4
                else { return Self.defaultBackgroundColor }
                return NSColor(srgbRed: components[0], green: components[1],
                               blue: components[2], alpha: components[3])
            }
        }
        set {
            let srgb = newValue.usingColorSpace(.sRGB) ?? Self.defaultBackgroundColor
            write([srgb.redComponent, srgb.greenComponent,
                   srgb.blueComponent, srgb.alphaComponent], "backgroundColor")
        }
    }

    /// A wash, not a lid.
    ///
    /// The original shipped 55 % black because its panel was an opaque plate and the colour
    /// *was* the surface. The surface is Liquid Glass now: the material supplies the value
    /// and the contrast, so a tint that heavy covers the refraction it is painted on and the
    /// panel goes back to looking like the slab this replaced.
    ///
    /// The first attempt at the other extreme was worse. At 10 % the panel over a white
    /// document measured `#FFFFFF` — it had no silhouette at all, and the cards floated with
    /// nothing holding them. Roughly a fifth of black keeps the panel a discrete object over
    /// bright content while still reading as glass over dark content, which is the range this
    /// has to work across. The colour well reaches the old value for anyone who wants it.
    static let defaultBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22)

    /// Whether the panel's own tint sits on top of a blurred capture of what is behind
    /// it. Only meaningful once the tint is translucent; at full opacity there is
    /// nothing to see through.
    var blurBackground: Bool {
        get { observed { bool("blurBackground", default: true) } }
        set { write(newValue, "blurBackground") }
    }

    /// Width in points of one window preview.
    var thumbnailSize: Double {
        get { observed { double("thumbnailSize", default: 185) } }
        set { write(min(max(newValue, Self.thumbnailRange.lowerBound),
                        Self.thumbnailRange.upperBound), "thumbnailSize") }
    }

    static let thumbnailRange: ClosedRange<Double> = 90...360

    var thumbnailQuality: ThumbnailQuality {
        get { observed { enumValue("thumbnailQuality", default: .high) } }
        set { write(newValue.rawValue, "thumbnailQuality") }
    }

    var showAppIcons: Bool {
        get { observed { bool("showAppIcons", default: true) } }
        set { write(newValue, "showAppIcons") }
    }

    var appIconSize: AppIconSize {
        get { observed { enumValue("appIconSize", default: .large) } }
        set { write(newValue.rawValue, "appIconSize") }
    }

    var hideAnimation: HideAnimation {
        get { observed { enumValue("hideAnimation", default: .fadeOut) } }
        set { write(newValue.rawValue, "hideAnimation") }
    }

    /// Larger labels and hit targets with fewer simultaneous cards.
    var comfortMode: Bool {
        get { observed { bool("comfortMode", default: false) } }
        set { write(newValue, "comfortMode") }
    }

    var showInDock: Bool {
        get { observed { bool("showInDock", default: true) } }
        set { write(newValue, "showInDock") }
    }

    var showInMenuBar: Bool {
        get { observed { bool("showInMenuBar", default: true) } }
        set { write(newValue, "showInMenuBar") }
    }

    /// Whether the user has been told how to get back in after hiding both the Dock tile
    /// and the menu bar icon. Shown once.
    var hasSeenPresenceNotice: Bool {
        get { observed { bool("hasSeenPresenceNotice", default: false) } }
        set { write(newValue, "hasSeenPresenceNotice") }
    }

    // MARK: Language

    var language: InterfaceLanguage {
        get { observed { enumValue("language", default: .system) } }
        set { write(newValue.rawValue, "language") }
    }

    // MARK: - Reset

    /// Returns every setting to its shipping value.
    ///
    /// Removes the whole persistent domain rather than writing each key back: that also
    /// clears state this type does not own but AppKit writes into the same domain — the
    /// status item's remembered visibility, window frame autosaves — which is what a
    /// person means by "reset", and leaving it behind is how a reset ends up not fixing
    /// whatever prompted it.
    ///
    /// The login item lives outside the domain, so it is unregistered explicitly.
    func resetToDefaults() {
        // Ahead of the wipe, because the record of having taken the system's ⌘Tab lives in
        // this same domain. Clearing it first would strand that shortcut switched off with
        // nothing left in the app that knows to give it back — a reset that breaks ⌘Tab
        // system-wide is the exact opposite of what the button promises.
        SystemHotKeys.restore()
        if let domain = Bundle.main.bundleIdentifier {
            store.removePersistentDomain(forName: domain)
        }
        LoginItem.setEnabled(false)
        revision &+= 1
        HotKeyState.shared.publish(preferences: hotKeySnapshot)
    }

    // MARK: - Backing helpers

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        store.object(forKey: key) as? Bool ?? fallback
    }

    private func int(_ key: String, default fallback: Int) -> Int {
        store.object(forKey: key) as? Int ?? fallback
    }

    private func double(_ key: String, default fallback: Double) -> Double {
        store.object(forKey: key) as? Double ?? fallback
    }

    private func enumValue<T: RawRepresentable>(_ key: String, default fallback: T) -> T
    where T.RawValue == String {
        guard let raw = store.string(forKey: key), let value = T(rawValue: raw) else {
            return fallback
        }
        return value
    }

    private func modifiers(_ key: String, default fallback: ModifierCombo) -> ModifierCombo {
        guard let raw = store.object(forKey: key) as? UInt else { return fallback }
        return ModifierCombo(rawValue: raw)
    }
}
