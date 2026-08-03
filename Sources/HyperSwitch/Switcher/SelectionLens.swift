import SwiftUI

/// The highlight that marks the one card Return will act on.
///
/// A single modifier rather than a copy in each tile, because the two rows must not drift:
/// in `.appSwitcher` the highlight moves between an application card and one of its window
/// cards, and both have to draw the same shape for that to read as one object moving.
///
/// **It is applied to the card, not behind it.** `glassEffect` renders the material as the
/// modified view's own backing and composites the content on top; putting it on a
/// `Color.clear` inside `.background { }` instead produced a sheet of glass floating *over*
/// the card — thumbnail and title both vanished behind a white blur.
///
/// Hover is deliberately not glass. The pointer resting on a card must never look like the
/// thing the keyboard has selected.
///
/// ## Why there is no `GlassEffectContainer` morph
///
/// The obvious macOS 26 treatment is `glassEffectID` inside a `GlassEffectContainer`, so the
/// highlight *morphs* from card to card instead of cross-fading. It was built that way first
/// and then removed, because the container silently drops decorations on the glass it owns.
/// Measured side by side in a test harness, with an opaque red ring for visibility:
///
/// | construction                                    | ring |
/// | ----------------------------------------------- | ---- |
/// | `glassEffect` + `overlay`                       | ✓    |
/// | in container, `glassEffectID`, then `overlay`   | ✗    |
/// | in container, `overlay`, then `glassEffectID`   | ✗    |
/// | in container, no ID, `glassEffect` + `overlay`  | ✗    |
/// | `overlay` on the container itself               | ✓    |
///
/// The container re-renders the glass shapes it owns in its own pass to make them mergeable,
/// and anything attached to those views is not part of what it re-renders. Only a sibling in
/// the container survives — and a sibling cannot size itself to one card without the card's
/// geometry, which is a lot of machinery to buy an animation.
///
/// It is not much of a loss. The morph's appeal is watching the highlight travel, and this
/// panel is driven at key-repeat speed: the trailing edge is still leaving the second card
/// when the third is selected, which reads as smearing rather than as motion. A cross-fade
/// on ``Design/lens`` is the honest treatment for something being stepped through.
struct SelectionLens: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    let isComfortable: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.tileRadius, style: .continuous)
    }

    /// The accent, read from AppKit rather than through `Color.accentColor`.
    ///
    /// SwiftUI resolves `.accentColor` against the *window's* active state, and this content
    /// lives in a panel that deliberately never becomes key, so the accent arrived as
    /// graphite on a Mac whose accent is blue.
    private var accent: Color { Color(nsColor: .controlAccentColor) }

    /// The accent ring, and why the accent is a *stroke* rather than a glass tint.
    ///
    /// `Glass.tint(_:)` is the obvious way to colour a lens, and it works — in a plain
    /// window. It stops applying once the glass is nested inside a composited background,
    /// which is exactly this panel's structure: the cards are drawn over a full-bleed glass
    /// plate. Measured rather than guessed — with the tint forced to *opaque red* the lens
    /// still rendered `#D0D2D5`, a neutral grey whose blue channel was five points above its
    /// red. The identical construction in a bare test window came out vividly red.
    ///
    /// So the material is left untinted and the accent is drawn as a shape, which composites
    /// normally instead of depending on how the glass samples its backdrop.
    ///
    /// It is also the better design. A *neutral* highlight is only findable while the panel
    /// behind it is darker than it is, and this panel is transparent — over a white document
    /// the plate measured `#FFFFFF`, and a light-grey selection on white is not a selection.
    /// A ring in the user's accent reads against anything the panel happens to be over.
    ///
    /// The gradient is a half-stop of light falling from above, the same cue the panel's own
    /// rim uses; a flat stroke of one colour reads as a border drawn on top of the surface
    /// rather than as an edge belonging to it.
    private var ring: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.6)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var ringWidth: CGFloat { isComfortable ? 3 : 2 }

    func body(content: Content) -> some View {
        if isSelected {
            if reduceTransparency {
                // Glass *is* a transparency effect, so with it suppressed the highlight has
                // to be rebuilt from something opaque. A tinted fill plus the same ring reads
                // as "selected" at the same glance, without asking to see through anything.
                content
                    .background { shape.fill(accent.opacity(0.26)) }
                    .overlay { shape.strokeBorder(ring, lineWidth: ringWidth) }
            } else {
                content
                    .glassEffect(.regular.interactive(), in: shape)
                    .overlay { shape.strokeBorder(ring, lineWidth: ringWidth) }
            }
        } else if isHovered {
            content.background { shape.fill(.quinary) }
        } else {
            content
        }
    }
}

extension View {
    func selectionLens(isSelected: Bool, isHovered: Bool,
                       isComfortable: Bool = false) -> some View {
        modifier(SelectionLens(isSelected: isSelected, isHovered: isHovered,
                               isComfortable: isComfortable))
    }
}
