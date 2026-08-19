import SwiftUI
import LiftingCoachModel

/// Rest set for a whole scope at once — every set of an exercise, or every set
/// of a type across a block.
///
/// The counterpart to `RestControl`, which is the one control for the rest
/// under a *single* set. This one is deliberately a different shape rather than
/// a fourth way to edit that: it never counts down, it never belongs to a set,
/// and the value it writes is a default that something more specific may
/// override. What it borrows is the field treatment — the same outlined box and
/// caret every editable quantity in the app wears, so a rest default reads as a
/// control rather than as a caption.
///
/// Shared rather than duplicated per screen for the reason `ExercisePicker` and
/// `NoteSheet` are: a copied control doesn't stay copied, it drifts.
struct RestMenu: View {
    /// `nil` means nothing is set at this level, and the next one down the
    /// chain answers instead.
    let seconds: Int?
    /// What this control is setting, carried inside the tappable area so the
    /// label is part of the target. `nil` where the caller has already written
    /// one beside it — the block editor lays its three out as `Readout` rows,
    /// which needs the labels aligned in a column rather than butted against
    /// each field.
    var label: String? = "REST"
    /// The sets in scope don't agree, so there's no single value to show.
    var isMixed: Bool = false
    /// What clearing this value falls back to, in the lifter's words — "block
    /// default" inside a block, "app default" for the block's own settings.
    var clearLabel: String = "block default"
    let onChange: (Int?) -> Void

    var body: some View {
        Menu {
            Button(clearLabel) { onChange(nil) }
            Divider()
            ForEach(options, id: \.self) { value in
                Button(value.restClockDescription) { onChange(value) }
            }
        } label: {
            HStack(spacing: 4) {
                if let label {
                    Text(label)
                        .font(Theme.label)
                        .tracking(1.2)
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize()
                }
                // The same field `RPEPicker` wears, so a rest default reads
                // as one of a family of editable values rather than as a
                // label with a number after it.
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(seconds == nil ? Theme.inkFaint : Theme.ink)
                    Text(displayValue)
                        .font(Theme.data(14, weight: .medium))
                        .foregroundStyle(seconds == nil ? Theme.inkFaint : Theme.ink)
                    FieldCaret(color: seconds == nil ? Theme.inkFaint : Theme.inkMuted)
                }
                .editableField(isActive: seconds != nil)
            }
            .fixedSize()
        }
    }

    private var displayValue: String {
        if let seconds { return seconds.restClockDescription }
        return isMixed ? "mixed" : "—"
    }

    private var options: [Int] { [30, 45, 60, 90, 120, 150, 180, 240, 300] }
}
