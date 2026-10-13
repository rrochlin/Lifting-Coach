import Foundation

/// What a set of an exercise is measured in.
///
/// A treadmill run isn't "5 × 225 lb", and offering weight and reps for one
/// is asking a question that has no answer — the report was "units for
/// exercises like running treadmill do not make sense". `WorkoutSet` has
/// carried `duration` and `distance` since `v13_setDurationDistance`; this is
/// what tells the tracker which pair of fields to draw.
public enum ExerciseTracking: String, Codable, Hashable, Sendable, CaseIterable {
    /// Weight × reps.
    case strength
    /// Time, and optionally distance: a run, a row, a plank.
    case timed
}

extension Exercise {
    /// How this exercise is logged unless the lifter says otherwise.
    ///
    /// **Read from the catalog's own `category`, never from the name.** The
    /// vendored catalog files fourteen entries under `cardio` (*Running,
    /// Treadmill*, *Rowing, Stationary*, …), which is a statement the catalog
    /// makes about the entry — the same standing as its equipment or muscle
    /// group. A name matcher deciding "this sounds like cardio" would be the
    /// thing this codebase deleted (see CLAUDE.md's name-matching rule).
    ///
    /// It's a default, not the answer: the catalog files a plank under
    /// `strength`, and an imported or program-created exercise has no category
    /// at all. `User.exerciseTracking` is where the lifter overrides it.
    public var defaultTracking: ExerciseTracking {
        category?.lowercased() == "cardio" ? .timed : .strength
    }
}

extension WeightUnit {
    /// The distance unit that goes with this weight unit: miles beside
    /// pounds, kilometres beside kilograms.
    ///
    /// The unit preference in this app is really a choice of *system* —
    /// app-wide, per exercise, per set (`User.unit(forExerciseID:)`,
    /// `WorkoutSet.unit`). A timed exercise reads that same chain as a distance
    /// unit, so "this treadmill reads in kilometres" is the same sticky
    /// per-exercise setting as "this rack is marked in kilograms", and needs
    /// no second preference to keep in step with the first.
    public var distanceUnit: UnitLength {
        self == .pounds ? .miles : .kilometers
    }

    /// The unit's name as a distance, for a menu.
    public var distanceName: String {
        self == .pounds ? "Miles (mi)" : "Kilometers (km)"
    }
}

extension User {
    /// How the lifter logs a given exercise: their own sticky choice, then the
    /// catalog's default. Same two-level shape as `unit(forExerciseID:)`.
    public func tracking(for exercise: Exercise) -> ExerciseTracking {
        exerciseTracking?[exercise.id] ?? exercise.defaultTracking
    }
}

/// A duration typed on a number pad, the way a stopwatch takes it.
///
/// Digits fill from the right, so there's no colon to hunt for on a keyboard
/// that doesn't have one: `3000` is 30:00, `13000` is 1:30:00, `45` is 0:45.
/// The same convention `RestControl` uses for a rest period, extended to
/// hours because a long run needs them.
public enum DurationEntry {
    /// Seconds for a string of digits, or `nil` for no digits at all — which
    /// is "nothing entered", not zero.
    ///
    /// Each pair is taken at face value and summed, so `90` is ninety seconds
    /// and `130` is 1:30 — both read the way they were typed, and neither is
    /// rejected for having a "minutes" pair over 59.
    public static func seconds(fromDigits text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        // Longer than hhmmss can't be a session; keep the last six typed.
        let padded = String(repeating: "0", count: max(0, 6 - digits.count)) + digits.suffix(6)
        let hours = Int(padded.prefix(2)) ?? 0
        let minutes = Int(padded.dropFirst(2).prefix(2)) ?? 0
        let seconds = Int(padded.suffix(2)) ?? 0
        return hours * 3600 + minutes * 60 + seconds
    }

    /// What the digits typed so far mean, placed by position with nothing
    /// carried: `9` → `0:09`, `90` → `0:90`, `900` → `9:00`.
    ///
    /// Shown beside the field while it's being typed into (the keyboard bar),
    /// so the lifter sees the time their digits are becoming. Deliberately not
    /// `format(seconds:)`: `90` reads `0:90` here rather than `1:30`, because
    /// it's on its way to `9:00` or `9:05` and the display should extend what
    /// was typed, not what it currently sums to.
    ///
    /// **It is not written back into the field.** Two versions of this did
    /// that — redrawing `9` as `0:09` on every keystroke — and both lost
    /// digits when typed quickly, because the redraw moves the caret and the
    /// next key lands wherever it was left. The field holds plain digits while
    /// it has focus, so nothing is redrawn under the lifter's thumb.
    public static func positional(digits text: String) -> String {
        let digits = String(text.filter(\.isNumber).drop { $0 == "0" }.suffix(6))
        guard !text.filter(\.isNumber).isEmpty else { return "" }
        let padded = String(repeating: "0", count: max(0, 3 - digits.count)) + digits
        let seconds = padded.suffix(2)
        let rest = padded.dropLast(2)
        guard rest.count > 2 else { return "\(rest):\(seconds)" }
        return "\(rest.dropLast(2)):\(rest.suffix(2)):\(seconds)"
    }

    /// `45` → `0:45`, `1800` → `30:00`, `5400` → `1:30:00`.
    public static func format(seconds: Int) -> String {
        let total = max(0, seconds)
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// The digits that would produce `seconds`, for putting a stored value
    /// back into an editable field: 1800 → `3000`.
    public static func digits(forSeconds seconds: Int) -> String {
        format(seconds: seconds).filter(\.isNumber)
            .drop { $0 == "0" }
            .description
    }
}
