import SwiftUI

/// The switcher's design tokens, in one place so the panel's geometry maths and the
/// SwiftUI content can never disagree about a number.
///
/// The panel is on screen for a few hundred milliseconds while the user holds a modifier
/// key down, on top of whatever they are actually working on. Every number here serves
/// *time to target*: the thumbnail is the content, the title is the tiebreaker, and the
/// selection has to be findable without reading anything.
///
/// The 2018 original hard-coded a lighter grey plate behind the selected card and 13pt
/// Lucida-era type. Both are kept in shape but not in substance: the selection is now a
/// semantic `.quaternary` fill so it tracks the user's appearance and accent colour, and
/// type comes from `Font.system(_:)` text styles so it follows the system size, which the
/// original's fixed point sizes could not.
enum Design {

    // MARK: Geometry
    //
    // One radius, and everything inside it derived. Curves nested inside a rounded shape
    // only look right when they stay *parallel* to it, which means each level subtracts
    // its own inset rather than picking a number — the previous 18 / 14 / 6 were three
    // unrelated arcs and the eye reads that as three unrelated objects.
    //
    // SwiftUI vends `ConcentricRectangle` for exactly this, but it resolves against the
    // enclosing `containerShape`, and this content lives in a borderless `NSPanel` whose
    // container corner is zero — it would flatten every corner to square. The arithmetic
    // is the same; doing it here keeps it predictable.

    /// The panel's own corner. Sized to sit with macOS 26's window and sheet radii.
    static let panelRadius: CGFloat = 32

    /// Padding between the panel's edge and the first tile's selection shape.
    static let panelPadding: CGFloat = 14

    /// A corner that stays parallel to `radius` when nested `inset` inside it.
    static func concentric(inside radius: CGFloat, inset: CGFloat) -> CGFloat {
        max(4, radius - inset)
    }

    /// The selection lens's corner — one level in from the panel.
    static var tileRadius: CGFloat { concentric(inside: panelRadius, inset: panelPadding) }

    /// The thumbnail's corner — one level in from the selection lens.
    static var thumbnailRadius: CGFloat {
        concentric(inside: tileRadius, inset: selectionInset)
    }

    /// Horizontal gap between two cards.
    ///
    /// Measured from the highlight plate outwards, so the visible gutter between two
    /// *thumbnails* is this plus twice ``selectionInset`` — which is why this number looks
    /// smaller than the original's 24pt while producing the same rhythm.
    static let tileGap: CGFloat = 10

    /// Vertical gap between the application row and the window row in `.appSwitcher`.
    static let rowGap: CGFloat = 14

    /// Gap between a card's thumbnail and its title.
    static let titleGap: CGFloat = 8

    /// Height reserved for a card's title line.
    ///
    /// Fixed rather than intrinsic so every card in the row puts its title on the same
    /// baseline: titles vary in ascender and descender content, and letting each card size
    /// itself makes the row's thumbnails sit at different heights.
    static let titleHeight: CGFloat = 18

    /// How far the selection lens extends beyond the card's content on every side.
    static let selectionInset: CGFloat = 9
    static let comfortSelectionInset: CGFloat = 13
    static let comfortTitleGap: CGFloat = 10
    static let comfortTitleHeight: CGFloat = 22
    static let groupGap: CGFloat = 16

    // MARK: Material

    /// How the travelling selection lens moves between cards.
    ///
    /// Slightly springy, unlike the old `focus` easing. The lens is a physical object in
    /// this design — it slides, it does not cut — and a spring with almost no overshoot is
    /// what reads as weight rather than as animation. Kept short: the user is stepping
    /// through this at key-repeat speed.
    static let lens = Animation.spring(response: 0.28, dampingFraction: 0.86)

    // MARK: Type
    //
    // Window titles carry the identity here — in `.allWindows` most of the row belongs to
    // different applications, and the icon already says which. So the title is the label
    // and the application name is only its fallback.

    static let titleFont = Font.system(.callout)
    static let titleSelectedFont = Font.system(.callout, weight: .semibold)
    static let badgeFont = Font.system(.caption, weight: .semibold)
    static let comfortTitleFont = Font.system(.body)
    static let comfortTitleSelectedFont = Font.system(.body, weight: .bold)

    // MARK: Motion

    /// The panel arriving. A short spring rather than a fade, because the panel appears
    /// *after* the selection has already advanced — it should read as catching up with
    /// the user, not as an animation they have to wait through.
    static let appear = Animation.spring(response: 0.22, dampingFraction: 0.82)

    /// The selection moving between cards. Fast and non-springy: overshoot on a highlight
    /// that the user is stepping through at key-repeat speed turns into visible wobble.
    static let focus = Animation.easeOut(duration: 0.12)

    /// The animation for the user's chosen dismissal style, or `nil` to leave instantly.
    ///
    /// `nil` is a real answer, not a missing one: `HideAnimation.none` exists precisely so
    /// the panel can vanish on the same frame the modifier is released, and handing back
    /// a zero-duration animation instead would still cost a transaction.
    static func hideAnimation(_ kind: HideAnimation) -> Animation? {
        switch kind {
        case .none: nil
        case .fadeOut: .easeIn(duration: 0.12)
        // Slightly longer than the fade: a scale that finishes in 120 ms reads as a
        // glitch, whereas an opacity change at the same duration does not.
        case .scaleDown: .easeIn(duration: 0.16)
        }
    }
}

extension View {
    /// Applies an animation unless the user has asked for reduced motion.
    ///
    /// Reduced motion means *dropped*, not *shortened*: a 60 ms spring is still a spring.
    func motion(_ animation: Animation, value: some Equatable, reduced: Bool) -> some View {
        self.animation(reduced ? nil : animation, value: value)
    }
}
