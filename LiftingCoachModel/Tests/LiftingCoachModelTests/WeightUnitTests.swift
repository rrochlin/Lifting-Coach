import Foundation
import Testing
@testable import LiftingCoachModel

@Suite("Weight units")
struct WeightUnitTests {

    @Test("A weight already in the lifter's unit is left exactly alone")
    func noConversionWhenUnitsMatch() {
        let weight = Measurement(value: 157.5, unit: UnitMass.pounds)

        // Not just equal-ish: rounding a weight that needed no conversion would
        // be a silent edit to a number the lifter typed.
        #expect(weight.expressed(in: .pounds).value == 157.5)
        #expect(weight.expressed(in: .pounds).unit == UnitMass.pounds)
    }

    @Test("Reading a pound entry in kilograms converts it")
    func convertsToKilograms() {
        let converted = Measurement(value: 225, unit: UnitMass.pounds).expressed(in: .kilograms)

        #expect(converted.unit == UnitMass.kilograms)
        #expect(converted.value == 102.1)
    }

    @Test("Conversion rounds to a tenth, so a readout stays readable")
    func roundsForDisplayAndEditing() {
        // The tracker's weight field both displays and writes this number, and
        // Home reads two of them side by side. At full precision 315 lb is
        // 142.88164 kg — digits that can't be loaded, that wrap a readout onto
        // two lines, and that get written back on the first edit.
        let converted = Measurement(value: 315, unit: UnitMass.pounds).expressed(in: .kilograms)
        #expect(converted.value == 142.9)

        // Still lands back on the bar within a rounding error far smaller than
        // the smallest plate.
        let back = converted.expressed(in: .pounds)
        #expect(abs(back.value - 315) < 0.3)
    }

    @Test("Only the two units a bar is loaded in are preferences")
    func onlyLiftingUnits() {
        #expect(WeightUnit(.pounds) == .pounds)
        #expect(WeightUnit(.kilograms) == .kilograms)
        // Grams are a real UnitMass and not a plausible answer to "what do you
        // load your bar in" — hence a two-case enum rather than all of UnitMass.
        #expect(WeightUnit(.grams) == nil)
    }

    @Test("Raw values match the symbols weights are stored under")
    func symbolsMatchStorage() {
        // The `unit` column of a stored weight and a stored preference have to
        // speak the same language, or a round-trip quietly loses the choice.
        #expect(WeightUnit.pounds.rawValue == UnitMass.pounds.symbol)
        #expect(WeightUnit.kilograms.rawValue == UnitMass.kilograms.symbol)
    }

    @Test("A lifter defaults to pounds")
    func defaultsToPounds() {
        #expect(User(name: "Me", email: "").preferredUnit == .pounds)
    }
}
