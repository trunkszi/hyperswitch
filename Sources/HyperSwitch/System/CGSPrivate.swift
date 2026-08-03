import CoreGraphics
import Foundation

/// Dynamic bindings to the private CoreGraphics / SkyLight "CGS" window-server SPI.
///
/// There is no public API that answers "which Space is this window on?", and the
/// switcher needs it twice over: to badge off-Space windows, and to honour the
/// "include windows from other spaces" setting at all. The real implementations live in
/// SkyLight.framework as `SLS*`; CoreGraphics re-exports them as `CGS*` (verified with
/// `dyld_info -exports` on CoreGraphics, which prints
/// `[re-export] _CGSCopySpacesForWindows (_SLSCopySpacesForWindows from SkyLight)`).
///
/// Everything resolves through `dlsym` rather than a link-time reference, so a future
/// macOS renaming a symbol degrades Space badges instead of preventing launch. Every
/// entry point returns an empty result on failure and every caller must tolerate it.
///
/// **The query direction matters.** This asks *"which windows are on this Space?"*, not
/// *"which Space is this window on?"*. Both SPIs exist, but the per-window one
/// (`CGSCopySpacesForWindows`) returns the de-duplicated **union** over every window
/// passed in rather than a parallel array, so it has to be called once per window or it
/// silently produces wrong answers. Building the reverse index from a handful of Spaces
/// is one call per Space and cannot be got wrong that way.
///
/// `nonisolated` because the project builds with `-default-isolation=MainActor` and this
/// is called from the window-index actor, off the main thread.
nonisolated enum CGS {

    // MARK: - Symbol resolution

    private typealias ConnectionID = Int32

    /// `RTLD_DEFAULT` — search every image already loaded in the process.
    /// `nonisolated(unsafe)` is required: under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// a plain `static let` of a raw pointer is a hard "not concurrency-safe" error.
    private nonisolated(unsafe) static let handle = UnsafeMutableRawPointer(bitPattern: -2)

    /// `@convention(c)` function pointers are already Sendable and must NOT be marked
    /// `nonisolated(unsafe)` — doing so produces a warning.
    private static func resolve<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let _mainConnectionID =
        resolve("CGSMainConnectionID", as: (@convention(c) () -> ConnectionID).self)

    private static let _copyManagedDisplaySpaces =
        resolve("CGSCopyManagedDisplaySpaces",
                as: (@convention(c) (ConnectionID) -> Unmanaged<CFArray>?).self)

    private static let _copyWindowsWithOptionsAndTags =
        resolve("CGSCopyWindowsWithOptionsAndTags",
                as: (@convention(c) (ConnectionID, UInt32, CFArray, UInt32,
                                     UnsafeMutablePointer<UInt64>,
                                     UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?).self)

    /// Turns a display UUID string — the only display identity
    /// `CGSCopyManagedDisplaySpaces` hands out — back into a `CGDirectDisplayID`.
    ///
    /// Public API, but declared in ColorSync rather than CoreGraphics, so Swift cannot see
    /// it without linking a framework this project has no other use for. Resolving it the
    /// same way as everything else here costs one `dlsym` and keeps the link line as it is;
    /// ColorSync is already loaded in the process by CoreGraphics itself (verified: the
    /// symbol resolves through `RTLD_DEFAULT` in a process that imports only CoreGraphics).
    private static let _displayIDFromUUID =
        resolve("CGDisplayGetDisplayIDFromUUID", as: (@convention(c) (CFUUID) -> UInt32).self)

    private static let _copySpacesForWindows =
        resolve("CGSCopySpacesForWindows",
                as: (@convention(c) (ConnectionID, UInt32, CFArray) -> Unmanaged<CFArray>?).self)

    /// `kCGSSpaceAll` — include every kind of Space in the answer.
    private static let selectorAllSpaces: UInt32 = 7

    private static var connectionID: ConnectionID? { _mainConnectionID?() }

    // MARK: - Window → Space

    /// The Spaces a single window belongs to.
    ///
    /// Call this **once per window**. `CGSCopySpacesForWindows` returns the de-duplicated
    /// UNION over every window passed in rather than a parallel array, so batching silently
    /// produces wrong answers — the same trap documented at the top of this file, from the
    /// other direction.
    nonisolated static func spaces(forWindow window: CGWindowID) -> [UInt64] {
        guard let cid = connectionID, let copy = _copySpacesForWindows else { return [] }
        let ids = [NSNumber(value: window)] as CFArray
        guard let result = copy(cid, selectorAllSpaces, ids)?.takeRetainedValue() as? [NSNumber]
        else { return [] }
        return result.map(\.uint64Value)
    }

    /// Every Space currently showing, one per display.
    nonisolated static func currentSpaces() -> Set<UInt64> {
        var out: Set<UInt64> = []
        for display in managedDisplaySpaces() {
            if let current = display.spaces.first(where: \.isCurrent) { out.insert(current.id) }
        }
        return out
    }

    /// The Space a window lives on, or `nil` when it is already on one the user is looking
    /// at — which is the same as "no switch is needed".
    ///
    /// Answered from live window-server state rather than from the switcher's snapshot: the
    /// current Space can change between the panel opening and the modifier being released,
    /// and acting on a stale reading switches *away* from the target.
    nonisolated static func spaceToReach(window: CGWindowID) -> UInt64? {
        let home = spaces(forWindow: window)
        guard !home.isEmpty else { return nil }
        let visible = currentSpaces()
        guard !home.contains(where: { visible.contains($0) }) else { return nil }
        return home.first
    }

    nonisolated static func isCurrent(space: UInt64) -> Bool {
        currentSpaces().contains(space)
    }

    /// The desktop number the "Switch to Desktop N" hotkeys count in.
    ///
    /// Taken from ``SpaceInfo/number``, which is already the continuous-across-displays
    /// count those hotkeys use; deriving it a second way here is how the two would drift.
    nonisolated static func desktopNumber(of space: UInt64) -> Int? {
        for display in managedDisplaySpaces() {
            for entry in display.spaces where entry.id == space {
                return entry.type == 0 ? entry.number : nil
            }
        }
        return nil
    }

    /// Ordinary on-screen windows an application owns, for deciding whether it already has
    /// a presence on a Space the user is looking at.
    nonisolated static func applicationWindows(pid: pid_t) -> [(id: CGWindowID, frame: CGRect)] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            return (id, CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0))
        }
    }

    // MARK: - Space topology

    /// One Space, as Mission Control presents it.
    nonisolated struct SpaceInfo: Sendable {
        /// The window server's `ManagedSpaceID`. Not user-visible and not ordered.
        let id: UInt64
        /// The number the desktop badge shows: 1-based, counting only ordinary desktops,
        /// and **continuous across displays** — see ``managedDisplaySpaces()`` for why it
        /// does not restart per display. 0 for a full-screen Space, which has no number.
        let number: Int
        /// 0 = ordinary desktop, 4 = a full-screen application's Space.
        let type: Int
        let isCurrent: Bool
    }

    nonisolated struct DisplaySpaces: Sendable {
        let spaces: [SpaceInfo]
    }

    /// Snapshot of every display's Space list, displays ordered left to right.
    ///
    /// Within a display the `Spaces` array order **is** the Mission Control left-to-right
    /// order and is deliberately not sorted by id — observed on this machine: 3, 5, 4, 6,
    /// 7, 8, 9, 10, 12. Never derive the user-visible desktop number by sorting ids.
    ///
    /// Across displays there is no such guarantee: the array comes back in whatever order
    /// the window server keeps displays in, which moves when one is attached, detached or
    /// made primary. Desktop numbers run continuously across displays, so an unstable
    /// display order would renumber desktops behind the user's back; sorting by each
    /// display's x origin pins it to something they can see.
    nonisolated static func managedDisplaySpaces() -> [DisplaySpaces] {
        guard let cid = connectionID,
              let raw = _copyManagedDisplaySpaces?(cid)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }

        // Ordering runs after the `connectionID` guard above and must never be moved
        // before it: `CGDisplayGetDisplayIDFromUUID` is SkyLight's `SLSGetDisplayForUUID`,
        // which runs `CGS_REQUIRE_INIT` and **aborts the process** if CoreGraphics has not
        // been initialised — reproduced in a scratch binary where it was the first CG call
        // made. Reading the connection id first is what guarantees it has been.
        let origins = activeDisplayOrigins()
        let ordered = raw.enumerated().sorted { lhs, rhs in
            switch (originX(of: lhs.element, in: origins), originX(of: rhs.element, in: origins)) {
            case let (left?, right?) where left != right: return left < right
            case (nil, _?): return false                 // a display we could not place
            case (_?, nil): return true                  // goes last, never first
            default: return lhs.offset < rhs.offset      // ties keep the SPI's own order
            }
        }.map(\.element)

        // One continuous run across every display. Restarting at 1 per display gave two
        // different Spaces the same badge on a multi-display setup, and that badge is the
        // only thing telling the user which desktop a window is on.
        var desktopNumber = 0
        return ordered.compactMap { display in
            let currentID = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            guard let rawSpaces = display["Spaces"] as? [[String: Any]], !rawSpaces.isEmpty else {
                return nil
            }

            let spaces: [SpaceInfo] = rawSpaces.compactMap { space in
                guard let id = space["ManagedSpaceID"] as? Int else { return nil }
                let type = space["type"] as? Int ?? 0
                // A full-screen Space occupies a slot but is not a numbered desktop, so
                // it must not advance the counter or every later Space is badged one too
                // high.
                if type == 0 { desktopNumber += 1 }
                return SpaceInfo(id: UInt64(id),
                                 number: type == 0 ? desktopNumber : 0,
                                 type: type,
                                 isCurrent: id == currentID)
            }
            return DisplaySpaces(spaces: spaces)
        }
    }

    /// Where each attached display starts, horizontally.
    private static func activeDisplayOrigins() -> [CGDirectDisplayID: CGFloat] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [:] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [:] }

        var origins: [CGDirectDisplayID: CGFloat] = [:]
        for id in ids.prefix(Int(count)) { origins[id] = CGDisplayBounds(id).origin.x }
        return origins
    }

    /// The x origin of the display a `Spaces` dictionary describes, or `nil` when it
    /// cannot be tied to an attached display.
    ///
    /// The result is looked up in the *active display list* rather than read straight out
    /// of `CGDisplayBounds`, because nothing on the way there reports failure. Measured:
    /// `CFUUIDCreateFromString` turns any malformed string into the all-zero UUID instead
    /// of returning nil, that UUID resolves to display id 2, and `CGDisplayBounds(2)`
    /// answers with a plausible 1×1 rectangle at the origin — so an unrecognised display
    /// would sort leftmost and renumber every real desktop. Only ids the system lists as
    /// active are accepted.
    private static func originX(of display: [String: Any],
                                in origins: [CGDirectDisplayID: CGFloat]) -> CGFloat? {
        guard let toDisplayID = _displayIDFromUUID,
              let identifier = display["Display Identifier"] as? String,
              let uuid = CFUUIDCreateFromString(nil, identifier as CFString)
        else { return nil }
        return origins[toDisplayID(uuid)]
    }

    // MARK: - Space → windows

    /// Every window currently living on the given Space, newest first.
    ///
    /// This is the direction that sees windows on Spaces the user is not looking at,
    /// which Accessibility cannot: `kAXWindowsAttribute` is filtered to the current Space
    /// and returns an empty array for an application whose windows all live elsewhere.
    nonisolated static func windows(onSpace space: UInt64) -> [CGWindowID] {
        guard let cid = connectionID, let copy = _copyWindowsWithOptionsAndTags else { return [] }

        // setTags/clearTags are in/out pointers acting as AND-filters. They must be real
        // zeroed variables — passing NULL is not allowed, and passing set=1 with clear=1
        // returns zero windows.
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let spaceList = [NSNumber(value: space)] as CFArray

        // Second parameter is a CGSConnectionID, not a pid. 0 means "any owner", which is
        // what we want; passing a pid there returns a plausible-looking but entirely wrong
        // window list.
        //
        // The 0x7 selector was measured, not copied from folklore: on macOS 26.5.2 the
        // selectors 0x1, 0x2, 0x3 and 0x4 used alone ALL return an empty array. The 0x4
        // "user space" bit is mandatory and must be OR'd into whatever else is asked for.
        guard let result = copy(cid, 0, spaceList, 0x7, &setTags, &clearTags)?
            .takeRetainedValue() as? [NSNumber] else { return [] }

        return result.map { CGWindowID($0.uint32Value) }
    }
}
