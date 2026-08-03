import Foundation
import Observation

/// The deterministic part of the calibration wizard.
nonisolated struct DelayCalibration: Sendable, Equatable {
    let requiredSamples: Int
    private(set) var samples: [Int] = []

    init(requiredSamples: Int = 10) {
        self.requiredSamples = max(1, requiredSamples)
    }

    var isComplete: Bool { samples.count >= requiredSamples }
    var progress: Double { min(1, Double(samples.count) / Double(requiredSamples)) }

    var recommendedMilliseconds: Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = max(0, Int(ceil(Double(sorted.count) * 0.8)) - 1)
        let percentile = sorted[rank]
        let rounded = Int((Double(percentile) / 10).rounded()) * 10
        return min(max(rounded, 40), 500)
    }

    mutating func record(milliseconds: Int) {
        guard !isComplete else { return }
        samples.append(max(0, milliseconds))
    }
}

/// Shared bridge between the settings sheet and the keyboard event tap.
@MainActor
@Observable
final class SwitcherDelayCalibrationSession {
    static let shared = SwitcherDelayCalibrationSession()

    private(set) var calibration = DelayCalibration()
    private(set) var isListening = false
    private var triggerTimestamp: UInt64?

    var isMeasuring: Bool { triggerTimestamp != nil }

    private init() {}

    func begin() {
        calibration = DelayCalibration()
        triggerTimestamp = nil
        isListening = true
        publish()
    }

    func cancel() {
        isListening = false
        triggerTimestamp = nil
        publish()
    }

    func registerTrigger(timestamp: UInt64) {
        guard isListening, !calibration.isComplete else { return }
        triggerTimestamp = timestamp
        publish()
    }

    func registerRelease(timestamp: UInt64) {
        guard isListening, let started = triggerTimestamp, timestamp >= started else { return }
        triggerTimestamp = nil
        let milliseconds = Int((timestamp - started) / 1_000_000)
        calibration.record(milliseconds: milliseconds)
        if calibration.isComplete { isListening = false }
        publish()
    }

    /// Mirrors both flags into the snapshot the event tap decides from.
    ///
    /// Called from every mutation rather than from the two obvious ones: the tap has to know
    /// it is in calibration mode *before* the next keystroke arrives, and `isMeasuring`
    /// changes on `registerTrigger` — which is itself driven by the tap. A missed publish
    /// here does not merely lose a measurement, it leaves the tap swallowing ⌥Tab into a
    /// calibration session the sheet has already closed.
    private func publish() {
        HotKeyState.shared.publish(
            calibration: (isCalibrating: isListening, isMeasuring: isMeasuring)
        )
    }

    func apply() {
        guard let recommended = calibration.recommendedMilliseconds else { return }
        let preferences = Preferences.shared
        preferences.windowSwitcherDelay = recommended
        preferences.appSwitcherDelayFirst = recommended
        preferences.appSwitcherDelaySubsequent = max(40, Int((Double(recommended) * 0.6).rounded()))
        cancel()
    }
}
