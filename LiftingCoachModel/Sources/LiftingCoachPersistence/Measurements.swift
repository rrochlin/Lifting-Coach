import Foundation

/// Rebuilds a weight from a stored value and unit symbol.
///
/// Weights are persisted with the unit they were entered in rather than
/// normalized to kilograms, so 185 lb reads back as 185 lb instead of an
/// 83.9-ish decimal that never matches what was actually on the bar.
func measurement(value: Double, symbol: String?) -> Measurement<UnitMass> {
    guard let symbol else { return Measurement(value: value, unit: .kilograms) }

    let unit: UnitMass = switch symbol {
    case UnitMass.pounds.symbol: .pounds
    case UnitMass.kilograms.symbol: .kilograms
    case UnitMass.grams.symbol: .grams
    case UnitMass.ounces.symbol: .ounces
    case UnitMass.stones.symbol: .stones
    // An unrecognized symbol still round-trips as itself; it just won't convert.
    default: UnitMass(symbol: symbol)
    }
    return Measurement(value: value, unit: unit)
}

/// Optional-passthrough variant. Distinctly named because an overload taking
/// `Double?` is ambiguous against the one above at every call site.
func optionalMeasurement(value: Double?, symbol: String?) -> Measurement<UnitMass>? {
    guard let value else { return nil }
    return measurement(value: value, symbol: symbol)
}

/// Rebuilds a set's distance from a stored value and unit symbol.
///
/// Same contract as weights, and for the same reason: a bike ride logged in
/// miles reads back in miles. Only the units a lifter plausibly records
/// distance in are recognized; anything else round-trips as itself.
func optionalDistance(value: Double?, symbol: String?) -> Measurement<UnitLength>? {
    guard let value else { return nil }
    guard let symbol else { return Measurement(value: value, unit: .meters) }

    let unit: UnitLength = switch symbol {
    case UnitLength.miles.symbol: .miles
    case UnitLength.kilometers.symbol: .kilometers
    case UnitLength.meters.symbol: .meters
    case UnitLength.yards.symbol: .yards
    case UnitLength.feet.symbol: .feet
    default: UnitLength(symbol: symbol)
    }
    return Measurement(value: value, unit: unit)
}

/// Rebuilds a set's duration from stored seconds.
///
/// No symbol column to go with it: seconds is the only storage, so there is
/// nothing here to disambiguate.
func optionalDuration(seconds: Double?) -> Measurement<UnitDuration>? {
    guard let seconds else { return nil }
    return Measurement(value: seconds, unit: .seconds)
}
