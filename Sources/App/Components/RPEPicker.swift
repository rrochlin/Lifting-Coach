import SwiftUI

/// The app's RPE control: a compact value chip that opens the scale itself.
///
/// It replaced a `Menu` over all nineteen values from 1 to 10. That menu was
/// technically complete and horrible to use — a scrolling list of bare numbers,
/// where the four or five values a lifter ever picks were somewhere in the
/// middle, and nothing on screen said what any of them meant.
///
/// What's here instead is the scale as a scale: one row per whole number, the
/// half-step beside it, and each row named in the words the lifter actually
/// uses. That naming is the load-bearing part. **RPE here is exertion, never
/// reps in reserve** (Core Tenets §3) — a control that spells out "8 —
/// exertion" can't be misread as "8 = two reps left" the way a bare number
/// list invites.
///
/// 6–10 is the working range and gets the whole popover. 1–5.5 is real but
/// vanishingly rare in a lifting log, so it lives one tap behind a disclosure
/// rather than taking up half the control.
struct RPEPicker: View {
    /// The value set here. `nil` means nothing is set at this level.
    let value: Float?
    /// Shown greyed when `value` is nil — an inherited exercise-level target,
    /// so a set row reads as "7, from the exercise" rather than as blank.
    var placeholder: String?
    /// Glued to the value in the same font ("@7"), so a number next to a load
    /// can't be read as part of it.
    var prefix: String?
    /// Small uppercase caption before the chip, where the column position
    /// doesn't already say what the number is.
    var label: String?
    /// What clearing the value is called here — "none" on an exercise,
    /// "inherit (7)" on a set that would fall back to one.
    var clearLabel: String = "none"
    let onChange: (Float?) -> Void

    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 4) {
                if let label {
                    Text(label)
                        .font(Theme.label)
                        .tracking(1.2)
                        .foregroundStyle(Theme.inkMuted)
                }
                HStack(spacing: 5) {
                    Text(displayValue)
                        .font(Theme.data(13, weight: .medium))
                        .foregroundStyle(value == nil ? Theme.inkFaint : Theme.signal)
                    FieldCaret(color: value == nil ? Theme.inkFaint : Theme.signal.opacity(0.75))
                }
                // Outlined and caretted rather than drawn as a quiet filled
                // rectangle: an RPE chip that looked like the annotation text
                // beside it gave a lifter no reason to believe it was tappable.
                .editableField(isActive: value != nil, accent: Theme.signal.opacity(0.5))
            }
            .fixedSize()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            RPEScale(
                value: value,
                clearLabel: clearLabel,
                onPick: { picked in
                    onChange(picked)
                    isPresented = false
                }
            )
            // Without this iOS presents a popover as a full sheet on iPhone,
            // which for a nine-button scale is a whole screen of nothing.
            .presentationCompactAdaptation(.popover)
        }
    }

    /// An unset RPE reads "RPE", not "—".
    ///
    /// A dash says "there's nothing here"; the field's own name says "there's
    /// nothing here *yet*, and here's what it wants." Costs nothing in width at
    /// 375pt, and it's how Strong and Hevy label an empty field.
    private var displayValue: String {
        if let value { return (prefix ?? "") + value.rpeDescription }
        if let placeholder { return (prefix ?? "") + placeholder }
        return label == nil ? "RPE" : "—"
    }
}

// MARK: - The scale

private struct RPEScale: View {
    let value: Float?
    let clearLabel: String
    let onPick: (Float?) -> Void

    @State private var showsLowRange = false

    /// The lifter's own anchors. These are exertion descriptions — how hard the
    /// set was — and deliberately not rep counts.
    private static let anchors: [(value: Float, word: String)] = [
        (10, "failure"),
        (9, "all-out effort"),
        (8, "exertion"),
        (7, "some effort"),
        (6, "easy"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 4) {
                ForEach(Self.anchors, id: \.value) { anchor in
                    anchorRow(anchor)
                }
            }

            if showsLowRange {
                lowRange
            }

            footer
        }
        .padding(14)
        .frame(width: 264)
        .background(Theme.panel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: "effort · rpe", accent: Theme.signal)
            // Says the thing the scale means, at the one moment the lifter is
            // looking straight at it.
            Text("How hard the set was — not reps left.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkFaint)
        }
    }

    private func anchorRow(_ anchor: (value: Float, word: String)) -> some View {
        HStack(spacing: 6) {
            Text(anchor.word)
                .font(Theme.caption)
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            valueButton(anchor.value, isPrimary: true)
            // 10.5 isn't on the scale; the slot stays to keep the whole
            // numbers in one column instead of letting the last row shift.
            if anchor.value < 10 {
                valueButton(anchor.value + 0.5, isPrimary: false)
            } else {
                Color.clear.frame(width: 42, height: 34)
            }
        }
    }

    private var lowRange: some View {
        // 1–5.5: on the scale, essentially never used for lifting. Kept
        // reachable rather than quietly unrepresentable.
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "lower", accent: Theme.inkFaint)
            HStack(spacing: 4) {
                ForEach(lowValues, id: \.self) { low in
                    valueButton(low, isPrimary: false)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(clearLabel) { onPick(nil) }
                .font(Theme.label)
                .tracking(1.2)
                .foregroundStyle(Theme.inkMuted)

            Spacer(minLength: 6)

            Button(showsLowRange ? "hide 1–5.5" : "1–5.5") {
                showsLowRange.toggle()
            }
            .font(Theme.label)
            .tracking(1.2)
            .foregroundStyle(Theme.inkFaint)
        }
        .buttonStyle(.plain)
    }

    private func valueButton(_ option: Float, isPrimary: Bool) -> some View {
        let selected = value == option
        return Button { onPick(option) } label: {
            Text(option.rpeDescription)
                .font(Theme.data(isPrimary ? 16 : 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.void : (isPrimary ? Theme.ink : Theme.inkMuted))
                // A gym-glove target, not a menu line.
                .frame(width: isPrimary ? 44 : 42, height: 34)
                .background(selected ? Theme.signal : Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(selected ? Theme.signal : Theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var lowValues: [Float] {
        stride(from: Float(1), through: Float(5.5), by: 0.5).map { $0 }
    }
}

#Preview {
    VStack(spacing: 20) {
        RPEPicker(value: 8, onChange: { _ in })
        RPEPicker(value: nil, placeholder: "7", prefix: "@", onChange: { _ in })
        RPEPicker(value: 9.5, label: "RPE", clearLabel: "none", onChange: { _ in })
    }
    .padding()
    .background(Theme.void)
}
