import SwiftUI

/// Everything about *when* the window switcher appears and what it lists.
///
/// Ordered as the original's General tab was, because the order is the story: turn the app
/// on, bind the two switchers, tune how long it waits, then decide which windows count.
struct GeneralPane: View {
    @State private var preferences = Preferences.shared
    @State private var showsCalibration = false
    @State private var confirmsReset = false

    var body: some View {
        let _ = preferences.revision
        Form {
            Section {
                Toggle(isOn: $preferences.launchAtLogin) {
                    Text("Run HyperSwitch in the background")
                }
            } header: { EmptyView() } footer: {
                // The failure text replaces the explanation rather than joining it. When
                // the switch has just sprung back on its own, "if enabled, HyperSwitch
                // keeps running…" is describing something that did not happen, and the
                // reason it did not is the only thing worth the space.
                if let failure = preferences.loginItemFailure {
                    Label {
                        Text("Could not change the login item: \(failure)")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("If enabled, HyperSwitch keeps running in the background and is automatically started when you log in.")
                }
            }

            Section {
                // The two hotkey rows share one Grid rather than being two independent
                // Form rows, so the modifier pop-ups line up in a column. Laid out as
                // separate rows they cannot: the first ends in a static "+ ⇥ (Tab)" and
                // the second in a second pop-up, so any trailing-edge alignment leaves the
                // modifier pop-ups at different x positions.
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                    GridRow {
                        Toggle(isOn: $preferences.windowSwitcherEnabled) {
                            Text("All windows")
                        }
                        .gridColumnAlignment(.leading)

                        ModifierChoicePicker(combo: $preferences.windowSwitcherModifier)

                        // Tab is not configurable for the all-windows switcher: it is the
                        // gesture the whole app is named after, and every muscle memory
                        // being ported from the original depends on it.
                        Text("+ ⇥ (Tab)")
                            .foregroundStyle(.secondary)
                    }
                    GridRow {
                        Toggle(isOn: $preferences.currentAppSwitcherEnabled) {
                            Text("Current app's windows")
                        }

                        ModifierChoicePicker(combo: $preferences.currentAppSwitcherModifier)

                        HStack(spacing: 8) {
                            Text(verbatim: "+")
                                .foregroundStyle(.secondary)
                            keyPicker
                        }
                    }
                }

                LabeledContent("Delay activation for") {
                    NumberField(value: $preferences.windowSwitcherDelay,
                                range: 0...5000, unit: "ms")
                }

                Button("Calibrate delay…") { showsCalibration = true }

                Picker("Show on Screen", selection: $preferences.switcherScreen) {
                    Text("Active Screen").tag(SwitcherScreen.active)
                    Text("Screen with Mouse").tag(SwitcherScreen.withMouse)
                    Text("Main Screen").tag(SwitcherScreen.main)
                }
            } header: {
                Text("Activate the window switcher for")
            } footer: {
                // Explains the one piece of behaviour that is otherwise invisible: below
                // the delay the switcher acts without ever drawing anything.
                Text("Releasing the modifier before the delay elapses switches straight away, without showing the switcher.")
            }

            Section {
                Toggle(isOn: $preferences.includeOtherSpaces) {
                    Text("Include windows from other spaces")
                }
                Toggle(isOn: $preferences.includeOtherScreens) {
                    Text("Include windows from other screens")
                }
                // Not in the original's General tab, which had no way to reach minimized
                // windows at all. The switcher can raise them, so the setting that decides
                // whether they are listed belongs with the other two.
                Toggle(isOn: $preferences.includeMinimized) {
                    Text("Include minimized windows")
                }
                Toggle(isOn: $preferences.showFullSizePreviewOnHover) {
                    Text("Show full size previews on hover")
                }
                if preferences.showFullSizePreviewOnHover {
                    LabeledContent("Full size preview delay") {
                        NumberField(value: $preferences.fullSizePreviewDelay,
                                    range: 0...5000, unit: "ms")
                    }
                }
                Toggle(isOn: $preferences.shiftCyclesBackwards) {
                    Text("Use shift to cycle backwards")
                }
            }

            Section {
                if shortcutConflicts.isEmpty {
                    Label("No shortcut conflicts detected", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(shortcutConflicts.enumerated()), id: \.offset) { _, conflict in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: conflict.binding.displayValue)
                                    .fontWeight(.semibold)
                                Text(verbatim: conflictDescription(conflict))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                HStack {
                    Button("Use recommended shortcuts") { useRecommendedShortcuts() }
                    Spacer()
                    Button("Restore Defaults", role: .destructive) { confirmsReset = true }
                }
            } header: {
                Text("Shortcut conflicts")
            } footer: {
                Text("Checks HyperSwitch bindings and enabled macOS symbolic shortcuts. macOS does not provide a reliable list of shortcuts owned privately by other apps.")
            }
        }
        .sheet(isPresented: $showsCalibration) { DelayCalibrationSheet() }
        .confirmationDialog(
            "Restore all HyperSwitch settings to their defaults?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) { preferences.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var shortcutConflicts: [ShortcutConflict] {
        ShortcutConflictDetector.conflicts(
            hyperSwitch: hyperSwitchBindings,
            system: SystemShortcutReader.current()
        )
    }

    private var hyperSwitchBindings: [ShortcutBinding] {
        [
            ShortcutBinding(
                id: "all-windows", label: Localization.string("All windows"),
                modifiers: preferences.windowSwitcherModifier, keyCode: KeyCodes.tab,
                source: .hyperSwitch, enabled: preferences.windowSwitcherEnabled
            ),
            ShortcutBinding(
                id: "current-app", label: Localization.string("Current app's windows"),
                modifiers: preferences.currentAppSwitcherModifier,
                keyCode: CGKeyCode(truncatingIfNeeded: preferences.currentAppSwitcherKeyCode),
                source: .hyperSwitch, enabled: preferences.currentAppSwitcherEnabled
            ),
            ShortcutBinding(
                id: "app-switcher", label: Localization.string("App Switcher"),
                modifiers: .command, keyCode: KeyCodes.tab,
                source: .hyperSwitch, enabled: preferences.appSwitcherPreviewsEnabled
            ),
        ]
    }

    private func conflictDescription(_ conflict: ShortcutConflict) -> String {
        String(
            format: Localization.string("%@ conflicts with %@"),
            conflict.binding.label,
            conflict.conflictingWith.label
        )
    }

    private func useRecommendedShortcuts() {
        preferences.windowSwitcherEnabled = true
        preferences.windowSwitcherModifier = .option
        preferences.currentAppSwitcherEnabled = true
        preferences.currentAppSwitcherModifier = .option
        preferences.currentAppSwitcherKeyCode = Int(KeyCodes.graveAccent)
        preferences.appSwitcherPreviewsEnabled = true
    }

    /// The key that, with its modifier, opens the current application's windows.
    ///
    /// `ForEach` is driven by indices rather than `id: \.code`: `KeyCodes.selectable` holds
    /// tuples, and Swift key paths cannot address a tuple element.
    private var keyPicker: some View {
        Picker("", selection: $preferences.currentAppSwitcherKeyCode) {
            ForEach(KeyCodes.selectable.indices, id: \.self) { index in
                let entry = KeyCodes.selectable[index]
                Text(verbatim: entry.label).tag(Int(entry.code))
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// The `⌥ (Option)` pop-up shared by both switcher rows.
///
/// Each row is composed into a plain `String` and shown with `Text(verbatim:)`. The
/// alternative — a `Text` built from an interpolated `LocalizedStringKey` — would register
/// a junk key of `"%@ (%@)"` in the string catalogue, and concatenating three `Text`s to
/// keep only the middle one localisable is unreadable for what is ultimately one label.
/// Reading `preferences.language` here is what makes the rows rebuild on a live language
/// change: a verbatim string does not consult the environment's locale, so without that
/// observation dependency the names would stay in whichever language they were drawn in.
struct ModifierChoicePicker: View {
    @Binding var combo: ModifierCombo
    @State private var preferences = Preferences.shared

    var body: some View {
        Picker("", selection: $combo) {
            ForEach(ModifierCombo.selectable, id: \.rawValue) { choice in
                Text(verbatim: label(for: choice)).tag(choice)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func label(for choice: ModifierCombo) -> String {
        let name = Localization.string(choice.nameKey, language: preferences.language)
        return "\(choice.symbols) (\(name))"
    }
}
