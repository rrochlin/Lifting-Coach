import SwiftUI
import LiftingCoachModel

/// Rest, as one line under a set: `REST ————— 2:00`.
///
/// It's the same line whether rest is prescribed or counting down, and what
/// tells the two apart is colour, not layout. Inactive is quiet ink. Active is
/// amber with a track draining under it. Complete is cyan.
///
/// **This view never expands.** It draws a line of fixed height and reports
/// taps; the parent decides whether `RestEditor` appears, and where. That isn't
/// a style preference — it's the fix for an animation bug that survived two
/// attempts inside this file. When the line and the editor were one view, the
/// editor's arrival changed the height of the `List` row they shared, and the
/// row's contents were laid out for the open state inside a frame that was
/// still growing: the clock and the buttons drifted toward each other and
/// visibly crossed. Owned by the parent, the editor is a *row of its own* —
/// nothing already on screen resizes, so there is nothing to interpolate and
/// nothing to cross.
///
/// Two ways to change the number, and only two:
/// - **Tap the line** — the parent opens `RestEditor`: ±30/±15 and the one
///   action that applies.
/// - **Tap the number** — type it. Digits fill from the right the way a
///   stopwatch takes them (`230` is 2:30), so a number pad is enough and
///   there's no colon to hunt for.
///
/// There was a row of preset durations too. It's gone: a third way to say what
/// the steppers and the keyboard both already say, and this control has been
/// through enough of those.
struct RestControl: View {
    enum Mode {
        /// A rest value being set — a set's own rest, or the default it
        /// inherits. `isExplicit` is false when the number shown was inherited
        /// rather than chosen here.
        case prescription(seconds: Int, isExplicit: Bool)
        /// A rest period counting down.
        case running(RestTimer)
    }

    let mode: Mode
    /// Whether the parent is currently showing `RestEditor` for this line. This
    /// view only reflects it — in the caret, which is the one thing here that
    /// animates, being a rotation that can't drag layout around with it.
    var isExpanded: Bool = false
    var onToggleExpanded: () -> Void = {}
    /// Where a typed duration lands.
    var onSet: (Int) -> Void = { _ in }

    /// Half an hour. Long past anything real, but a bound stops a fat-fingered
    /// `9999` from producing an hours-long timer.
    static let maximum = 1800

    /// Typing state. It stays in this view rather than moving out with the
    /// expansion because it changes nothing about the layout — the number
    /// occupies the same box whether it's being read or written.
    @State private var isTyping = false
    @State private var digits = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button(action: onToggleExpanded) {
                    HStack(spacing: 8) {
                        Image(systemName: mode.isOver ? "checkmark.circle.fill" : "timer")
                            .font(.system(size: 12, weight: .medium))
                        Text(mode.title)
                            .font(Theme.label)
                            .tracking(1.6)
                            .fixedSize()
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 1)
                    }
                    .foregroundStyle(mode.accent)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                clock

