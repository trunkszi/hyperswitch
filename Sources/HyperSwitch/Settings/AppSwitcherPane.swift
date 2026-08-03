import SwiftUI

/// Settings for the ⌘Tab switcher.
///
/// The first toggle is not a display option: with it on we intercept ⌘Tab and draw the
/// switcher ourselves, and with it off the system's own switcher is left completely
/// untouched. Everything below only exists inside our version, which is why it all greys
/// out together — see ``Preferences/appSwitcherPreviewsEnabled`` and PLAN §3.1 for why
/// drawing our own is the only option: Dock's switcher is a single full-screen window that
/// exposes neither the strip's position nor which application is selected.
struct AppSwitcherPane: View {
    @State private var preferences = Preferences.shared

    private var previewsOn: Bool { preferences.appSwitcherPreviewsEnabled }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.appSwitcherPreviewsEnabled) {
                    Text("Show window previews on the app switcher (⌘ + Tab)")
                }
            } header: { EmptyView() } footer: {
                Text("Use the arrow keys to move between the app row and its windows.")
            }

            Section {
                LabeledContent("Delay activation for") {
                    // Stacked under one label rather than given a label each: they are two
                    // halves of one answer, and repeating "Delay activation for" twice
                    // reads as two unrelated settings.
                    VStack(alignment: .leading, spacing: 6) {
                        NumberField(value: $preferences.appSwitcherDelayFirst,
                                    range: 0...5000, unit: "ms on first activation")
                        NumberField(value: $preferences.appSwitcherDelaySubsequent,
                                    range: 0...5000, unit: "ms on subsequent activations")
                    }
                }
                .disabled(!previewsOn)
            } header: { EmptyView() } footer: {
                Text("The application row appears at once. Only the window previews wait, so a quick ⌘Tab stays quick.")
            }

            Section {
                Toggle(isOn: $preferences.openDefaultWindow) {
                    Text("When activating an app without windows, try to open the default window")
                }
                .disabled(!previewsOn)

                HStack(spacing: 8) {
                    Toggle(isOn: $preferences.autoActivateEnabled) {
                        Text("Automatically activate the current app after")
                    }
                    Spacer(minLength: 8)
                    NumberField(value: $preferences.autoActivateDelay,
                                range: 0...10000, unit: "ms", digits: 5,
                                isEnabled: preferences.autoActivateEnabled)
                }
                .disabled(!previewsOn)
            } header: { EmptyView() } footer: {
                // Both settings are implemented inside our own ⌘Tab session and nowhere
                // else, so with previews off they are inert. Greying them out says that
                // much but not *why*, and "why is this greyed out" with no answer on
                // screen is what sends someone hunting for a bug that is not there.
                Text("Both apply only while HyperSwitch is drawing the ⌘Tab switcher. With previews off the system's own switcher takes over and neither has any effect.")
            }
        }
    }
}
