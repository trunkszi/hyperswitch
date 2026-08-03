import CoreGraphics
import Foundation

nonisolated enum SwitcherEscapeAction: Equatable, Sendable {
    case clearedSearch
    case cancelSession
}

/// Session-only interaction state, independent from window enumeration and rendering.
nonisolated struct SwitcherInteractionState: Sendable, Equatable {
    private(set) var isLatched = false
    private(set) var isSearching = false
    private(set) var query = ""
    private(set) var showsUsageHints = false
    private var presentedAt: TimeInterval?

    mutating func reset() {
        isLatched = false
        isSearching = false
        query = ""
        showsUsageHints = false
        presentedAt = nil
    }

    mutating func markPresented(at time: TimeInterval) {
        presentedAt = time
        showsUsageHints = false
    }

    mutating func refreshHints(at time: TimeInterval, enabled: Bool) {
        guard enabled, let presentedAt else {
            showsUsageHints = false
            return
        }
        showsUsageHints = time - presentedAt >= 0.5
    }

    @discardableResult
    mutating func toggleLatch(allowed: Bool) -> Bool {
        guard allowed else { return false }
        isLatched.toggle()
        if !isLatched {
            isSearching = false
            query = ""
        }
        return isLatched
    }

    @discardableResult
    mutating func beginSearch(candidateCount: Int, threshold: Int, explicit: Bool = false) -> Bool {
        guard isLatched,
              explicit || candidateCount >= max(1, threshold)
        else { return false }
        isSearching = true
        return true
    }

    @discardableResult
    mutating func appendSearchText(_ text: String,
                                   candidateCount: Int,
                                   threshold: Int) -> Bool {
        guard !text.isEmpty, isLatched else { return false }
        if !isSearching,
           !beginSearch(candidateCount: candidateCount, threshold: threshold) {
            return false
        }

        let printableScalars = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        guard !printableScalars.isEmpty else { return false }
        let addition = String(String.UnicodeScalarView(printableScalars))
        query = String((query + addition).prefix(80))
        return true
    }

    mutating func deleteSearchCharacter() {
        guard isSearching, !query.isEmpty else { return }
        query.removeLast()
        if query.isEmpty { isSearching = false }
    }

    mutating func escape() -> SwitcherEscapeAction {
        if isSearching, !query.isEmpty {
            query = ""
            isSearching = false
            return .clearedSearch
        }
        isSearching = false
        return .cancelSession
    }
}

/// In-memory filtering for the current switcher session.
nonisolated enum SwitcherSearch {
    static func filter(_ windows: [WindowInfo], query: String) -> [WindowInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return windows }
        let options: String.CompareOptions = [
            .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
        ]
        return windows.filter { window in
            window.title.range(of: needle, options: options, locale: .current) != nil
                || window.applicationName.range(of: needle, options: options, locale: .current) != nil
        }
    }
}

/// A bounded window into a larger result list that keeps the selection near the centre.
nonisolated enum CenteredSlice {
    static func range(count: Int, selected: Int, capacity: Int) -> Range<Int> {
        guard count > 0, capacity > 0 else { return 0..<0 }
        let visibleCount = min(count, capacity)
        let safeSelection = min(max(selected, 0), count - 1)
        let idealStart = safeSelection - visibleCount / 2
        let start = min(max(idealStart, 0), count - visibleCount)
        return start..<(start + visibleCount)
    }
}

nonisolated struct WindowGroupKey: Hashable, Sendable {
    let applicationName: String
    let spaceNumber: Int?
}

nonisolated struct WindowGroup: Sendable, Equatable, Identifiable {
    let key: WindowGroupKey?
    var windows: [WindowInfo]

    /// Identity for `ForEach`, taken from the first window rather than from ``key``.
    ///
    /// The key is not unique: grouping is *consecutive*, so a row of A, B, A produces three
    /// groups and two of them carry the same key. Window IDs are unique across the whole
    /// row — each window lands in exactly one group — so the first one names its group
    /// unambiguously.
    ///
    /// This exists so callers can iterate the groups themselves. Iterating `indices` and
    /// subscripting back into the collection is what crashed the app: `ForEach` re-runs its
    /// child closure after the row has been rebuilt, and by then the array the index came
    /// from can be shorter. See ``SwitcherView/windowRow``.
    var id: CGWindowID { windows.first?.id ?? 0 }
}