                Button(action: onToggleExpanded) {
                    FieldCaret(color: mode.accent.opacity(0.85))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                        .frame(width: 18, height: clockHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            // Only a running rest draws a track. Its presence is half of what
            // says "this one is live" — a dim rule under every set would be
            // noise, and under the running one it wouldn't mean anything.
            if case .running(let timer) = mode {
                if timer.hasExpired {
                    track(1)
                } else {
                    TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
                        track(timer.progress(at: context.date))
                    }
                }
            }
        }
    }

    // MARK: The number

    /// Read or written, the number lives in a box of the same size, so starting
    /// to type doesn't resize the row around it.
    @ViewBuilder
    private var clock: some View {
        if isTyping {
            TextField(
                "",
                text: entry,
                prompt: Text(mode.currentSeconds.restClockDescription)
                    .foregroundColor(Theme.inkFaint)
            )
            .keyboardType(.numberPad)
            .focused($focused)
            .multilineTextAlignment(.trailing)
            .font(Theme.data(isBig ? 24 : 17, weight: .medium))
            .foregroundStyle(Theme.ink)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .frame(width: clockWidth, height: clockHeight)
            .background(Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.signal, lineWidth: 1)
            )
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
        } else {
            reading
                .frame(width: clockWidth, height: clockHeight, alignment: .trailing)
                .contentShape(.rect)
                .onTapGesture {
                    digits = ""
                    isTyping = true
                    focused = true
                }
        }
    }

    /// The ticking half. The `TimelineView` wraps the digits and nothing else —
    /// rebuilding the buttons around them once a second is how a phone gets
    /// warm in the middle of a workout.
    @ViewBuilder
    private var reading: some View {
        switch mode {
        case .running(let timer) where timer.hasExpired:
            // A finished timer has nothing left to count, so the timeline goes
            // away entirely rather than redrawing 0:00 once a second until
            // someone dismisses it.
            digitsView(0)
        case .running(let timer):
            TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
                // Rounded up, so a timer showing 1:00 has a full minute left
                // rather than flicking to 0:59 the instant it starts.
                digitsView(Int(timer.remaining(at: context.date).rounded(.up)))
            }
        case .prescription(let seconds, _):
            digitsView(seconds)
        }
    }

    private func digitsView(_ seconds: Int) -> some View {
        Text(seconds.restClockDescription)
            // The live clock is the biggest thing on the row; a prescribed one
            // is annotation and sits back. Size is part of what separates the
            // two states, along with the colour and the track — three quiet
            // 2:00s under three sets shouldn't shout as loudly as the one
            // that's running.
            .font(Theme.data(isBig ? 24 : 17, weight: .medium))
            .foregroundStyle(mode.clockInk)
            // Digits keep their column as the count changes, so the readout
            // doesn't jitter every second — and the clock is the one thing here
            // that must never wrap: "2:00" broken across two lines reads as two
            // numbers.
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: isBig))
            .fixedSize()
    }

    /// Digits fill from the right, stopwatch style: `2` is 0:02, `230` is 2:30.
    /// Formatting on the way out and stripping on the way in lets the field
    /// show a colon the number pad has no key for.
    private var entry: Binding<String> {
        Binding(
            get: { digits.isEmpty ? "" : Self.clock(from: digits) },
            set: { digits = String($0.filter(\.isNumber).suffix(4)) }
        )
    }

    private static func clock(from digits: String) -> String {
        let padded = String(repeating: "0", count: max(0, 3 - digits.count)) + digits
        let seconds = Int(padded.suffix(2)) ?? 0
        let minutes = Int(padded.dropLast(2)) ?? 0
        return "\(minutes):" + String(format: "%02d", seconds)
    }

    /// Applied when the field gives up focus — never while typing. A running
    /// timer would otherwise see `2` on the way to `2:30`, and expire.
    private func commit() {
        isTyping = false
        guard !digits.isEmpty else { return }
        let padded = String(repeating: "0", count: max(0, 3 - digits.count)) + digits
        let seconds = (Int(padded.dropLast(2)) ?? 0) * 60 + (Int(padded.suffix(2)) ?? 0)
        digits = ""
        onSet(min(Self.maximum, max(0, seconds)))
    }

    private var isBig: Bool {
        if case .running = mode { return true }
        return false
    }

    private var clockWidth: CGFloat { isBig ? 104 : 74 }
    private var clockHeight: CGFloat { isBig ? 34 : 28 }

    /// Drawn rather than a `ProgressView`, which needs a scale hack to stop
    /// being a chunky system bar and animates on values it wasn't given.
    private func track(_ progress: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule()
                    .fill(mode.accent)
                    .frame(width: geometry.size.width * min(1, max(0, progress)))
            }
        }
        .frame(height: 3)
    }
}

// MARK: - The editor

