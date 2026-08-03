import AppKit
import SwiftUI

/// One application in the `.appSwitcher` top row: a large icon, its window count, and its
/// name.
///
/// Deliberately close to the system's own ⌘Tab strip, because that is the thing being
/// replaced and muscle memory is aimed at it — a row of big icons with the selected one
/// on a rounded plate. The two additions are the ones that justify replacing it at all:
/// a window count, and a name under every icon instead of only under the selected one, so
/// the row can be read without stepping through it.
///
/// Hover lives in local state rather than in `SwitcherModel`. The model tracks a hovered
/// *window* because the full-size preview needs one; an application has nothing behind it
/// to drive, so pushing it into shared state would only invalidate every other tile.
struct AppTile: View {
    /// Edge length of the icon. Matches the system switcher's own tile closely enough
    /// that the substitution is not jarring, while staying small enough that a row of
    /// twenty applications still fits a laptop display.
    static let iconSide: CGFloat = 56

    /// Width of one card. Fixed rather than intrinsic so the row is an even rhythm and
    /// the panel's width is a multiplication instead of a layout pass.
    static let tileWidth: CGFloat = 96

    let app: AppEntry
    let isSelected: Bool
    let comfortMode: Bool
    let onSelect: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: comfortMode ? Design.comfortTitleGap : Design.titleGap) {
            icon
                .frame(width: Self.iconSide, height: Self.iconSide)
                .overlay(alignment: .topTrailing) { countBadge }
                // The badge overhangs the icon's corner, so the icon's box has to be
                // allowed to spill rather than clip it.
                .padding(.top, 4)
                .padding(.trailing, 4)
            name
        }
        .frame(width: Self.tileWidth)
        .padding(comfortMode ? Design.comfortSelectionInset : Design.selectionInset)
        .selectionLens(isSelected: isSelected, isHovered: isHovered,
                       isComfortable: comfortMode)
        .motion(Design.lens, value: isSelected, reduced: reduceMotion)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction { onSelect() }
    }

    // MARK: Icon

    @ViewBuilder
    private var icon: some View {
        if let image = AppIcons.icon(for: app.pid) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            // The application went away between the row being built and this frame being
            // drawn. A placeholder keeps the row's rhythm intact for the one frame before
            // the controller notices.
            Image(systemName: "app.dashed")
                .font(.system(size: Self.iconSide * 0.7, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }

    /// Shown only past one window, because "1" on every icon is noise: the interesting
    /// fact is that an application has *several*, since that is when ↓ into the window
    /// row is worth pressing.
    @ViewBuilder
    private var countBadge: some View {
        if app.windowCount > 1 {
            Text(verbatim: "\(app.windowCount)")
                .font(Design.badgeFont)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.tint, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
                .offset(x: 6, y: -4)
        }
    }

    // MARK: Name

    private var name: some View {
        Text(app.name)
            .font(comfortMode
                  ? (isSelected ? Design.comfortTitleSelectedFont : Design.comfortTitleFont)
                  : (isSelected ? Design.titleSelectedFont : Design.titleFont))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            // Tail truncation here, unlike a window title: application names are
            // front-loaded ("Visual Studio Code"), so the first word identifies them and
            // middle truncation would only cut out the part that does.
            .frame(width: Self.tileWidth,
                   height: comfortMode ? Design.comfortTitleHeight : Design.titleHeight)
            .help(Text(app.name))
    }

    private var accessibilityDescription: String {
        guard app.windowCount > 0 else { return app.name }
        return "\(app.name), \(Localization.string("\(app.windowCount) windows"))"
    }
}
