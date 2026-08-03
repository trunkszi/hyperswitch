import AppKit
import SwiftUI

/// The panel's content: the plate, one or two rows of cards, and the full-size preview.
///
/// This view owns *arrangement* only. What a card looks like belongs to ``WindowTile`` and
/// ``AppTile``, and what a card means belongs to ``SwitcherController`` — the split is what
/// lets a tile be rendered in isolation while the row it lives in still knows about screen
/// widths and wrapping.
///
/// The one piece of real layout logic here is the wrap. A single row is the shape the
/// original had and the shape the eye reads fastest, but twenty windows at 185 pt is a
/// 4,000 pt strip: wider than any display, so it would either hang off both edges or force
/// the cards down to postage stamps. So the row stays a row until it cannot, and then
/// becomes a grid of the same cards.
struct SwitcherView: View {
    let model: SwitcherModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The namespace the selection lens travels in.
    ///
    /// Exactly one card carries the lens at a time and every card offers it the same id, so
    /// when the selection moves SwiftUI has a shape leaving one position and the same shape
    /// arriving at another — which it resolves by *morphing* rather than by cross-fading.
    /// That is the whole reason the highlight slides instead of blinking, and it is the one
    /// thing here that no version of macOS before 26 could draw.

    /// Transparent margin reserved around the plate.
    ///
    /// The panel sets `hasShadow = false` — AppKit derives a borderless window's shadow
    /// from the rendered alpha and only recomputes it when told to, so it lags every
    /// resize and every fade — and SwiftUI draws the shadow instead. A shadow drawn at the
    /// very edge of the window is simply clipped away by the window, so this margin is
    /// where it lands. It is part of `fittingSize`, which is why the panel is measurably
    /// larger than the plate you can see.
    private static let shadowMargin: CGFloat = 30
    private static let shadowRadius: CGFloat = 22

    private var appearance: SwitcherAppearance { model.appearance }

    var body: some View {
        VStack(spacing: appearance.comfortMode ? 14 : 10) {
            if model.isSearching { searchHeader }
            rows
            if footerIsVisible { footer }
        }
            .padding(appearance.comfortMode ? 20 : Design.panelPadding)
            .background(plate)
            .overlay { preview }
            // The preview floats over the plate rather than pushing the rows around, but
            // it is still inside a window, and a window clips. Growing the outer frame to
            // fit it is what keeps it from being sliced off — both it and the plate are
            // centred, so the plate does not move when this kicks in.
            .frame(minWidth: previewExtent?.width, minHeight: previewExtent?.height)
            .padding(Self.shadowMargin)
            // `.system` must apply *nothing*: forcing either scheme would override the
            // Mac's own setting rather than follow it.
            .preferredColorScheme(preferredScheme)
    }

    // MARK: - Plate

