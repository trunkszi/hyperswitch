import SwiftUI

/// Interaction aids that reduce sustained key holds, visual travel and destructive slips.
struct InteractionPane: View {
    @State private var preferences = Preferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("Allow Space to keep the switcher open",
                       isOn: $preferences.latchedModeEnabled)
                Toggle("Show keyboard hints after a short pause",
                       isOn: $preferences.showUsageHints)
            } header: {
                Text("Hands and keyboard")
            } footer: {
                Text("Pinned mode lets you release the modifier, browse with the arrow keys, type to search, press Return to open, or Escape to cancel.")
            }

            Section {
                LabeledContent("Enable search and grouping at") {
                    NumberField(value: $preferences.searchThreshold,
                                range: 5...30, unit: "windows", digits: 2)
                }
                Toggle("Keep the selection in the central visual band",
                       isOn: $preferences.keepSelectionCentered)
                Toggle("Group long lists by app and Desktop",
                       isOn: $preferences.groupLongLists)
            } header: {
                Text("Long lists")
            } footer: {
                Text("HyperSwitch draws only the nearby 5–7 cards. All results remain reachable, while layout and thumbnail work stay bounded.")
            }

            Section {
                Toggle("Require Q twice before quitting an app",
                       isOn: $preferences.quitProtectionEnabled)
            } header: {
                Text("Safety")
            } footer: {
                Text("The second Q must target the same app within 0.9 seconds. Moving the selection cancels the confirmation.")
            }
        }
    }
}
