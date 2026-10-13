import LiftingCoachModel
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
            .numericKeyboardBar(
                isFocused: focused, label: label, step: step, hasNext: false,
                onStep: onStep, onNext: {}, onDone: { focused = false }
            )
            #endif
    }
}

// MARK: - Suggesting field

/// A number field that can be **empty**, showing what the lifter did last time
/// as a proposal rather than as a value.
///
/// The problem it solves: `NumberField` binds a non-optional number, so an
/// unlogged set rendered `0` — a weight nobody has ever lifted, sitting in the
/// field as though it were data. Strong and Hevy both show last session's
/// numbers greyed instead, and checking the set off accepts them.
///
/// **What's shown here is a proposal, not a prescription.** It only ever fills
/// a field that is otherwise empty: a set carrying program data keeps it, since
/// `WorkoutSession.start(from:)` writes the prescribed reps and resolved weight
/// as real values. So this never overrides what a coach asked for — it fills in
/// where nothing was asked at all (Core Tenets §1).
///
/// **It is not styled with colour alone.** The placeholder is `inkMuted`, which
/// meets AA as text because it is text you can commit by tapping a checkbox —
/// not decorative hint text. Where the number came from is said in words on the
/// annotation line, because "this is a suggestion" is not something a shade of
/// grey can convey to everyone (WCAG §1.4.1).
struct SuggestingNumberField<ID: Hashable>: View {
    /// `nil` means the lifter hasn't entered anything here.
    @Binding var value: Double?
    /// What they did last time, shown greyed when `value` is nil.
    var suggestion: Double?
    /// Digits to keep. Reps take 0; a weight takes 2.
    var fractionDigits: Int = 2
    var label: String = ""
    var isActive: Bool = true
    var font: Font = Theme.data(15, weight: .medium)
    var foreground: Color = Theme.ink
    var minWidth: CGFloat = 30
    var maxWidth: CGFloat = 72
    /// The increment offered above the keyboard, or `nil` for none. The field
    /// applies it itself, through `value` — see `applyStep`.
    var step: Double?
    /// Called once as the lifter leaves the field, with the value it held when
    /// they arrived. For whatever a *finished* edit means to the caller — the
    /// tracker carries a changed weight down to the sets below — as opposed to
    /// `value`, which is written on every keystroke.
    var onEditingEnded: (_ valueOnArrival: Double?) -> Void = { _ in }

    /// Focus, owned by the screen rather than by this field.
    ///
    /// A decimal pad has no return key, so DONE was the only way off it — and
    /// with each field holding its own private `@FocusState` there was no way
    /// for one to hand over to the next. Typing a warmup meant DONE, tap, type,
    /// DONE, tap, type. The screen owns one focus value keyed by field, so the
    /// bar can carry a NEXT that actually moves.
    ///
    /// `id` is this field's key in that space; `next` is where NEXT goes, or
    /// `nil` when this is the last field and NEXT should just dismiss.
    var focus: FocusState<ID?>.Binding
    let id: ID
    var next: ID?

    /// Editing happens in text so the field can be genuinely empty. A numeric
    /// binding has no way to represent "nothing typed yet".
    @State private var text: String = ""
    @State private var selection: TextSelection?
    @State private var valueOnArrival: Double?

    private var focused: Bool { focus.wrappedValue == id }