/// Consecutive grouping preserves the switcher's recency order exactly.
nonisolated enum WindowGrouping {
    static func groups(_ windows: [WindowInfo], threshold: Int) -> [WindowGroup] {
        guard !windows.isEmpty else { return [] }
        guard windows.count >= max(1, threshold) else {
            return [WindowGroup(key: nil, windows: windows)]
        }

        var result: [WindowGroup] = []
        for window in windows {
            let key = WindowGroupKey(
                applicationName: window.applicationName,
                spaceNumber: window.spaceNumber
            )
            if result.last?.key == key {
                result[result.count - 1].windows.append(window)
            } else {
                result.append(WindowGroup(key: key, windows: [window]))
            }
        }
        return result
    }
}

nonisolated enum HoverIntentDecision: Equatable, Sendable {
    case waiting
    case ready
    case abandoned
}

/// Decides whether a pointer has settled enough to justify an expensive large capture.
nonisolated struct HoverIntentTracker: Sendable {
    private let stableRadius: CGFloat
    private let dwell: TimeInterval
    private let timeout: TimeInterval

    private var candidate: CGWindowID?
    private var sessionStarted: TimeInterval?
    private var anchorPoint: CGPoint?
    private var anchorTime: TimeInterval?

    init(stableRadius: CGFloat, dwell: TimeInterval, timeout: TimeInterval) {
        self.stableRadius = max(0, stableRadius)
        self.dwell = max(0, dwell)
        self.timeout = max(0, timeout)
    }

    mutating func update(candidate newCandidate: CGWindowID,
                         point: CGPoint,
                         time: TimeInterval) -> HoverIntentDecision {
        if candidate != newCandidate {
            candidate = newCandidate
            sessionStarted = time
            anchorPoint = point
            anchorTime = time
            return dwell == 0 ? .ready : .waiting
        }

        guard let sessionStarted, let anchorPoint, let anchorTime else {
            self.sessionStarted = time
            self.anchorPoint = point
            self.anchorTime = time
            return .waiting
        }
        if time - sessionStarted > timeout { return .abandoned }

        if hypot(point.x - anchorPoint.x, point.y - anchorPoint.y) > stableRadius {
            self.anchorPoint = point
            self.anchorTime = time
            return .waiting
        }
        return time - anchorTime >= dwell ? .ready : .waiting
    }

    mutating func reset() {
        candidate = nil
        sessionStarted = nil
        anchorPoint = nil
        anchorTime = nil
    }
}

/// Whether a pointer reading means the person moved the mouse, or means the panel moved
/// underneath a mouse that stayed put.
///
/// The distinction is what stops the keyboard and the full-size preview driving each other
/// in a loop; see ``SwitcherModel/ignoresPointer``. Split out as a free function purely so
/// the rule can be tested without a screen — everything around it reads
/// `NSEvent.mouseLocation`, which needs a window server.
nonisolated enum PointerSuppression {
    static func shouldRelease(anchor: CGPoint,
                              current: CGPoint,
                              beyond distance: CGFloat) -> Bool {
        hypot(current.x - anchor.x, current.y - anchor.y) > distance
    }
}

/// Two-step destructive confirmation scoped to one running application.
nonisolated struct QuitConfirmationState: Sendable {
    private let window: TimeInterval
    private(set) var targetPID: pid_t?
    private var deadline: TimeInterval?

    init(window: TimeInterval = 0.9) {
        self.window = max(0, window)
    }

    mutating func request(targetPID: pid_t, time: TimeInterval) -> Bool {
        if self.targetPID == targetPID, let deadline, time <= deadline {
            reset()
            return true
        }
        self.targetPID = targetPID
        deadline = time + window
        return false
    }

    func isArmed(for targetPID: pid_t, time: TimeInterval) -> Bool {
        self.targetPID == targetPID && (deadline.map { time <= $0 } ?? false)
    }

    mutating func reset() {
        targetPID = nil
        deadline = nil
    }
}
