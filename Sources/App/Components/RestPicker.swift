import SwiftUI

/// Rest for a single set, as a directly editable value.
///
/// The chip is styled like the reps and weight fields beside it because it is
/// the same kind of thing: a quantity belonging to *this* set, not a property
/// of the exercise. Rest was previously written once per exercise and rendered
/// as static annotation text, which made "three minutes before the heavy
/// single, ninety seconds on the back-offs" unsayable.
///
/// Tapping opens fine adjustment rather than a fixed menu. The old control
/// offered nine preset durations and nothing between them; ±15/±30 from
/// wherever you are is what "tune this" actually means, and the presets are
/// still there for the large jumps.
struct RestPicker: View {
    /// Seconds in effect right now, from wherever they came.
    let seconds: Int
    /// True when `seconds` is this set's own value rather than something it
    /// inherited — drives whether the chip reads as set or as a default.
    let isExplicit: Bool
    /// Label for reverting to the inherited value. `nil` offers no revert,
    /// for the case where there's nothing to revert to.
    var resetLabel: String?
    /// Uppercase caption before the chip.
    var label: String? = "REST"
    let onChange: (Int?) -> Void

    @State private var isPresented = false

    /// Half an hour. Long past anything real, but a bound stops a stuck +30 from
    /// producing an hours-long timer.
    private static let maximum = 1800

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 5) {
                if let label {
                    Text(label)
                        .font(Theme.label)
                        .tracking(1.2)
                        .foregroundStyle(Theme.inkMuted)
                }
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isExplicit ? Theme.ink : Theme.inkFaint)
                    Text(seconds.restClockDescription)
                        .font(Theme.data(13, weight: .medium))
                        .foregroundStyle(isExplicit ? Theme.ink : Theme.inkFaint)
                    FieldCaret(color: isExplicit ? Theme.inkMuted : Theme.inkFaint)
                }
                // Outlined like the reps and weight fields because it is the
                // same kind of thing. Drawn as a bare filled rectangle it read
                // as annotation — a number the app was telling you, not one you
                // could tell the app.
                .editableField(isActive: isExplicit, accent: Theme.fieldEdge)
            }
            .fixedSize()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            RestAdjuster(
                title: "rest",
                seconds: seconds,
                resetLabel: resetLabel,
                onChange: onChange,
                onDismiss: { isPresented = false }
            )
            // iPhone presents a popover as a full sheet without this, which is
            // a whole screen for six buttons.
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - The adjuster

/// The rest editor itself: a big readout, fine steppers, and the jumps.
///
/// Shared by the per-set `RestPicker` and by the running rest timer, which
/// opens the same control to retune what's on the clock. Rest is one idea in
/// this app and gets one editor — two different controls for "how long am I
/// resting" would be two places to disagree.
struct RestAdjuster: View {
    /// What this instance is editing — "rest" for a set, "rest remaining" for a
    /// countdown already running.
    var title: String = "rest"
    let seconds: Int
    var resetLabel: String?
    let onChange: (Int?) -> Void
    let onDismiss: () -> Void

    private static let presets = [60, 90, 120, 150, 180, 240, 300]
    private static let maximum = 1800

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: title)

            HStack(spacing: 6) {
                Text(seconds.restClockDescription)
                    .font(Theme.data(26, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    // The clock is the one thing here that must never wrap:
                    // "2:00" broken across two lines reads as two numbers.
                    .fixedSize()
                Spacer(minLength: 6)
                stepButton("−30", by: -30)
                stepButton("−15", by: -15)
                stepButton("+15", by: 15)
                stepButton("+30", by: 30)
            }

            // The jumps the steppers would take a dozen taps to reach.
            HStack(spacing: 4) {
                ForEach(Self.presets, id: \.self) { preset in
                    presetButton(preset)
                }
            }

            if let resetLabel {
                Button(resetLabel) {
                    onChange(nil)
                    onDismiss()
                }
                .font(Theme.label)
                .tracking(1.2)
                .foregroundStyle(Theme.signal)
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(Theme.panel)
    }

    private func stepButton(_ title: String, by delta: Int) -> some View {
        // Steps from whatever's showing, not from the prescription — the point
        // of a stepper is that repeated taps compound.
        let next = min(Self.maximum, max(0, seconds + delta))
        return Button { onChange(next) } label: {
            Text(title)
                .font(Theme.data(12, weight: .medium))
                .foregroundStyle(next == seconds ? Theme.inkFaint : Theme.ink)
                .frame(width: 40, height: 32)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(next == seconds)
    }

    private func presetButton(_ preset: Int) -> some View {
        let selected = preset == seconds
        return Button {
            onChange(preset)
            onDismiss()
        } label: {
            Text(preset.restClockDescription)
                .font(Theme.data(11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.void : Theme.inkMuted)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(selected ? Theme.signal : Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

extension Int {
    /// Seconds as `M:SS`, the one format rest is written in across the app.
    var restClockDescription: String {
        String(format: "%d:%02d", self / 60, self % 60)
    }
}

#Preview {
    VStack(spacing: 20) {
        RestPicker(seconds: 180, isExplicit: true, resetLabel: "use prescribed 2:00", onChange: { _ in })
        RestPicker(seconds: 120, isExplicit: false, onChange: { _ in })
    }
    .padding()
    .background(Theme.void)
}
