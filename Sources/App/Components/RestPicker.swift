import SwiftUI

/// Rest for a single set, as a directly editable value.
///
/// The chip is styled like the reps and weight fields beside it because it is
/// the same kind of thing: a quantity belonging to *this* set, not a property
/// of the exercise. Rest was previously written once per exercise and rendered
/// as static annotation text, which made "three minutes before the heavy
/// single, ninety seconds on the back-offs" unsayable.
///
/// Tapping opens `RestControl` — the same control the running countdown *is*,
/// in its `.prescription` state. Setting rest and watching it run are one idea
/// and wear one face; the only difference between what opens here and what
/// appears under a set mid-rest is that one of them is moving.
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
        // Stays open after a preset is tapped, the same way the running
        // control does: jumping to 2:00 and then adding fifteen seconds is one
        // gesture, not two round trips through the chip.
        .popover(isPresented: $isPresented) {
            RestControl(
                mode: .prescription(seconds: seconds, isExplicit: isExplicit),
                onSet: { onChange($0) },
                actionLabel: resetLabel,
                onAction: resetLabel == nil ? nil : {
                    onChange(nil)
                    isPresented = false
                }
            )
            .padding(14)
            .frame(width: 320)
            .background(Theme.panel)
            // iPhone presents a popover as a full sheet without this, which is
            // a whole screen for a dozen buttons.
            .presentationCompactAdaptation(.popover)
        }
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
