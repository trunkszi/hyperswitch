import AppKit
import SwiftUI

/// The large preview that appears when the pointer rests on a card.
///
/// An overlay drawn *over* the panel rather than a bigger card inside it. Growing the
/// hovered card would push every other card out from under the pointer, so the user would
/// lose their place at the exact moment they asked to look closer — the opposite of what
/// the gesture means. Floating it on top leaves the row untouched.
///
/// Takes a `CGImage` and a size rather than a `WindowInfo` on purpose: it has no opinion
/// about *which* window it is showing, so the controller can hand it a full-resolution
/// capture, a cached thumbnail, or anything else it already has, without this view needing
/// to know where the pixels came from.
struct FullSizePreview: View {
    let image: CGImage
    let size: CGSize

    /// Driven from `onAppear` rather than from a `.transition`, so the fade happens
    /// whether the parent inserts this view conditionally or swaps its content while it
    /// is already on screen.
    @State private var revealed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.panelRadius, style: .continuous)
    }

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay {
                // A hairline, not a border: the preview is often a screenshot whose own
                // edge is nearly the colour of whatever is behind the panel, and without
                // this it looks like a hole rather than a picture.
                shape.strokeBorder(.white.opacity(0.16), lineWidth: 1)
            }
            // The shadow is cast by an opaque plate *behind* the picture rather than by the
            // picture itself. SwiftUI derives a shadow from the rendered alpha of whatever
            // it is attached to, so `.shadow` on the image meant rasterising 1800 × 1126
            // pixels of screenshot and running a radius-24 blur over them — on every
            // relayout, on the main thread, which is the exact path this preview is already
            // the most expensive thing on. Blurring a filled rounded rectangle is the same
            // picture to the eye, because the image is opaque and covers the plate whole.
            .background {
                shape
                    .fill(.black)
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            }
            .opacity(revealed ? 1 : 0)
            // Barely there: a preview that grows from 90% draws the eye to the motion
            // instead of to the picture, and this surface exists to be looked at
            // immediately.
            .scaleEffect(revealed ? 1 : 0.98)
            // Purely informational — it must never intercept the pointer that summoned it,
            // which is still resting on the card underneath.
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else {
                    revealed = true
                    return
                }
                withAnimation(.easeOut(duration: 0.14)) { revealed = true }
            }
    }

    /// The size a preview of the given shape should be drawn at.
    ///
    /// Capped at half the width and 55% of the height of the visible screen area. A
    /// "full size" preview that genuinely matched the window would cover the switcher it
    /// was summoned from on any laptop display, which makes the row it belongs to
    /// unusable while it is up.
    @MainActor
    static func size(forAspectRatio aspectRatio: CGFloat, on screen: NSScreen) -> CGSize {
        size(forAspectRatio: aspectRatio, in: screen.visibleFrame)
    }

    /// The same cap, against a rectangle rather than a live screen.
    ///
    /// The view works from `SwitcherAppearance.screenFrame` — the display pinned when the
    /// session began — because asking `NSScreen` again mid-session can answer with a
    /// different display, and the capture was requested at the *pinned* one's cap. Sizing
    /// the drawing and sizing the request from two different rectangles is how a preview
    /// ends up soft or cropped.
    nonisolated static func size(forAspectRatio aspectRatio: CGFloat, in area: CGRect) -> CGSize {
        let maxWidth = min(area.width * 0.5, 900)
        let maxHeight = area.height * 0.55

        var width = maxWidth
        // Floored so a degenerate frame — a zero-height window, which CGWindowList does
        // report — cannot divide the height into infinity.
        var height = width / max(aspectRatio, 0.2)
        if height > maxHeight {
            height = maxHeight
            width = height * max(aspectRatio, 0.2)
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}
