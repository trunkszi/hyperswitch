import AppKit
import SwiftUI

/// The window the switcher is drawn in.
///
/// Every flag here is set against a constraint that was hit in practice:
///
///   * `.nonactivatingPanel` plus `orderFrontRegardless()` puts the switcher on screen
///     without making HyperSwitch the frontmost application. That is not cosmetic: the
///     whole session ends by raising a window in *another* application, and the moment
///     this process becomes frontmost the raise lands behind us instead.
///
///   * Level `.popUpMenu` (101), not `.floating`. `.floating` is level 3 and the Dock
///     sits at 20, so a panel at `.floating` is drawn *underneath* the Dock — which for
///     a full-width switcher strip means its bottom edge disappears.
///
///   * `hasShadow = false`. AppKit derives a borderless window's shadow from the rendered
///     alpha and only recomputes it when told to, so it lags every resize and every fade.
///     SwiftUI draws the shadow instead, inside a transparent margin the view reserves.
private final class SwitcherWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
        // Hover drives the full-size preview, so mouse-moved events have to reach the
        // content even though this window will never be key.
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        isMovable = false
        isReleasedWhenClosed = false
        // AppKit's own window fade would run on top of ours and double the duration.
        animationBehavior = .none
    }

    /// The panel must never *take* focus — but it still has to answer the mouse.
    ///
    /// A `.borderless` window reports `canBecomeKey == false` by default, and that stops
    /// mouse events reaching its content entirely: HyperDock's bubble was unclickable
    /// until this override was added. The cards here are clickable and hoverable, so the
    /// same override is needed.
    ///
    /// This is safe, and the distinction is worth stating precisely because the risk it
    /// looks like is real. Focus is only ever *taken* by calling `makeKey()` /
    /// `makeKeyAndOrderFront(_:)`, which this app never does — the panel is only ever put
    /// up with `orderFrontRegardless()`. Combined with `.nonactivatingPanel`, a click lands
    /// on the card without HyperSwitch becoming the active application, so the frontmost
    /// application is unchanged and the raise that commit performs still lands in front.
    /// `canBecomeMain` stays false because main status *would* make us frontmost.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the switcher window and its SwiftUI content, and nothing else.
///
/// Deliberately has no opinion about *when* it appears — the session logic, the delays and
/// the selection all live in ``SwitcherController``. This type only measures, places,
/// shows and hides.
@MainActor
final class SwitcherPanel {
    private let panel = SwitcherWindow()
    private let model: SwitcherModel

    /// `AnyView` because the root carries `localizedFollowingPreference()`, whose modifier
    /// type is private to `Localization.swift` and therefore cannot be named in a stored
    /// property's type.
    private let hosting: NSHostingView<AnyView>

    /// Invalidates a hide animation that a later `show(on:)` has overtaken.
    ///
    /// Without it, tapping the hotkey again during the 0.12 s fade lets the fade's
    /// completion handler run *after* the panel is back on screen and order it straight
    /// back out — the switcher appears and instantly vanishes.
    private var generation = 0