    /// The panel surface: Liquid Glass, tinted by the user's colour.
    ///
    /// The colour used to be an opaque wash painted over a blurred capture of the desktop —
    /// a stack that predates macOS 26 and reads like it. Glass refracts what is behind it
    /// rather than covering it, and carries its own edge and shadow, so three layers
    /// (material, fill, hairline stroke) collapse into one and the hand-drawn halo goes.
    ///
    /// Both Appearance settings survive the change and mean more than they did:
    ///
    ///   * the background colour becomes the glass **tint**, so it colours the refraction
    ///     instead of hiding it — the same swatch, now visible as a cast rather than a lid;
    ///   * "Blur window background" picks the glass itself, `.regular` against `.clear`,
    ///     which is the difference between a frosted surface and a barely-there one.
    ///
    /// Reduce Transparency still gets an opaque plate: the request is for *less* to show
    /// through, and clear glass would give it more.
    @ViewBuilder
    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: Design.panelRadius, style: .continuous)
        if reduceTransparency {
            shape
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay { shape.fill(appearance.background) }
                .background { halo }
        } else {
            Color.clear
                .glassEffect(panelGlass, in: shape)
                // The tint is a layer of its own rather than `Glass.tint(_:)`, which does
                // not apply to glass nested inside a composited background — this plate's
                // exact situation. It was silently doing nothing, which meant the
                // Appearance colour well had no effect on the panel at all. Drawn here it
                // sits *inside* `plate`, and `plate` is used as `.background(plate)`, so it
                // stays behind the cards instead of washing over them.
                .overlay { shape.fill(appearance.background) }
                .overlay { shape.strokeBorder(rim, lineWidth: 0.75) }
        }
    }

    /// The light caught along the panel's top edge.
    ///
    /// Glass carries no border of its own, and without one the panel has no silhouette
    /// against content of a similar brightness — over a white document it simply ends,
    /// with nothing to say where. A hairline that is bright at the top and fades by the
    /// bottom reads as a lit edge rather than as a drawn outline, which is what separates a
    /// pane of glass from a rectangle.
    private var rim: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var panelGlass: Glass {
        appearance.blurBackground ? .regular : .clear
    }

    /// The drop shadow, drawn as its own layer with the plate's footprint punched out.
    ///
    /// A plain `.shadow()` on the plate is wrong here, and subtly so. SwiftUI draws the
    /// blur *behind* the content, and this content is deliberately translucent — the
    /// shipping tint is 55 % black — so the darkest part of the shadow shows straight
    /// through the middle of the panel and adds roughly 17 % extra black to whatever
    /// colour was chosen in Appearance. Masking the shape's own area out leaves only the
    /// part that was ever meant to be seen: the halo around the edge.
    private var halo: some View {
        let shape = RoundedRectangle(cornerRadius: Design.panelRadius, style: .continuous)
        return shape
            .fill(Color.black)
            .shadow(color: .black.opacity(0.42), radius: Self.shadowRadius, y: 6)
            .mask {
                // The mask has to reach past the plate, or it clips away the very halo it
                // exists to preserve — a bare `Rectangle()` is exactly the plate's size.
                Rectangle()
                    .padding(-Self.shadowMargin)
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
            }
    }

    private var preferredScheme: ColorScheme? {
        switch appearance.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    // MARK: - Rows

    /// Deliberately *not* wrapped in a `GlassEffectContainer`.
    ///
    /// The container is what would let the highlight morph from card to card, and it was
    /// built that way first. It also discards decorations attached to the glass it owns,
    /// which took the selection's accent ring with it — see ``SelectionLens`` for the
    /// measurements. Only one card carries glass at a time, so there is nothing here for a
    /// container to merge anyway.
    private var rows: some View {
        VStack(spacing: Design.rowGap) {
                if model.mode == .appSwitcher, !model.isSearching { appRow }
                windowRow
        }
    }

    @ViewBuilder
    private var appRow: some View {
        HStack(spacing: Design.tileGap) {
            ForEach(visibleApps) { app in
                AppTile(
                    app: app,
                    isSelected: model.focusRow == .apps && model.selectedAppEntry?.pid == app.pid,
                    comfortMode: appearance.comfortMode,
                    onSelect: { SwitcherController.shared.select(app: app) }
                )
            }
        }
    }

    @ViewBuilder
    private var windowRow: some View {
        if model.isSearchLoading, model.windows.isEmpty {
            loadingRow
        } else if model.windows.isEmpty {
            emptyRow
        } else {
            // `ForEach(displayGroups)`, never `ForEach(displayGroups.indices)`.
            //
            // The index form crashed the app — `Swift runtime failure: Index out of range`,
            // on the main thread, inside `ForEachChild.updateValue()`. `displayGroups` is
            // computed from `model.windows`, and SwiftUI re-runs this child closure *after*
            // the row has been rebuilt: thumbnails arriving, a search filtering the list, or
            // a window closing mid-session all shorten the array between the index being
            // handed out and the subscript being evaluated. Iterating the groups themselves
            // passes each one in by value, so there is no stale index to resolve.
            HStack(alignment: .top, spacing: Design.groupGap) {
                ForEach(displayGroups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        if let key = group.key {
                            Text(verbatim: groupTitle(key))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityAddTraits(.isHeader)
                        }
                        HStack(spacing: Design.tileGap) {
                            ForEach(group.windows) { windowTile($0) }
                        }
                    }
                }
            }
        }
    }

    private func windowTile(_ window: WindowInfo) -> some View {
        WindowTile(
            window: window,
            thumbnail: model.thumbnails[window.id],
            isSelected: isSelected(window),
            width: appearance.thumbnailWidth,
            height: appearance.thumbnailHeight,
            model: model,
            onSelect: { SwitcherController.shared.select(window: window) }
        )
    }

    /// An application with no windows still has to occupy the row.
    ///
    /// Collapsing to nothing would shrink the panel by the height of a card the instant the
    /// selection crossed an application like Preview with nothing open, and then grow it
    /// back on the next press — the row of icons above would jump on every keystroke.
    @ViewBuilder
    private var emptyRow: some View {
        if model.isSearching {
            emptyRowLabel(Text("No matching windows"))
                .accessibilityLabel(Text("No matching windows"))
        } else {
            emptyRowLabel(Text("No Windows"))
                .accessibilityLabel(Text("No Windows"))
        }
    }

    private func emptyRowLabel(_ label: Text) -> some View {
        label
            .font(appearance.comfortMode ? Design.comfortTitleFont : Design.titleFont)
            .foregroundStyle(.tertiary)
            .frame(width: appearance.thumbnailWidth,
                   height: appearance.thumbnailHeight + Design.titleGap + Design.titleHeight)
    }

    private var loadingRow: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading searchable windows…")
                .foregroundStyle(.secondary)
        }
        .frame(width: appearance.thumbnailWidth,
               height: appearance.thumbnailHeight + Design.titleGap + Design.titleHeight)
    }

    /// Only the focused row shows a selection, so the two rows of the app switcher are
    /// never both lit — the highlight *is* the answer to "what does Return do".
    private func isSelected(_ window: WindowInfo) -> Bool {
        guard model.mode != .appSwitcher || model.focusRow == .windows else { return false }
        return model.selectedWindowInfo?.id == window.id
    }

    private var visibleApps: [AppEntry] {
        let capacity = appearance.comfortMode ? 7 : 9
        let range = CenteredSlice.range(count: model.apps.count,
                                        selected: model.selectedApp,
                                        capacity: capacity)
        return Array(model.apps[range.clamped(to: model.apps.indices)])
    }

    private var displayGroups: [WindowGroup] {
        if !model.windowGroups.isEmpty { return model.windowGroups }
        let range = model.visibleWindowRange.clamped(to: model.windows.indices)
        return WindowGrouping.groups(Array(model.windows[range]), threshold: .max)
    }

    private func groupTitle(_ key: WindowGroupKey) -> String {
        guard let space = key.spaceNumber else { return key.applicationName }
        return "\(key.applicationName) · \(Localization.string("Desktop \(space)"))"
    }

    // MARK: - Search and help

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            if model.query.isEmpty {
                Text("Type to search windows")
                    .foregroundStyle(.tertiary)
            } else {
                Text(verbatim: model.query)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            if model.isSearchLoading { ProgressView().controlSize(.mini) }
        }
        .font(appearance.comfortMode ? .body : .callout)
        .padding(.horizontal, 12)
        .padding(.vertical, appearance.comfortMode ? 9 : 7)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Window search"))
        .accessibilityValue(Text(verbatim: model.query))
    }

    private var footerIsVisible: Bool {
        model.isLatched || model.statusMessage != nil || model.showsUsageHints
            || model.windows.count > appearance.visibleWindowCapacity
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isLatched { stateBadge("Pinned") }
            if let status = model.statusMessage {
                keycap("Q")
                Text(verbatim: status)
                    .foregroundStyle(.primary)
            } else if model.showsUsageHints {
                usageHintView
            }
            Spacer(minLength: 8)
            if model.windows.count > appearance.visibleWindowCapacity,
               model.selectedWindow >= 0 {
                Text(verbatim: "\(model.selectedWindow + 1) / \(model.windows.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Window position"))
            }
        }
        .font(appearance.comfortMode ? .callout : .caption)
        .accessibilityElement(children: .combine)
    }

    private var usageHint: LocalizedStringKey {
        if model.isSearching {
            return "Type to search · Delete edits · Escape clears or cancels · Return opens"
        }
        if model.isLatched {
            return "Type to search · Arrow keys navigate · Return opens · Escape cancels"
        }
        return "Press Space to keep the switcher open · Release the modifier to switch"
    }

    private var usageHintKeys: [String] {
        if model.isSearching { return ["⌫", "esc", "↩"] }
        if model.isLatched { return ["↑↓←→", "↩", "esc"] }
        return ["Space"]
    }

    private var usageHintView: some View {
        HStack(spacing: 5) {
            ForEach(Array(usageHintKeys.enumerated()), id: \.offset) { _, key in
                keycap(key)
            }
            Text(usageHint)
                .foregroundStyle(.secondary)
        }
    }

    private func keycap(_ key: String) -> some View {
        Text(verbatim: key)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(.tertiary, lineWidth: 0.75)
            }
            .accessibilityHidden(true)
    }

    private func stateBadge(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quinary, in: Capsule())
    }

    /// The display this session was pinned to, read from the snapshot rather than resolved
    /// a second time here.
    ///
    /// `switcherScreen` can name "the screen with the mouse", and the controller resolves
    /// it once at `begin` exactly so the pointer cannot move the panel out from under
    /// itself. Asking `Preferences` again from the view reopened that hole one level down:
    /// the panel would stay put while the row wrapped for whichever display the pointer had
    /// since wandered onto, on the first redraw after a hover or a Tab.
    private var screenFrame: CGRect { appearance.screenFrame }

    // MARK: - Full-size preview

    private var fullSizeTarget: WindowInfo? {
        guard appearance.showFullSizePreviewOnHover, let id = model.fullSizeWindow else { return nil }
        return model.windows.first { $0.id == id }
    }

    @ViewBuilder
    private var preview: some View {
        // Read from the dedicated slot, not from `thumbnails`. The two carry different
        // pictures on purpose — the grid keeps the small one, this keeps the sharp one —
        // and the slot's id is what stops the previous card's capture being drawn under
        // the current one during the moment before the new capture lands.
        if let window = fullSizeTarget,
           let slot = model.fullSizeImage, slot.id == window.id {
            FullSizePreview(image: slot.thumbnail.image, size: previewSize(for: window))
        }
    }

    /// The frame the panel has to reach for the preview to fit inside the window.
    ///
    /// `nil` while nothing is being previewed, which is what leaves the panel at its
    /// natural size the rest of the time. The margin is for the preview's own drop shadow,
    /// which extends past its frame.
    private var previewExtent: CGSize? {
        guard let window = fullSizeTarget,
              model.fullSizeImage?.id == window.id else { return nil }
        let size = previewSize(for: window)
        return CGSize(width: size.width + 28, height: size.height + 28)
    }

    /// Sized against the snapshot's screen, not a freshly resolved one: the controller
    /// requests the capture at `FullSizePreview`'s cap for the *pinned* display, so a view
    /// measuring against a different display would draw a picture captured at the wrong
    /// resolution — soft on the way up, cropped on the way down.
    private func previewSize(for window: WindowInfo) -> CGSize {
        FullSizePreview.size(forAspectRatio: window.aspectRatio, in: screenFrame)
    }
}
