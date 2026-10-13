import Foundation

/// The arithmetic behind a typed number field: what a string means as a
/// number, and what a ± step does to it.
///
/// Pulled out of the view because both halves have been wrong in ways a
/// simulator can't show — `simctl` can't type or tap — and a rule that can
/// only be checked by hand in a gym is one that regresses. See
/// `SuggestingNumberField`, which is the only caller.
public enum NumericEntry {
    /// What the lifter has typed, as a number.
    ///
    /// - `.empty` is a real answer — "nothing here" — and distinct from a
    ///   number that couldn't be read.
    /// - `.partial` is text on the way to a number (`.`, `-`), which should
    ///   change nothing yet rather than be read as zero.
    public enum Reading: Equatable, Sendable {
        case empty
        case value(Double)
        case partial
    }

    public static func read(_ text: String) -> Reading {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        // A comma is what some locales' decimal pads emit.
        guard let parsed = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
              parsed.isFinite, parsed >= 0
        else { return .partial }
        return .value(parsed)
    }

    /// The result of pressing a ± step.
    ///
    /// **Steps from what's on screen**, in this order: the number typed (even
    /// if not yet committed anywhere), else the stored value, else the greyed
    /// suggestion, else zero. Stepping from the suggestion is the point of
    /// showing one: last week's 225 with one tap of +2.5 is this week's 227.5,
    /// without typing either number. Never below zero.
    public static func stepped(
        text: String, value: Double?, suggestion: Double?, by delta: Double
    ) -> Double {
        let base: Double = switch read(text) {
        case .value(let typed): typed
        case .empty, .partial: value ?? suggestion ?? 0
        }
        // Rounded to a thousandth so 2.5 steps from a converted weight don't
        // accumulate binary noise into the field ("227.50000000000003").
        return max(0, ((base + delta) * 1000).rounded() / 1000)
    }

    public static func format(_ value: Double?, fractionDigits: Int) -> String {
        guard let value else { return "" }
        return value.formatted(
            .number.precision(.fractionLength(0...fractionDigits)).grouping(.never)
        )
    }
}