    init(model: SwitcherModel) {
        self.model = model

        let root = AnyView(SwitcherView(model: model).localizedFollowingPreference())
        hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        // The window is transparent and the plate is drawn by SwiftUI; the hosting view
        // must not paint an opaque backing behind the material.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    /// Whether the panel is currently *transparent to clicks*.
    ///
    /// Exposed for the regression test behind the "windows stop working after Mission
    /// Control" report: an ordered-in panel keeps hit-testing however faded it is, so
    /// "not visible to the eye" and "not eating clicks" are different questions.
    var isClickThrough: Bool { panel.ignoresMouseEvents }
    var alpha: Double { panel.alphaValue }

    /// The window ID, for `screencapture -l` and the debug bridge.
    ///
    /// `nil` while hidden: a window number for a window that is not on screen captures a
    /// blank image, and reporting one would make a failed presentation look like a
    /// successful one.
    var windowNumber: Int? { panel.isVisible ? panel.windowNumber : nil }

    /// Measures the content, centres it on `screen` and puts it up.
    ///
    /// Safe to call again while already visible — that is how the panel re-fits itself
    /// after a window is closed out of the row or the full-size preview appears.
    func show(on screen: NSScreen) {
        // The theme has to be applied to the window as well as to SwiftUI.
        // `preferredColorScheme` restyles the SwiftUI content but leaves
        // `.ultraThinMaterial` resolving against the *system* appearance, so a panel forced
        // to Dark on a Light Mac would otherwise get a light blur under dark text.
        panel.appearance = model.appearance.theme.nsAppearance

        // Supersede any hide still in flight, and undo whatever it did to the window.
        generation &+= 1
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false

        // SwiftUI's Observation invalidation has already marked the hosting view dirty by
        // the time a caller gets here, but the layout pass itself is deferred to the next
        // run-loop turn. Forcing it now is what makes `fittingSize` describe the content we
        // are about to show rather than the previous frame's.
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()

        let visible = screen.visibleFrame
        var size = hosting.fittingSize
        size.width = min(max(size.width, 120), visible.width)
        size.height = min(max(size.height, 80), visible.height)

        var origin = CGPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        origin.x = max(origin.x, visible.minX)
        origin.y = max(origin.y, visible.minY)

        panel.setFrame(CGRect(origin: origin, size: size).integral, display: panel.isVisible)
        // Never `makeKeyAndOrderFront`: see `SwitcherWindow.canBecomeKey`.
        panel.orderFrontRegardless()
    }

    /// Takes the panel off screen using the user's chosen exit animation.
    func hide(animation: HideAnimation) {
        guard panel.isVisible else { return }

        generation &+= 1
        let token = generation

        // Stops swallowing clicks *now*, before the fade rather than after it.
        //
        // Reported from real use: after a three-finger swipe up, "the windows stop
        // working". A `.popUpMenu`-level panel that is ordered in still hit-tests even at
        // zero opacity, so for as long as it lingers it is an invisible rectangle in the
        // middle of the screen that eats every click. The fade is only 120 ms, but the
        // completion handler that finally orders the panel out can be delayed or dropped
        // outright while Mission Control owns the compositor — and then the rectangle is
        // there for good, with nothing on screen to explain it.
        panel.ignoresMouseEvents = true

        // Reduce Motion turns both animated exits into an immediate one. Fading is mild
        // enough to keep, but the scale is unambiguously motion, and mixing the two rules
        // would leave the panel shrinking for someone who asked it not to.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animation != .none, !reduceMotion else {
            finish(token)
            return
        }

        let shrunk: CGRect? = animation == .scaleDown ? Self.scaled(panel.frame, by: 0.92) : nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if let shrunk { panel.animator().setFrame(shrunk, display: true) }
        } completionHandler: { [weak self] in
            // `NSAnimationContext` delivers this on the main thread, but its parameter is a
            // plain escaping closure so the compiler cannot know that.
            MainActor.assumeIsolated { self?.finish(token) }
        }

        // The completion handler above is the fast path, not the guarantee. This timer is
        // what makes "the panel is gone" true even when Core Animation never calls back —
        // `finish` is idempotent for a given token, so whichever arrives first wins.
        // `.common`, not `Timer.scheduledTimer`'s implicit `.default`. This is the third
        // place in the project to need it and the reason is the same each time: a timer
        // left in `.default` stops while the run loop is tracking a menu or running a
        // modal, and hiding the panel is something that happens *during* both — pick the
        // switcher's own status-bar menu, or an alert raised by the window it just
        // committed to. A safety net that pauses exactly when the user has a menu open is
        // not a safety net.
        let fallback = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(token) }
        }
        RunLoop.main.add(fallback, forMode: .common)
    }

    private func finish(_ token: Int) {
        // A `show(on:)` that landed during the fade already bumped the generation and
        // reset the alpha; ordering out now would hide the panel it just put up.
        guard token == generation else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// Shrinks a rect about its own centre, so the panel collapses inwards instead of
    /// sliding towards the screen's bottom-left corner.
    private static func scaled(_ frame: CGRect, by factor: CGFloat) -> CGRect {
        let size = CGSize(width: frame.width * factor, height: frame.height * factor)
        return CGRect(x: frame.midX - size.width / 2,
                      y: frame.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }
}
