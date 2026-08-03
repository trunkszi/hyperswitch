import AppKit
import SwiftUI

/// One window, drawn as a card: thumbnail, the owning application's icon centred on it,
/// and the window's title underneath.
///
/// This is the original's shape, kept because it is right — the icon says *which
/// application* at a glance and the screenshot says *which window*, and neither alone is
/// enough when a row holds four Terminal windows and two browsers. What changed is the
/// material: the selection is a semantic `.quaternary` plate instead of a hard-coded
/// lighter grey, so it tracks light/dark and the user's accent rather than assuming a
/// dark panel.
///
/// The card is deliberately inert about *what selecting means*: it reports a tap through
/// ``onSelect`` and writes hover straight into the model. It never touches
/// `SwitcherController`, so it can be rendered from a preview or a test with nothing else
/// running.
struct WindowTile: View {
    let window: WindowInfo
    let thumbnail: Thumbnail?
    let isSelected: Bool
    /// Width of the thumbnail box. Every card in a row shares it, so the titles line up.
    let width: CGFloat
    /// Height of the thumbnail box — also uniform across the row. The image is fitted
    /// inside by its own aspect ratio, which is why a tall window shows as a narrow
    /// picture in a wide box rather than as a stretched one.
    let height: CGFloat
    let model: SwitcherModel
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var appearance: SwitcherAppearance { model.appearance }
    private var isHovered: Bool { model.hoveredWindow == window.id }

    var body: some View {
        VStack(spacing: appearance.comfortMode ? Design.comfortTitleGap : Design.titleGap) {
            thumbnailBox
            title
        }
        .padding(appearance.comfortMode ? Design.comfortSelectionInset : Design.selectionInset)
        .selectionLens(isSelected: isSelected, isHovered: isHovered,
                       isComfortable: appearance.comfortMode)
        // Registered here rather than inside the branch: the two states are different
        // views, so an animation attached in there has no shared ancestor to interpolate
        // across and the highlight snaps. It also picks up the title's weight change,
        // which should move with the lens rather than after it.
        .motion(Design.lens, value: isSelected, reduced: reduceMotion)
        // The plate, not the thumbnail, is the hit target: the gap around a card belongs
        // to that card, so clicking just under a title still picks the window.
        .contentShape(Rectangle())
        .onHover { inside in
            // A hover the pointer did not cause. Re-fitting the panel slides the cards
            // around under a stationary pointer, and SwiftUI reports that as entering a
            // card — which would ask for a full-size capture, re-fit the panel again, and
            // so on. See `SwitcherModel.ignoresPointer`.
            guard !model.ignoresPointer else { return }
            if inside {
                model.hoveredWindow = window.id
            } else if model.hoveredWindow == window.id {
                // Only clear our own hover. The pointer leaving this card and entering the
                // next one delivers the two events in an order that is not guaranteed, and
                // clearing unconditionally can wipe the neighbour's hover right after it
                // was set.
                model.hoveredWindow = nil
            }
        }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // `.accessibilityAction { }` rather than `(perform:)`: the trailing-closure form is
        // the only overload SwiftUI vends for the default action.
        .accessibilityAction { onSelect() }
    }

    // MARK: Thumbnail

