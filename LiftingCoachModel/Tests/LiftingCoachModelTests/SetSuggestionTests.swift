import Foundation
import Testing
@testable import LiftingCoachModel

private func logged(
    _ reps: Int, _ pounds: Double, type: SetType = .working
) -> WorkoutSet {
    WorkoutSet(
        reps: reps,
        weight: Measurement(value: pounds, unit: .pounds),
        complete: true,
        type: type
    )
}

private func empty(_ type: SetType = .working) -> WorkoutSet {
    WorkoutSet(complete: false, type: type)
}

@Suite("Set suggestions")
struct SetSuggestionTests {

    @Test("An empty set is offered the matching set from last time")
    func matchesByPosition() {
        let previous = [logged(5, 225), logged(5, 235), logged(5, 245)]
        let current = [empty(), empty(), empty()]

        let second = SetSuggestion.forSet(at: 1, in: current, previous: previous)

        #expect(second?.reps == 5)
        #expect(second?.weight?.value == 235)
    }

    @Test("More sets today than last time reuses the last one")
    func fallsBackToTheLastSetOfItsType() {
        let previous = [logged(5, 225), logged(5, 235)]
        let current = [empty(), empty(), empty()]

        // A fifth working set most resembles the fourth, not the first.
        let third = SetSuggestion.forSet(at: 2, in: current, previous: previous)

        #expect(third?.weight?.value == 235)
    }

    @Test("Warmups draw from warmups, not from the top set")
    func matchesWithinSetType() {
        let previous = [
            logged(5, 135, type: .warmup),
            logged(3, 225, type: .warmup),
            logged(1, 405),
        ]
        let current = [empty(.warmup), empty(.warmup), empty()]

        let firstWarmup = SetSuggestion.forSet(at: 0, in: current, previous: previous)
        let working = SetSuggestion.forSet(at: 2, in: current, previous: previous)

        // Matching across types would propose 405 for a ramp-up.
        #expect(firstWarmup?.weight?.value == 135)
        #expect(working?.weight?.value == 405)
    }

    @Test("A drop set draws from last session's drop sets")
    func dropSetsMatchDropSets() {
        let previous = [logged(5, 225), logged(10, 135, type: .drop)]
        let current = [empty(), empty(.drop)]

        let drop = SetSuggestion.forSet(at: 1, in: current, previous: previous)

        // Positionally this is the second set; by type it's the first drop.
        #expect(drop?.weight?.value == 135)
        #expect(drop?.reps == 10)
    }

    @Test("Only the missing half is suggested")
    func fillsOnlyWhatIsAbsent() {
        let previous = [logged(5, 225)]
        var set = empty()
        set.reps = 3

        let suggestion = SetSuggestion.forSet(at: 0, in: [set], previous: previous)

        // Reps were typed, so they're left alone; the weight is still open.
        #expect(suggestion?.reps == nil)
        #expect(suggestion?.weight?.value == 225)
    }

    @Test("A set that already has both numbers gets no suggestion")
    func fullSetIsLeftAlone() {
        let previous = [logged(5, 225)]
        let current = [WorkoutSet(
            reps: 3, weight: Measurement(value: 315, unit: .pounds),
            complete: false, type: .working
        )]

        #expect(SetSuggestion.forSet(at: 0, in: current, previous: previous) == nil)
    }

    @Test("A logged set gets no suggestion — it's history now")
    func completedSetIsLeftAlone() {
        let previous = [logged(5, 225)]
        let current = [WorkoutSet(complete: true, type: .working)]

        #expect(SetSuggestion.forSet(at: 0, in: current, previous: previous) == nil)
    }

    @Test("No history means no suggestion, not a zero")
    func noHistoryIsNothing() {
        #expect(SetSuggestion.forSet(at: 0, in: [empty()], previous: []) == nil)
    }

    @Test("Incomplete sets from last time aren't proposed")
    func ignoresUnloggedPreviousSets() {
        // A set that was never checked off didn't happen, and finishing a
        // workout drops them — but a snapshot taken mid-session can still hold
        // them, and an unlifted weight is not a suggestion.
        let previous = [WorkoutSet(
            reps: 5, weight: Measurement(value: 999, unit: .pounds),
            complete: false, type: .working
        )]

        #expect(SetSuggestion.forSet(at: 0, in: [empty()], previous: previous) == nil)
    }

    @Test("An out-of-range index is nil rather than a crash")
    func indexOutOfRange() {
        #expect(SetSuggestion.forSet(at: 7, in: [empty()], previous: [logged(5, 225)]) == nil)
    }

    @Test("A suggestion carries the unit the set was actually logged in")
    func preservesLoggedUnit() {
        let previous = [WorkoutSet(
            reps: 5, weight: Measurement(value: 100, unit: .kilograms),
            complete: true, type: .working
        )]

        let suggestion = SetSuggestion.forSet(at: 0, in: [empty()], previous: previous)

        #expect(suggestion?.weight?.unit == .kilograms)
        #expect(suggestion?.weight?.value == 100)
    }

    // MARK: Carrying the set above down

    @Test("With no history, the weight typed above fills the blanks below")
    func carriesEnteredWeightDown() {
        // The reported case: a lift the app has never seen, four blank rows
        // under the one you just typed 225 into.
        var typed = empty()
        typed.weight = Measurement(value: 225, unit: .pounds)
        typed.reps = 5
        let current = [typed, empty(), empty()]

        let third = SetSuggestion.forSet(at: 2, in: current, previous: [])

        #expect(third?.weight?.value == 225)
        #expect(third?.reps == 5)
    }

    @Test("A weight typed above carries even though the set isn't checked off yet")
    func carriesBeforeCompletion() {
        // Waiting for the checkbox would leave the rows blank at exactly the
        // moment the lifter is looking at them.
        var typed = empty()
        typed.weight = Measurement(value: 185, unit: .pounds)

        let suggestion = SetSuggestion.forSet(at: 1, in: [typed, empty()], previous: [])

        #expect(typed.complete != true)
        #expect(suggestion?.weight?.value == 185)
    }

    @Test("History still wins over the set above")
    func historyOutranksTheSetAbove() {
        // Last session matches by ordinal within type, so it knows the third
        // working set was a back-off. The set above only speaks when it can't.
        let previous = [logged(5, 225), logged(5, 235), logged(8, 185)]
        var typed = empty()
        typed.weight = Measurement(value: 225, unit: .pounds)
        let current = [typed, empty(), empty()]

        let third = SetSuggestion.forSet(at: 2, in: current, previous: previous)

        #expect(third?.weight?.value == 185)
        #expect(third?.reps == 8)
    }

    @Test("A warmup ramp is not flattened by the set above it")
    func doesNotFlattenAWarmupRamp() {
        let previous = [
            logged(5, 45, type: .warmup), logged(5, 135, type: .warmup),
            logged(3, 185, type: .warmup),
        ]
        var first = empty(.warmup)
        first.weight = Measurement(value: 45, unit: .pounds)
        let current = [first, empty(.warmup), empty(.warmup)]

        let second = SetSuggestion.forSet(at: 1, in: current, previous: previous)
        let third = SetSuggestion.forSet(at: 2, in: current, previous: previous)

        #expect(second?.weight?.value == 135)
        #expect(third?.weight?.value == 185)
    }

    @Test("The set above is matched within its own type")
    func carriesWithinTypeOnly() {
        // A drop set sitting under a 315 working set is not a 315 drop set.
        var working = empty()
        working.weight = Measurement(value: 315, unit: .pounds)
        let current = [working, empty(.drop)]

        #expect(SetSuggestion.forSet(at: 1, in: current, previous: []) == nil)
    }
}
