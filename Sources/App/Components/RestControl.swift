import SwiftUI
import LiftingCoachModel

/// Rest, as one control in two states.
///
/// There used to be two of these: a countdown row in the tracker, and a
/// separate editor behind the per-set chip. They did the same job with
/// different layouts, different buttons, and different ideas about where the
/// clock goes — so tuning rest mid-workout meant learning a second control at
/// the exact moment there's least attention to spare.
///
/// One component now, in two modes. `.prescription` is a rest value being set;
/// `.running` is that value counting down. The skeleton is identical in both —
/// clock, track, steppers, presets, one action — and only what has to differ
/// does: the running state moves, fills its track, and turns amber for the live
/// moment (cyan the instant it's up). Learn it once, in either place.
///
/// **Everything is inline.** The running state carries its own presets rather
/// than opening a sheet to reach them, which is what makes "make it three
/// minutes" one tap instead of six, and removes a presentation that used to
/// hang off a view rebuilding itself every second.
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
    /// Nudge by a delta. Only the running state uses this — `RestTimer.adjust`
    /// clamps against elapsed time and moves the bar's denominator with it,
    /// which is arithmetic this view has no business redoing.
    var onAdjust: (Int) -> Void = { _ in }
    /// Jump straight to a duration: a preset, or a step resolved against a
    /// static value.
    var onSet: (Int) -> Void = { _ in }
    /// The single action beside the steppers — "skip" while running, "reset
    /// 2:00" when there's something to revert to. `nil` draws none.
    var actionLabel: String?
    var onAction: (() -> Void)?

    /// Half an hour. Long past anything real, but a bound stops a stuck +30
    /// from producing an hours-long timer.
    private static let maximum = 1800
    private static let presets = [60, 90, 120, 150, 180, 240, 300]

    var body: some View {
        // Three rows in both modes: what the clock says, how to nudge it, and
        // where to jump to. The action rides on the stepper row rather than
        // taking a fourth — inline under a set, every row costs the lifter
        // screen they'd rather spend on the next set.
        VStack(alignment: .leading, spacing: 9) {
            readout
            stepperRow
            presetRow
        }
    }

    // MARK: Readout

    /// The clock and its track — the only two things here that change with the
    /// second hand.
    ///
    /// The `TimelineView` is scoped to exactly these. Wrapping the whole
    /// control would rebuild a dozen buttons every second for a readout that's
    /// four characters wide, which is the sort of thing that makes a phone warm
    /// in the middle of a workout.
    @ViewBuilder
    private var readout: some View {
        switch mode {
        case .running(let timer) where timer.hasExpired:
            // A finished timer has nothing left to count. Keeping the timeline
            // alive here would redraw 0:00 once a second until the lifter
            // dismissed it, which is a phone warming up to say nothing.
            readoutBody(seconds: 0, progress: 1)
        case .running(let timer):
            TimelineView(.periodic(from: timer.startedAt, by: 1)) { context in
                readoutBody(
                    // Rounded up, so a timer showing 1:00 has a full minute left
                    // rather than flicking to 0:59 the instant it starts.
                    seconds: Int(timer.remaining(at: context.date).rounded(.up)),
                    progress: timer.progress(at: context.date)
                )
            }
        case .prescription(let seconds, _):
            readoutBody(seconds: seconds, progress: 0)
        }
    }

    private func readoutBody(seconds: Int, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: isOver ? "checkmark.circle.fill" : "timer")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accent)
                Text(title)
                    .font(Theme.label)
                    .tracking(1.6)
                    .foregroundStyle(accent)
                    .fixedSize()
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                Text(seconds.restClockDescription)
                    .font(Theme.data(24, weight: .medium))
                    .foregroundStyle(clockInk)
                    // Digits keep their column as the count changes, so the
                    // readout doesn't jitter every second — and the clock is the
                    // one thing here that must never wrap: "2:00" broken across
                    // two lines reads as two numbers.
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: isRunning))
                    .fixedSize()
            }

            track(progress)
        }
    }

    /// Drawn rather than a `ProgressView`, which needs a scale hack to stop
    /// being a chunky system bar and animates on values it wasn't given.
    /// Present in both modes at the same height: the track is where the
    /// countdown will run, and keeping it makes the two states read as one
    /// control rather than two.
    private func track(_ progress: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule()
                    .fill(accent)
                    .frame(width: geometry.size.width * min(1, max(0, progress)))
            }
        }
        .frame(height: 3)
    }

    // MARK: Controls

    private var stepperRow: some View {
        HStack(spacing: 6) {
            step("−30", by: -30)
            step("−15", by: -15)
            step("+15", by: 15)
            step("+30", by: 30)
            if let actionLabel, let onAction {
                actionButton(actionLabel, onAction)
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

    private var presetRow: some View {
        // The jumps the steppers would take a dozen taps to reach.
        HStack(spacing: 4) {
            ForEach(Self.presets, id: \.self) { preset in
                Button { onSet(preset) } label: {
                    Text(preset.restClockDescription)
                        .font(Theme.data(11, weight: isSelected(preset) ? .semibold : .regular))
                        .foregroundStyle(isSelected(preset) ? Theme.void : Theme.inkMuted)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(isSelected(preset) ? Theme.signal : Theme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Fixed width, so it's the steppers that give ground on a narrow screen
    /// rather than this truncating to "SKIP RE…".
    private func actionButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(Theme.label)
                .tracking(1.2)
                .foregroundStyle(accent)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(accent.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
    }

    // MARK: State

    private var isRunning: Bool {
        if case .running = mode { return true }
        return false
    }

    /// Read from the timer's latched flag rather than from the clock, so the
    /// static half of this control isn't a function of the current second.
    /// `RestTimer.hasExpired` exists for exactly this.
    private var isOver: Bool {
        if case .running(let timer) = mode { return timer.hasExpired }
        return false
    }

    private var accent: Color {
        switch mode {
        case .running: isOver ? Theme.signal : Theme.live
        case .prescription: Theme.inkMuted
        }
    }

    private var title: String {
        switch mode {
        case .running: isOver ? "REST COMPLETE" : "REST"
        case .prescription: "REST"
        }
    }

    private var clockInk: Color {
        switch mode {
        case .running: isOver ? Theme.signal : Theme.ink
        case .prescription(_, let isExplicit): isExplicit ? Theme.ink : Theme.inkFaint
        }
    }

    private var currentSeconds: Int {
        switch mode {
        case .running(let timer): Int(timer.remaining(at: Date()).rounded(.up))
        case .prescription(let seconds, _): seconds
        }
    }

    /// Steps compound from whatever's showing — that's the point of a stepper —
    /// but a running clock is adjusted through the timer, which clamps against
    /// the time already spent instead of going negative.
    private func adjust(by delta: Int) {
        switch mode {
        case .running: onAdjust(delta)
        case .prescription(let seconds, _):
            onSet(min(Self.maximum, max(0, seconds + delta)))
        }
    }

    private func canStep(_ delta: Int) -> Bool {
        if isOver { return delta > 0 }
        if delta < 0 { return currentSeconds > 0 }
        return currentSeconds < Self.maximum
    }

    /// Nothing is "selected" while a clock is running: the highlight would land
    /// on 3:00 and leave again a second later.
    private func isSelected(_ preset: Int) -> Bool {
        if case .prescription(let seconds, _) = mode { return preset == seconds }
        return false
    }
}

extension Int {
    /// Seconds as `M:SS`, the one format rest is written in across the app.
    var restClockDescription: String {
        String(format: "%d:%02d", self / 60, self % 60)
    }
}

#Preview {
    VStack(spacing: 24) {
        RestControl(
            mode: .prescription(seconds: 180, isExplicit: true),
            actionLabel: "reset 2:00",
            onAction: {}
        )
        RestControl(
            mode: .running(
                RestTimer(
                    exerciseID: UUID(),
                    setID: UUID(),
                    exerciseName: "Barbell Bench Press",
                    seconds: 150,
                    from: Date().addingTimeInterval(-40)
                )
            ),
            actionLabel: "skip",
            onAction: {}
        )
    }
    .padding()
    .background(Theme.void)
}
