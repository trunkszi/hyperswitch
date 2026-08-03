import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A ScreenCaptureKit window handle, carried across isolation boundaries.
///
/// `SCWindow` is an immutable descriptor handed out by a `SCShareableContent` snapshot;
/// nothing mutates it and it is only ever read. It carries no `Sendable` conformance,
/// so the reason is stated here rather than silently suppressed at each use site.
private nonisolated struct ShareableWindow: @unchecked Sendable {
    let window: SCWindow
}

/// Captures window thumbnails.
///
/// `SCScreenshotManager.captureImage` is the only supported way to do this on macOS 26.
/// `CGWindowListCreateImage` is not merely deprecated but *obsoleted* as of macOS 15, so
/// it will not even compile against this SDK — and it returned nothing for minimised
/// windows anyway, which is precisely the case this feature exists to cover.
///
/// Measured here: a warm capture runs 20–24 ms, a cold first call 55–66 ms, and windows
/// on other Spaces or minimised into the Dock capture successfully and non-blank.
actor ThumbnailEngine {
    static let shared = ThumbnailEngine()

    /// Concurrency saturates quickly — for ten windows, 232 ms serially, 141 ms two at a
    /// time, 133 ms at four, and no further gain beyond that. Going wider only floods
    /// the capture daemon.
    private static let maxConcurrentCaptures = 4

    private var cache: [CGWindowID: Thumbnail] = [:]

    /// The last window listing, and when it was taken.
    ///
    /// `SCShareableContent.excludingDesktopWindows` costs 46–57 ms and every capture path
    /// needs it, so a session that opens the panel and then has the pointer rest on a card
    /// paid for it twice within a few hundred milliseconds — and again on every further
    /// hover, because the full-size preview re-runs from scratch each time. Holding it for a
    /// second collapses a burst of ⌘Tab-with-the-pointer-parked into one listing.
    ///
    /// The staleness this admits is bounded and cheap: a window opened inside the second
    /// is missing from the listing, so its capture is skipped and the tile draws from the
    /// model's previous image until the next session. Nothing reads a *wrong* window from
    /// it — the lookup is by window ID.
    private var shareable: (content: SCShareableContent, taken: Date)?
    private static let shareableLifetime: TimeInterval = 1.0

    private init() {}

    /// The window listing, from cache when it is fresh enough.
    private func shareableContent() async -> SCShareableContent? {
        if let shareable, Date().timeIntervalSince(shareable.taken) < Self.shareableLifetime {
            return shareable.content
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false) else { return nil }
        shareable = (content, Date())
        return content
    }

    // MARK: - Public API

    func cached(_ id: CGWindowID) -> Thumbnail? { cache[id] }

    /// Captures thumbnails for `windows`, four at a time, delivering each through
    /// `onReady` as soon as it lands so tiles fill in progressively rather than the
    /// panel waiting on the slowest one.
    ///
    /// `quality` is a parameter rather than a `Preferences` lookup because reading
    /// `Preferences.shared` from here would mean an `await` back onto the main actor per
    /// batch, on the exact path that has to be ready within the switcher's activation
    /// delay. The caller is already on the main actor when it starts a session, so it
    /// reads the setting once and hands the answer down.
    func capture(_ windows: [WindowInfo],
                 targetWidth: CGFloat,
                 quality: ThumbnailQuality,
                 onReady: @escaping @Sendable (CGWindowID, Thumbnail) -> Void) async {
        guard !Task.isCancelled else { return }

        // One listing for the whole batch. It costs 46–57 ms, so doing it per window —
        // as an earlier version did — added more latency than every capture combined.
        guard let content = await shareableContent() else {
            if !Task.isCancelled {
                Log.thumbnails.error("SCShareableContent failed; is Screen Recording granted?")
            }
            return
        }
        // ScreenCaptureKit does not guarantee that cancelling its await throws. A user
        // can move across several applications during this listing, so re-check before
        // turning an obsolete result into a whole batch of captures.
        guard !Task.isCancelled else { return }

        var handles: [CGWindowID: ShareableWindow] = [:]
        for window in content.windows { handles[window.windowID] = ShareableWindow(window: window) }

        await withTaskGroup(of: Void.self) { group in
            var iterator = windows.makeIterator()
            var active = 0

            // A sliding window: keep exactly `maxConcurrentCaptures` in flight, starting
            // the next capture each time one finishes.
            func startNext() -> Bool {
                guard !Task.isCancelled else { return false }
                guard let window = iterator.next() else { return false }
                guard let handle = handles[window.id] else { return startNext() }
                group.addTask { [weak self] in
                    guard !Task.isCancelled, let self else { return }
                    if let thumbnail = await self.performCapture(window,
                                                                 handle: handle,
                                                                 targetWidth: targetWidth,
                                                                 quality: quality),
                       !Task.isCancelled {
                        onReady(window.id, thumbnail)
                    }
                }
                return true
            }

            while active < Self.maxConcurrentCaptures, startNext() { active += 1 }
            while active > 0 {
                await group.next()
                active -= 1
                if Task.isCancelled {
                    group.cancelAll()
                } else if startNext() {
                    active += 1
                }
            }
        }
    }

    /// A single high-resolution capture for the full-size hover preview.
    ///
    /// Deliberately outside the thumbnail cache in both directions: it does not read the
    /// grid's small image on the way in, which would look soft blown up, and it does not
    /// write this large one on the way out, which would evict the thumbnails the panel
    /// still needs. The cached image appears only as a failure fallback, where a soft
    /// preview beats an empty one.
    ///
    /// The quality setting is not applied here on purpose: it exists to bound the memory
    /// held by a row of twenty previews, and this is one image shown at full size, which
    /// is the one place the pixels are actually looked at.
    func fullSize(_ window: WindowInfo, targetWidth: CGFloat) async -> Thumbnail? {
        guard !Task.isCancelled else { return nil }
        guard let content = await shareableContent(),
              !Task.isCancelled,
              let match = content.windows.first(where: { $0.windowID == window.id })
        else { return cache[window.id] }

        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(targetWidth.rounded()))
        configuration.height = max(2, Int((targetWidth / max(window.aspectRatio, 0.05)).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best

        do {
            let filter = SCContentFilter(desktopIndependentWindow: match)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: configuration)
            guard !Task.isCancelled else { return nil }
            return Thumbnail(image: image, captured: Date(), isLive: window.isOnScreen)
        } catch {
            return cache[window.id]
        }
    }

    /// Drops cached images for windows that no longer exist.
    func prune(keeping live: Set<CGWindowID>) {
        cache = cache.filter { live.contains($0.key) }
    }

    // MARK: - Capture

    private func performCapture(_ window: WindowInfo,
                                handle: ShareableWindow,
                                targetWidth: CGFloat,
                                quality: ThumbnailQuality) async -> Thumbnail? {
        guard !Task.isCancelled else { return nil }
        let configuration = SCStreamConfiguration()

        // The returned image is always exactly the requested width × height. With the
        // default aspect-ratio preservation, a mismatched request is letterboxed with
        // fully transparent pixels — which in a row of tiles reads as a correctly sized
        // tile whose content floats, putting the app icon and title in the wrong place.
        // So the height comes from the window's own aspect ratio rather than a guess.
        //
        // Quality scales the pixel request, not the layout: the tile still occupies
        // `targetWidth` points and SwiftUI resamples into it. The 2 px floor matters
        // because the two multipliers compose — a sliver of a window at Low can otherwise
        // round to zero, and SCScreenshotManager rejects a zero-sized configuration.
        let requested = targetWidth * quality.scale
        let width = max(2, Int(requested.rounded()))
        let height = max(2, Int((requested / max(window.aspectRatio, 0.05)).rounded()))

        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best

        do {
            let filter = SCContentFilter(desktopIndependentWindow: handle.window)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: configuration)
            // Do not retain or publish pixels that belong to a row the user has already
            // left. This is especially important because the capture API may complete
            // normally after its parent task was cancelled.
            guard !Task.isCancelled else { return nil }
            let thumbnail = Thumbnail(image: image, captured: Date(), isLive: window.isOnScreen)
            cache[window.id] = thumbnail
            return thumbnail
        } catch {
            // A window closing mid-capture reports SCStreamErrorInternalError (-3811)
            // with a message about audio/video capture failure. That is a routine race
            // in a switcher that opens on a keystroke, not a fault worth surfacing —
            // fall back to the last image.
            Log.thumbnails.debug("capture failed for \(window.id): \(error.localizedDescription, privacy: .public)")
            return cache[window.id]
        }
    }
}
