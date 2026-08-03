import AppKit
import SwiftUI

/// How the switcher panel looks, and where the app itself is visible.
struct AppearancePane: View {
    @State private var preferences = Preferences.shared

    // Read here for the same reason the switcher reads them: two of the controls below are
    // overridden by these system settings, and a control that is live and unexplained while
    // its preference is being ignored is the failure this pane already greys the blur
    // switch to avoid. Same source as the panel — SwitcherView reads these environment
    // values and SwitcherPanel reads NSWorkspace's twin of the motion one — so the
    // interface cannot disagree with what actually happens.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $preferences.theme) {
                    Text("System Default").tag(AppearanceTheme.system)
                    Text("Light").tag(AppearanceTheme.light)
                    Text("Dark").tag(AppearanceTheme.dark)
                }

                ColorPicker("Background color", selection: backgroundColor,
                            supportsOpacity: true)

                Toggle(isOn: $preferences.blurBackground) {
                    Text("Blur window background")
                }
                // Blur has nothing to work with once the tint is fully opaque — there is
                // no way to see the blurred content behind it — so the switch is greyed
                // rather than silently doing nothing. The original greyed it too; this is
                // the reason why.
                //
                // Reduce Transparency is the same failure from the other side: the plate
                // takes the opaque branch (SwitcherView) and never reads this preference,
                // so the switch used to flip freely with nothing on screen changing.
                .disabled(reduceTransparency || !isBackgroundTranslucent)
            } header: { EmptyView() } footer: {
                // Ordered like the plate's own branches, not shown side by side: with
                // Reduce Transparency on, "lower the opacity" is advice that cannot work,
                // and printing it would send the user off to fix the wrong thing.
                if reduceTransparency {
                    Text("Reduce Transparency is on, so the switcher already uses an opaque background.")
                } else if !isBackgroundTranslucent {
                    Text("Lower the background colour's opacity to blur what is behind the switcher.")
                }
            }

            Section {
                Toggle("Comfort display: larger labels and targets",
                       isOn: $preferences.comfortMode)

                LabeledContent("Thumbnail size") {
                    HStack(spacing: 10) {
                        // Filled squares of differing size, not two outlined rectangles of
                        // the same weight: `rectangle` at two point sizes renders as a
                        // pair of near-identical empty boxes that say nothing about which
                        // end is which. A small solid square against a large one reads
                        // instantly.
                        Slider(value: $preferences.thumbnailSize,
                               in: Preferences.thumbnailRange) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "square.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Image(systemName: "square.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 170)

                        // The original showed only Small…Large, which makes the setting
                        // impossible to return to. A number can be matched again later.
                        Text("\(Int(preferences.thumbnailSize)) px")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 54, alignment: .trailing)
                    }
                }

                Picker("Quality", selection: $preferences.thumbnailQuality) {
                    Text("Low").tag(ThumbnailQuality.low)
                    Text("Medium").tag(ThumbnailQuality.medium)
                    Text("High").tag(ThumbnailQuality.high)
                }

                HStack(spacing: 8) {
                    Toggle(isOn: $preferences.showAppIcons) {
                        Text("Show app icons")
                    }
                    Spacer(minLength: 8)
                    Picker("", selection: $preferences.appIconSize) {
                        Text("Small").tag(AppIconSize.small)
                        Text("Medium").tag(AppIconSize.medium)
                        Text("Large").tag(AppIconSize.large)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!preferences.showAppIcons)
                }

                Picker("Hide animation", selection: $preferences.hideAnimation) {
                    Text("Fade out").tag(HideAnimation.fadeOut)
                    Text("Scale down").tag(HideAnimation.scaleDown)
                    Text("No animation").tag(HideAnimation.none)
                }
                // Reduce Motion collapses all three choices into an instant disappearance
                // (SwitcherPanel.hide), so the picker was three settings that produced one
                // result with nothing saying so.
                .disabled(reduceMotion)
            } footer: {
                if preferences.comfortMode {
                    Text("Comfort display shows at most five nearby windows with stronger selection outlines and larger text.")
                } else if reduceMotion {
                    Text("Reduce Motion is on, so the switcher always disappears instantly.")
                }
            }

            Section {
                Toggle(isOn: $preferences.showInDock) {
                    Text("the Dock")
                }
                .onChange(of: preferences.showInDock) { _, _ in presenceChanged() }

                Toggle(isOn: $preferences.showInMenuBar) {
                    Text("the menu bar")
                }
                .onChange(of: preferences.showInMenuBar) { _, _ in presenceChanged() }
            } header: {
                Text("Show HyperSwitch in")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("With both off HyperSwitch keeps running, but has no visible way in. Opening it again from the Applications folder brings the menu bar icon back.")
                    // `Presence.apply` pins the policy to `.regular` for as long as this
                    // window is open, because an `.accessory` app cannot hold keyboard
                    // focus and every number field here would stop accepting typing.
                    // The consequence is that unchecking "the Dock" leaves the tile
                    // sitting there, which reads as the switch having failed.
                    Text("The Dock icon returns to its setting once this window closes.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Applies the new presence at once — the point of these two switches is the surface
    /// appearing and disappearing as they are flipped. The Dock tile is the one exception,
    /// and `Presence.apply` says why it cannot go until this window does; the footer says
    /// the same thing to the person watching it stay put.
    private func presenceChanged() {
        Presence.apply()
        guard !preferences.showInDock, !preferences.showInMenuBar else { return }
        // Deferred by one runloop turn rather than called from inside `onChange`.
        // `warnIfHiddenEverywhere` ends in `NSAlert.runModal()`, which spins a nested
        // modal runloop; started in the middle of a SwiftUI update transaction that
        // freezes the toggle mid-animation and re-enters the view update from inside
        // itself. The alert has to outlive this update, not interrupt it.
        Task { @MainActor in
            Presence.warnIfHiddenEverywhere()
        }
    }

    // MARK: - Colour bridging

    /// `ColorPicker` speaks `Color`; the panel and the stored preference speak `NSColor`.
    ///
    /// Both directions are pinned to sRGB rather than left to whatever space the picker
    /// hands back. Two reasons: the preference is persisted as four plain components, so
    /// the space has to be one both ends agree on; and a `Color` coming out of the picker
    /// can be in Display P3, whose components are numerically different for the same
    /// visible colour — round-tripping through the untagged store would shift the tint
    /// slightly on every launch.
    private var backgroundColor: Binding<Color> {
        Binding(
            get: {
                let srgb = preferences.backgroundColor.usingColorSpace(.sRGB)
                    ?? Preferences.defaultBackgroundColor
                return Color(.sRGB,
                             red: Double(srgb.redComponent),
                             green: Double(srgb.greenComponent),
                             blue: Double(srgb.blueComponent),
                             opacity: Double(srgb.alphaComponent))
            },
            set: { newValue in
                preferences.backgroundColor =
                    NSColor(newValue).usingColorSpace(.sRGB) ?? Preferences.defaultBackgroundColor
            }
        )
    }

    private var isBackgroundTranslucent: Bool {
        let srgb = preferences.backgroundColor.usingColorSpace(.sRGB)
            ?? Preferences.defaultBackgroundColor
        return srgb.alphaComponent < 1
    }
}
