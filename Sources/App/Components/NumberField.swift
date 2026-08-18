import SwiftUI

/// Every number a lifter types goes through this field.
///
/// It exists because of the one thing a decimal pad doesn't have: a return key.
/// There is no key on that keyboard that ends editing, so a field opened
/// mid-workout stayed open, covering the bottom third of the screen with no way
/// off it — the rest timer's own entry was the only place in the app that had
/// thought to put a DONE above the keys. That confirmation belongs to *numeric
/// entry*, not to one control that happened to need it first.
///
/// So the accessory bar is part of the field, and comes with anything it types:
/// - **DONE** ends editing, which is also what commits the value —
///   `TextField(value:format:)` writes its binding when editing ends, never per
///   keystroke, so a half-typed `2` on the way to `225` is never a real weight.
/// - **± steps**, where the caller offers one. A lifter adding a plate per side
///   is adding 2.5 lb (or 1 kg) and shouldn't have to retype three digits to say
///   so. Strong's numeric panel does the same thing, and it's the half of that
///   panel that needs no new screen.
///
/// The plate calculator that rounds out Strong's version is real work and is
/// written down in `notes/Feedback.md` as backlog, not sketched in here.
///
/// **Only the focused field contributes the bar.** Every set row holds two of
/// these; without the `focused` guard each one adds its own keyboard toolbar and
/// they stack.
struct NumberField<F: ParseableFormatStyle>: View where F.FormatOutput == String {
    @Binding var value: F.FormatInput
    let format: F

    /// What the bar calls this number, so it's clear which of a row's fields is
    /// being edited once the keyboard covers the row.
    var label: String = ""
    /// Brightens the outline the same way `editableField` does elsewhere.
    var isActive: Bool = true
    var font: Font = Theme.data(15, weight: .medium)
    var foreground: Color = Theme.ink
    var minWidth: CGFloat = 30
    var maxWidth: CGFloat = 72
    /// The increment offered above the keyboard. `nil` offers none — reps and
    /// weight both want one; a percentage typed once doesn't.
    var step: Double?
    /// Applies a step. The caller owns it because the delta has to land on the
    /// caller's own type (reps are `Int`, a weight is a `Measurement`), which
    /// this view is generic over and can't do arithmetic on.
    var onStep: (Double) -> Void = { _ in }

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", value: $value, format: format)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .focused($focused)
            .font(font)
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            // No fixed width: the field takes what's available and shares it
            // with its siblings, so a row reflows instead of overflowing.
            .frame(minWidth: minWidth, maxWidth: maxWidth)
            .editableField(
                isActive: focused || isActive,
                accent: focused ? Theme.signal : Theme.fieldEdge
            )
            #if os(iOS)
            .toolbar { keyboardBar }
            #endif
    }

    @ToolbarContentBuilder
    private var keyboardBar: some ToolbarContent {
        if focused {
            ToolbarItemGroup(placement: .keyboard) {
                if let step {
                    stepButton(-step)
                    stepButton(step)
                }
                if !label.isEmpty {
                    Text(label.uppercased())
                        .font(Theme.label)
                        .tracking(1.4)
                        .foregroundStyle(Theme.inkMuted)
                        // The bar is wide and the label is one word; without
                        // this it wraps to "WEIG / HT" beside the steppers.
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer()
                Button("DONE") { focused = false }
                    .font(Theme.label)
                    .tracking(1.4)
                    .foregroundStyle(Theme.signal)
            }
        }
    }

    /// Steps apply immediately and leave the field focused — the lifter is
    /// usually adding a plate and then another one.
    private func stepButton(_ delta: Double) -> some View {
        Button { onStep(delta) } label: {
            Text(Self.stepLabel(delta))
                .font(Theme.data(15, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 54, minHeight: 30)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Theme.fieldEdge, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// A true minus sign, and no trailing `.0` on a whole-number step.
    static func stepLabel(_ delta: Double) -> String {
        let magnitude = abs(delta)
        let text = magnitude == magnitude.rounded()
            ? String(Int(magnitude))
            : String(format: "%g", magnitude)
        return (delta < 0 ? "−" : "+") + text
    }
}

// MARK: - Dismissing

#if os(iOS)
/// Gives up the keyboard from anywhere.
///
/// The other half of the complaint the accessory bar answers: DONE is a way
/// *off* the keyboard, but touching something else should be one too. Buttons
/// inside a `List` don't take focus, so a tap on a checkbox or an RPE chip
/// leaves the keyboard exactly where it was unless someone says otherwise. The
/// controls a lifter is likely to reach for next say it — resigning focus is
/// also what commits whatever was typed, so nothing is lost on the way.
@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
    )
}
#else
@MainActor func dismissKeyboard() {}
#endif