/// What you touch to change a rest period: ±30, ±15, and the one action that
/// applies — "SKIP" while a rest runs, "DONE" once it's up, "RESET 2:00" when
/// there's a prescription to go back to.
///
/// **The parent owns whether this is on screen**, and places it as a row of its
/// own under the line. See `RestControl` for why: a row that grows is a row
/// whose contents cross each other on the way.
///
/// One row, deliberately. There was a second one holding preset durations, and
/// it was a third way to say what the steppers and the keyboard already say.
struct RestEditor: View {
    let mode: RestControl.Mode
    /// Nudge by a delta. Only the running state uses this — `RestTimer.adjust`
    /// clamps against elapsed time and moves the bar's denominator with it,
    /// which is arithmetic this view has no business redoing.
    var onAdjust: (Int) -> Void = { _ in }
    /// Jump straight to a duration — a step resolved against a static value.
    var onSet: (Int) -> Void = { _ in }
    var actionLabel: String?
    var onAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            step("−30", by: -30)
            step("−15", by: -15)
            step("+15", by: 15)
            step("+30", by: 30)
            if let actionLabel, let onAction {
                action(actionLabel, onAction)
            }
        }
    }

    private func step(_ label: String, by delta: Int) -> some View {
        Button { adjust(by: delta) } label: {
            Text(label)
                .font(Theme.data(13, weight: .medium))
                .foregroundStyle(canStep(delta) ? Theme.ink : Theme.inkFaint)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Theme.fieldEdge, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canStep(delta))
    }

    /// Fixed width, so it's the steppers that give ground on a narrow screen
    /// rather than this truncating to "SKIP RE…".
    private func action(_ label: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(label.uppercased())
                .font(Theme.label)
                .tracking(1.2)
                .foregroundStyle(mode.accent)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(mode.accent.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
    }

    /// Steps compound from whatever's showing — that's the point of a stepper —
    /// but a running clock is adjusted through the timer, which clamps against
    /// the time already spent instead of going negative.
    private func adjust(by delta: Int) {
        switch mode {
        case .running: onAdjust(delta)
        case .prescription(let seconds, _):
            onSet(min(RestControl.maximum, max(0, seconds + delta)))
        }
    }

    private func canStep(_ delta: Int) -> Bool {
        if mode.isOver { return delta > 0 }
        if delta < 0 { return mode.currentSeconds > 0 }
        return mode.currentSeconds < RestControl.maximum
    }
}

// MARK: - Shared reading of the mode

extension RestControl.Mode {
    /// Read from the timer's latched flag rather than from the clock, so the
    /// static half of this control isn't a function of the current second.
    /// `RestTimer.hasExpired` exists for exactly this.
    var isOver: Bool {
        if case .running(let timer) = self { return timer.hasExpired }
        return false
    }

    /// The whole of the active/inactive distinction. A prescribed rest is
    /// annotation and reads like it; a running one is the live moment and gets
    /// the app's one amber; a finished one is cyan, like every other completion.
    var accent: Color {
        switch self {
        case .running: isOver ? Theme.signal : Theme.live
        case .prescription(_, let isExplicit): isExplicit ? Theme.inkMuted : Theme.inkFaint
        }
    }

    var clockInk: Color {
        switch self {
        case .running: isOver ? Theme.signal : Theme.ink
        case .prescription(_, let isExplicit): isExplicit ? Theme.ink : Theme.inkFaint
        }
    }

    var title: String {
        switch self {
        case .running: isOver ? "REST COMPLETE" : "REST"
        case .prescription: "REST"
        }
    }

    var currentSeconds: Int {
        switch self {
        case .running(let timer): Int(timer.remaining(at: Date()).rounded(.up))
        case .prescription(let seconds, _): seconds
        }
    }
}

extension Int {
    /// Seconds as `M:SS`, the one format rest is written in across the app.
    var restClockDescription: String {
        String(format: "%d:%02d", self / 60, self % 60)
    }
}

#Preview {
    let timer = RestTimer(
        exerciseID: UUID(),
        setID: UUID(),
        exerciseName: "Barbell Bench Press",
        seconds: 150,
        from: Date().addingTimeInterval(-40)
    )
    return VStack(alignment: .leading, spacing: 20) {
        RestControl(mode: .prescription(seconds: 180, isExplicit: true))
        VStack(alignment: .leading, spacing: 9) {
            RestControl(mode: .running(timer), isExpanded: true)
            RestEditor(mode: .running(timer), actionLabel: "skip", onAction: {})
        }
    }
    .padding()
    .background(Theme.void)
}