    private var thumbnailBox: some View {
        thumbnailImage
            .aspectRatio(window.aspectRatio, contentMode: .fit)
            .clipShape(shape)
            // A hairline, not a drop shadow. The shadow was there to lift a screenshot off
            // an opaque grey plate; against glass it reads as grime, and glass already
            // separates what sits on it. What is still needed is an edge for a window whose
            // own content is near-white — hence a stroke rather than nothing.
            .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
            .overlay(alignment: .center) { centredIcon }
            .overlay(alignment: .bottomLeading) { iconBadge.padding(6) }
            .overlay(alignment: .topTrailing) { badges.padding(6) }
            .frame(width: width, height: height)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.thumbnailRadius, style: .continuous)
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let thumbnail {
            Image(decorative: thumbnail.image, scale: 1)
                .resizable()
                // A minimised window is not on any screen, so these pixels are a memory
                // rather than live content. Fading says so without hiding what it is.
                .opacity(window.isMinimized ? 0.55 : 1)
        } else {
            // A neutral plate, not a spinner: captures land in ~20 ms on the hot path and
            // a spinner that appears and vanishes that fast is just a flicker. The
            // application icon is drawn on top regardless, so an empty card is still
            // identifiable while its screenshot is in flight.
            Rectangle().fill(.quaternary)
        }
    }

    /// The icon at full size, in the middle — but only when there is no screenshot yet.
    ///
    /// It used to sit here always, and it was covering the one thing that distinguishes one
    /// card from the next: at the shipping 185 pt width a Large icon blanks out the centre
    /// of every preview, so a row of three Chrome windows came out looking identical. The
    /// screenshot is the entire reason this panel exists rather than ⌘Tab, so the icon
    /// steps aside for it — and steps back in when there is nothing to step aside for,
    /// where it stops being an annotation and becomes the content.
    @ViewBuilder
    private var centredIcon: some View {
        if thumbnail == nil, appearance.showAppIcons, let icon = AppIcons.icon(for: window.pid) {
            let side = min(appearance.appIconPoints, min(width, height) * 0.55)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
        }
    }

    /// The icon as a corner badge, once the screenshot has arrived.
    ///
    /// Bottom-leading because window content crowds the top: title bars, tab strips and
    /// toolbars all live up there, and a badge over a toolbar hides the very thing that
    /// says which document this is.
    @ViewBuilder
    private var iconBadge: some View {
        if thumbnail != nil, appearance.showAppIcons, let icon = AppIcons.icon(for: window.pid) {
            // Scaled off the same preference so Small / Medium / Large still mean
            // something, then clamped so a Large badge on a Small thumbnail cannot swallow
            // the corner it is annotating.
            let side = min(appearance.appIconPoints * 0.62, min(width, height) * 0.30)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
    }

    // MARK: Badges

    /// Says where the window is, when that is not "on screen, right here".
    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if window.isMinimized {
                Image(systemName: "minus.circle.fill")
                    .font(Design.badgeFont)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
                    .padding(2)
                    .background(plateStyle, in: Circle())
            }
            if !window.isOnCurrentSpace, let number = window.spaceNumber {
                // The bare number, not "Desktop 3": the badge sits in a 6pt corner of a
                // screenshot, and the full phrase either shrinks to unreadable or covers
                // the picture. The word is carried by the tooltip and the accessibility
                // label instead.
                Text(verbatim: "\(number)")
                    .font(Design.badgeFont)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(plateStyle,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }

    /// Badges sit on a material plate because they land on an arbitrary screenshot: a
    /// plain translucent fill disappears against a white document or a black terminal.
    private var plateStyle: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.thinMaterial)
    }

    // MARK: Title

    private var title: some View {
        Text(window.displayTitle)
            .font(appearance.comfortMode
                  ? (isSelected ? Design.comfortTitleSelectedFont : Design.comfortTitleFont)
                  : (isSelected ? Design.titleSelectedFont : Design.titleFont))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .lineLimit(1)
            // Middle truncation keeps both ends. Windows of the same application often
            // differ only in a leading path or a trailing file name, and tail truncation
            // reduces a whole row to the same repeated prefix.
            .truncationMode(.middle)
            .frame(width: width,
                   height: appearance.comfortMode ? Design.comfortTitleHeight : Design.titleHeight)
            .help(Text(helpText))
    }

    private var helpText: String {
        var parts = [window.displayTitle]
        if window.isMinimized {
            parts.append(Localization.string("Minimized"))
        } else if !window.isOnCurrentSpace, let number = window.spaceNumber {
            parts.append(Localization.string("Desktop \(number)"))
        }
        return parts.joined(separator: " — ")
    }

    private var accessibilityDescription: String {
        var parts = [window.displayTitle, window.applicationName]
        if window.isMinimized {
            parts.append(Localization.string("Minimized"))
        } else if !window.isOnCurrentSpace, let number = window.spaceNumber {
            parts.append(Localization.string("Desktop \(number)"))
        }
        return parts.joined(separator: ", ")
    }
}