    var body: some View {
        TextField("", text: $text, selection: $selection, prompt: prompt)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .focused(focus, equals: id)
            .font(font)
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .frame(minWidth: minWidth, maxWidth: maxWidth)
            .editableField(
                isActive: focused || isActive,
                accent: focused ? Theme.signal : Theme.fieldEdge
            )
            // **Written as it's typed, not when the field is left.** It used to
            // commit on blur, and that made the model lag the screen: tapping a
            // set's checkbox completes it in the same instant the field loses
            // focus, so the set was logged — and checked for a new max — at
            // the weight it had *before* the edit, and the typed number landed
            // a moment later. A lifter who dropped 275 to 255 was told 275 was
            // a new max. Nothing downstream can be trusted to wait for a blur,
            // so there is no longer a moment when the screen and the model
            // disagree. A half-typed `2` on the way to `255` is briefly the
            // stored weight, which costs nothing: only completing a set acts
            // on it.
            .onChange(of: text) { _, typed in
                guard focused else { return }
                switch NumericEntry.read(typed) {
                case .value(let number): if value != number { value = number }
                // Clearing the field is a real edit — "I didn't do this".
                case .empty: if value != nil { value = nil }
                case .partial: break
                }
            }
            .onChange(of: focus.wrappedValue) { previous, current in
                if current == id, previous != id { arrive() }
                if previous == id, current != id { leave() }
            }
            .onAppear { text = NumericEntry.format(value, fractionDigits: fractionDigits) }
            // Something else wrote the value — a weight carried down from the
            // set above, a unit switch. Take it, unless the lifter is typing.
            .onChange(of: value) { _, newValue in
                guard !focused else { return }
                text = NumericEntry.format(newValue, fractionDigits: fractionDigits)
            }
            #if os(iOS)
            .numericKeyboardBar(
                isFocused: focused, label: label, step: step, hasNext: next != nil,
                onStep: applyStep,
                onNext: { focus.wrappedValue = next },
                onDone: { focus.wrappedValue = nil }
            )
            #endif
    }

    private var prompt: Text? {
        guard let suggestion else { return nil }
        return Text(NumericEntry.format(suggestion, fractionDigits: fractionDigits))
            .foregroundColor(Theme.inkMuted)
    }

    /// Tapping into a number selects all of it, so typing replaces it.
    ///
    /// A weight is far more often *replaced* than edited — 275 becomes 255 —
    /// and with the caret at the end that was backspace, backspace, retype.
    /// Deferred a beat because the text field places its own caret as it takes
    /// focus, after this runs.
    private func arrive() {
        valueOnArrival = value
        guard !text.isEmpty else { return }
        Task { @MainActor in
            guard focused, !text.isEmpty else { return }
            selection = TextSelection(range: text.startIndex..<text.endIndex)
        }
    }

    private func leave() {
        // Tidy what's shown: "255." reads back as "255", and text that never
        // became a number (a lone ".") reverts to the value it didn't change.
        text = NumericEntry.format(value, fractionDigits: fractionDigits)
        selection = nil
        onEditingEnded(valueOnArrival)
    }

    /// A ± step, applied to what is on screen and written to both the text and
    /// the value.
    ///
    /// This used to be the caller's job, and it changed the stored value while
    /// this field — focused, so deliberately ignoring outside writes — kept
    /// its old text and then wrote that text back on the way out. The buttons
    /// did nothing. The field owns its text, so the field applies the step.
    private func applyStep(_ delta: Double) {
        let stepped = NumericEntry.stepped(text: text, value: value, suggestion: suggestion, by: delta)
        text = NumericEntry.format(stepped, fractionDigits: fractionDigits)
        value = stepped
    }
}

// MARK: - Duration field

/// A time, typed on the number pad the way a stopwatch takes it — digits fill
/// from the right, so `3000` is thirty minutes and there is no colon to find
/// on a keyboard that doesn't have one. See `DurationEntry`.
///
/// For work measured in time rather than weight: a run, a row, a plank. Same
/// contract as `SuggestingNumberField` — it can be empty, it writes as it's
/// typed, it selects everything on arrival, and the screen owns its focus so
/// NEXT can move on.
struct DurationField<ID: Hashable>: View {
    /// Seconds, or `nil` for nothing entered.
    @Binding var seconds: Int?
    var label: String = "time"
    var isActive: Bool = true
    var font: Font = Theme.data(15, weight: .medium)
    var foreground: Color = Theme.ink
    var minWidth: CGFloat = 52
    var maxWidth: CGFloat = 96

    var focus: FocusState<ID?>.Binding
    let id: ID
    var next: ID?

    /// Plain digits while the field has focus (`3000`), the formatted time
    /// when it doesn't (`30:00`).
    @State private var text: String = ""
    @State private var selection: TextSelection?

