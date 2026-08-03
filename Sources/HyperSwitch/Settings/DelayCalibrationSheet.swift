import SwiftUI

/// Ten-sample wizard driven by the same event tap as the real switcher hotkey.
struct DelayCalibrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = SwitcherDelayCalibrationSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Calibrate activation delay")
                .font(.title2.weight(.semibold))

            Text("Press and release your All Windows shortcut at a comfortable quick-switch pace. HyperSwitch records only the timing and will not open the switcher during these samples.")
                .foregroundStyle(.secondary)

            ProgressView(value: session.calibration.progress) {
                Text("Samples: \(session.calibration.samples.count) of \(session.calibration.requiredSamples)")
                    .monospacedDigit()
            }

            GroupBox {
                HStack {
                    Label(session.isListening ? "Waiting for shortcut" : "Sampling complete",
                          systemImage: session.isListening ? "keyboard.fill" : "checkmark.circle.fill")
                    Spacer()
                    if let recommendation = session.calibration.recommendedMilliseconds {
                        Text("Recommended: \(recommendation) ms")
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(4)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    session.cancel()
                    dismiss()
                }
                Spacer()
                Button("Start over") { session.begin() }
                Button("Apply recommendation") {
                    session.apply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.calibration.isComplete)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(session.isMeasuring)
        .onAppear { session.begin() }
        .onDisappear { session.cancel() }
        .accessibilityElement(children: .contain)
    }
}
