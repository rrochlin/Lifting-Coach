import Testing
@testable import LiftingCoachModel

@Suite("Numeric entry")
struct NumericEntryTests {
    @Test("Text reads as a number, as nothing, or as not-yet-a-number")
    func reading() {
        #expect(NumericEntry.read("255") == .value(255))
        #expect(NumericEntry.read(" 227.5 ") == .value(227.5))
        #expect(NumericEntry.read("227,5") == .value(227.5))
        #expect(NumericEntry.read("2.") == .value(2))
        #expect(NumericEntry.read("") == .empty)
        #expect(NumericEntry.read("  ") == .empty)
        // On the way to a number: must not be read as zero.
        #expect(NumericEntry.read(".") == .partial)
        #expect(NumericEntry.read("-5") == .partial)
        #expect(NumericEntry.read("abc") == .partial)
    }

    /// The bug this exists for: the ± buttons changed the stored value while
    /// the field kept its old text, and leaving the field wrote the old text
    /// back. A step has to start from what is on screen.
    @Test("A step starts from what's typed, not from what was stored")
    func stepsFromTheText() {
        #expect(NumericEntry.stepped(text: "255", value: 275, suggestion: nil, by: 2.5) == 257.5)
        #expect(NumericEntry.stepped(text: "255", value: 275, suggestion: nil, by: -2.5) == 252.5)
    }

    @Test("With nothing typed, a step starts from the value, then the suggestion, then zero")
    func stepFallbacks() {
        #expect(NumericEntry.stepped(text: "", value: 275, suggestion: 225, by: 2.5) == 277.5)
        #expect(NumericEntry.stepped(text: "", value: nil, suggestion: 225, by: 2.5) == 227.5)
        #expect(NumericEntry.stepped(text: "", value: nil, suggestion: nil, by: 2.5) == 2.5)
        #expect(NumericEntry.stepped(text: ".", value: 100, suggestion: nil, by: 1) == 101)
    }

    @Test("A step never goes below zero, and repeated steps stay clean")
    func stepBounds() {
        #expect(NumericEntry.stepped(text: "1", value: nil, suggestion: nil, by: -2.5) == 0)
        var weight = 124.7
        for _ in 0..<40 { weight = NumericEntry.stepped(text: "", value: weight, suggestion: nil, by: 2.5) }
        #expect(NumericEntry.format(weight, fractionDigits: 2) == "224.7")
    }

    @Test("Formatting drops trailing zeros and never groups thousands")
    func formatting() {
        #expect(NumericEntry.format(225, fractionDigits: 2) == "225")
        #expect(NumericEntry.format(227.5, fractionDigits: 2) == "227.5")
        #expect(NumericEntry.format(5, fractionDigits: 0) == "5")
        // "1,000" would not parse back as a thousand.
        #expect(NumericEntry.format(1000, fractionDigits: 2) == "1000")
        #expect(NumericEntry.format(nil, fractionDigits: 2) == "")
    }
}