    private var focused: Bool { focus.wrappedValue == id }

    var body: some View {
        TextField("", text: $text, selection: $selection, prompt: Text("0:00").foregroundColor(Theme.inkFaint))
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .focused(focus, equals: id)
            .font(font)
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .frame(minWidth: minWidth, maxWidth: maxWidth)
            .editableField(
                isActive: focused || isActive,
                accent: focused ? Theme.signal : Theme.fieldEdge
            )
            // Written as it's typed, like the number fields — and **the text
            // is never rewritten while it's being typed into**. See
            // `DurationEntry.positional` for the two attempts that did, and
            // what fast typing did to them.
            .onChange(of: text) { _, typed in
                guard focused else { return }
                let entered = DurationEntry.seconds(fromDigits: typed)
                if seconds != entered { seconds = entered }
            }
            .onChange(of: focus.wrappedValue) { previous, current in
                if current == id, previous != id {
                    // Arriving: the stored time as the digits that make it,
                    // all selected, so typing replaces it.
                    text = seconds.map(DurationEntry.digits(forSeconds:)) ?? ""
                    guard !text.isEmpty else { return }
                    Task { @MainActor in
                        guard focused, !text.isEmpty else { return }
                        selection = TextSelection(range: text.startIndex..<text.endIndex)
                    }
                }
                if previous == id, current != id { show(seconds) }
            }
            .onAppear { show(seconds) }
            .onChange(of: seconds) { _, newValue in
                guard !focused else { return }
                show(newValue)
            }
            #if os(iOS)
            .numericKeyboardBar(
                // The bar says what the digits mean: "TIME 30:00" over a
                // field reading 3000.
                isFocused: focused,
                label: text.isEmpty ? label : "\(label) \(DurationEntry.positional(digits: text))",
                step: nil, hasNext: next != nil,
                onStep: { _ in },
                onNext: { focus.wrappedValue = next },
                onDone: { focus.wrappedValue = nil }
            )
            #endif
    }

    /// Normalised, for reading: `90` typed is `1:30` shown.
    private func show(_ seconds: Int?) {
        text = seconds.map(DurationEntry.format(seconds:)) ?? ""
        selection = nil
    }
}

// MARK: - The keyboard bar

extension View {
    /// The accessory bar every numeric field carries. Shared rather than
    /// duplicated, so the two field types can't drift apart on the one
    /// interaction they both exist to provide.
    @ViewBuilder
    func numericKeyboardBar(
        isFocused: Bool,
        label: String,
        step: Double?,
        hasNext: Bool,
        onStep: @escaping (Double) -> Void,
        onNext: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        self.toolbar {
            // Only the focused field contributes a bar. Every set row holds two
            // of these; without the guard each one adds its own and they stack.
            if isFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    if let step {
                        StepButton(delta: -step, action: onStep)
                        StepButton(delta: step, action: onStep)
                    }
                    if !label.isEmpty {
                        Text(label.uppercased())
                            .font(Theme.label)
                            .tracking(1.4)
                            .foregroundStyle(Theme.inkMuted)
                            // The bar is wide and the label is one word;
                            // without this it wraps to "WEIG / HT".
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Spacer()
                    // The return key a decimal pad doesn't have. Weight →
                    // reps → the next set's weight, without reaching back to
                    // the screen between every number.
                    if hasNext {
                        Button("NEXT", action: onNext)
                            .font(Theme.label)
                            .tracking(1.4)
                            .foregroundStyle(Theme.ink)
                    }
                    Button("DONE", action: onDone)
                        .font(Theme.label)
                        .tracking(1.4)
                        .foregroundStyle(Theme.signal)
                }
            }
        }
        #else
        self
        #endif
    }
}

/// Steps apply immediately and leave the field focused — the lifter is usually
/// adding a plate and then another one.
private struct StepButton: View {
    let delta: Double
    let action: (Double) -> Void

    var body: some View {
        Button { action(delta) } label: {
            Text(Self.label(delta))
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
    static func label(_ delta: Double) -> String {
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
