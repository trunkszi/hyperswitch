import AppKit
import SwiftUI

/// Identity, language and permissions, plus the destructive escape hatch.
///
/// The original's About tab carried "automatically check for software updates", "download
/// & install in the background" and "send anonymous usage statistics". All three were
/// front-ends to services this rewrite does not have — a Sparkle appcast and the author's
/// statistics server — so shipping them as switches would mean shipping three controls
/// that do nothing. They are replaced by the two things this build genuinely needs a home
/// for: the interface language, and the state of the two permissions without which the
/// app cannot work. PLAN §4.4 records the deviation.
struct AboutPane: View {
    @State private var preferences = Preferences.shared
    @State private var permissions = Permissions.shared

    /// The version as a person would say it.
    ///
    /// Build number omitted: it means something to whoever compiled the app and nothing to
    /// whoever is reading this pane.
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "HyperSwitch")
                            .font(.title3.weight(.semibold))
                        Text("Version \(version)")
                            .foregroundStyle(.secondary)
                        // Says what the app does for the reader, not how it was built.
                        Text("Hold a modifier and press Tab to see every open window as a preview — including windows on other desktops and ones you have minimized — then release on the one you want.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }

            Section {
                Picker("Interface language", selection: $preferences.language) {
                    // "Match System" is translated because it describes a behaviour, but
                    // each language is named in itself — a reader looking for their own
                    // language finds it whatever the interface currently shows.
                    Text("Match System").tag(InterfaceLanguage.system)
                    Text(verbatim: "简体中文").tag(InterfaceLanguage.simplifiedChinese)
                    Text(verbatim: "English").tag(InterfaceLanguage.english)
                }
            } header: { Text("Language") } footer: {
                Text("Takes effect immediately — no restart needed.")
            }

            Section {
                LabeledContent("Accessibility") {
                    PermissionBadge(granted: permissions.hasAccessibility,
                                    open: permissions.openAccessibilitySettings)
                }
                LabeledContent("Screen Recording") {
                    PermissionBadge(granted: permissions.hasScreenRecording,
                                    open: permissions.openScreenRecordingSettings)
                }
            } header: { Text("Permissions") } footer: {
                Text("Accessibility lets HyperSwitch see the hotkeys and raise, close and minimize windows — without it nothing here works. Screen Recording adds the window thumbnails and the real window titles.")
            }

            Section {
                HStack(spacing: 12) {
                    // Not "Visit Homepage" / "Support": this rewrite has no homepage and
                    // no issue tracker, and a button that opens github.com because it had
                    // to open *something* is a dead link wearing a real one's label. The
                    // two things someone actually needs from an About pane when the app
                    // misbehaves are the log and the bundle it is running from, and both
                    // of those exist.
                    Button("Open Console") { openConsole() }
                    Button("Reveal in Finder") { revealInFinder() }
                    Spacer(minLength: 12)
                    Button(role: .destructive) {
                        confirmRestoreDefaults()
                    } label: {
                        Text("Restore Defaults")
                    }
                }
            }
        }
        // The permission watcher runs continuously, but a grant made in System Settings
        // while this pane was closed should be visible the instant it is opened rather
        // than up to a poll interval later.
        .onAppear { permissions.refresh() }
    }

    /// Opens Console.app, which is where everything `Log` writes ends up.
    private func openConsole() {
        let workspace = NSWorkspace.shared
        // Asked for by bundle identifier rather than by path: Console has moved between
        // /Applications/Utilities and /System/Applications/Utilities across releases, so
        // the literal path is the fallback for the case where Launch Services has no
        // answer at all, not the first choice.
        let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.Console")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        workspace.openApplication(at: url,
                                  configuration: NSWorkspace.OpenConfiguration(),
                                  completionHandler: nil)
    }

    /// Selects this app's own bundle in the Finder.
    ///
    /// Worth a button because HyperSwitch normally has no Dock tile and may have no menu
    /// bar icon either — "where is the app I am looking at the settings of" is otherwise
    /// a genuinely awkward question to answer.
    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Asks first, through `NSAlert` rather than `confirmationDialog`.
    ///
    /// SwiftUI's presentation never appeared from here: attached inside the detail pane of
    /// a `NavigationSplitView` the dialog has no presentation context, and the button
    /// simply did nothing.
    private func confirmRestoreDefaults() {
        let alert = NSAlert()
        alert.messageText = Localization.string("Restore all settings to their defaults?")
        alert.informativeText = Localization.string(
            "Every preference returns to the value HyperSwitch ships with, and it stops opening at login. This cannot be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: Localization.string("Restore Defaults"))
        alert.addButton(withTitle: Localization.string("Cancel"))
        // A destructive default would make Return wipe the settings, so the safe button
        // takes the Return key and restoring has to be chosen deliberately.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Preferences.shared.resetToDefaults()
        // The Dock tile and the menu bar item are only ever changed by Presence, so
        // restoring the defaults for `showInDock` / `showInMenuBar` has no visible effect
        // until it is told to look again.
        Presence.apply()
    }
}

/// Granted / not granted, with a way to fix it when it is the latter.
struct PermissionBadge: View {
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(granted ? "Granted" : "Not granted")
            } icon: {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
            }
            if !granted {
                Button("Open Settings", action: open)
                    .buttonStyle(.link)
            }
        }
    }
}
