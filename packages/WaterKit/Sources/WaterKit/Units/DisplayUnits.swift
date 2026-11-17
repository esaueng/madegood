// Display units for the units setting (docs/PLAN.md §6). WaterKit and every file keep
// SI values (m, m/s); convert with these only when showing a value to the user.
//
// Conversion factors are the exact definitions: 1 nmi = 1852 m, 1 mi = 1609.344 m
// (international mile), 1 h = 3600 s.

/// A unit for showing speeds.
public enum SpeedUnit: String, Sendable, Hashable, Codable, CaseIterable {
    case knots = "kn"
    case kilometresPerHour = "kmh"
    case milesPerHour = "mph"
    case metresPerSecond = "mps"

    /// One unit is `metres` per `seconds`.
    private var metres: Double {
        switch self {
        case .knots: 1852
        case .kilometresPerHour: 1000
        case .milesPerHour: 1609.344
        case .metresPerSecond: 1
        }
    }

    private var seconds: Double {
        switch self {
        case .knots, .kilometresPerHour, .milesPerHour: 3600
        case .metresPerSecond: 1
        }
    }

    /// One of this unit in m/s (1 kn = 1852/3600 m/s).
    public var metresPerSecond: Double { metres / seconds }

    /// The unit's symbol: "kn", "km/h", "mph", "m/s".
    public var symbol: String {
        switch self {
        case .knots: "kn"
        case .kilometresPerHour: "km/h"
        case .milesPerHour: "mph"
        case .metresPerSecond: "m/s"
        }
    }

    /// Converts a speed in m/s to this unit.
    public func fromSI(_ metresPerSecond: Double) -> Double {
        metresPerSecond * seconds / metres
    }

    /// Converts a speed in this unit to m/s.
    public func toSI(_ value: Double) -> Double {
        value * metres / seconds
    }

    /// A speed in m/s, ready to show: one decimal below 100 (12.3 kn), whole numbers above.
    public func display(_ metresPerSecond: Double) -> DisplayQuantity {
        DisplayQuantity.rounded(fromSI(metresPerSecond), symbol: symbol) { magnitude in magnitude < 100 ? 1 : 0 }
    }
}

/// A unit system for showing distances.
public enum DistanceUnit: String, Sendable, Hashable, Codable, CaseIterable {
    /// Metres below 1 km, kilometres from 1 km.
    case metric = "m"
    case nauticalMiles = "nm"
    case statuteMiles = "mi"

    /// One of this unit's main unit in metres (km for `metric`).
    public var metres: Double {
        switch self {
        case .metric: 1000
        case .nauticalMiles: 1852
        case .statuteMiles: 1609.344
        }
    }

    /// The main unit's symbol: "km", "nm", "mi".
    public var symbol: String {
        switch self {
        case .metric: "km"
        case .nauticalMiles: "nm"
        case .statuteMiles: "mi"
        }
    }

    /// Converts a distance in metres to this unit's main unit (km, nm or mi).
    public func fromSI(_ metres: Double) -> Double {
        metres / self.metres
    }

    /// Converts a distance in this unit's main unit (km, nm or mi) to metres.
    public func toSI(_ value: Double) -> Double {
        value * metres
    }

    /// A distance in metres, ready to show. Metric shows whole metres below 1 km
    /// (850 m); every unit then shows two decimals below 10 (1.25 nm), one below 100
    /// (12.5 km) and whole numbers above (125 mi).
    public func display(_ metres: Double) -> DisplayQuantity {
        if self == .metric {
            let shortForm = DisplayQuantity.rounded(metres, symbol: "m") { _ in 0 }
            if !metres.isFinite || abs(shortForm.value) < 1000 { return shortForm }
        }
        return DisplayQuantity.rounded(fromSI(metres), symbol: symbol) { magnitude in
            magnitude < 10 ? 2 : magnitude < 100 ? 1 : 0
        }
    }
}

/// A value converted and rounded for display. Apps that localize number formatting use
/// `value` and `fractionDigits`; `text` is a locale-independent fallback ("12.3 kn").
public struct DisplayQuantity: Sendable, Hashable {
    /// The value in `symbol`'s unit, rounded to `fractionDigits`.
    public var value: Double
    public var fractionDigits: Int
    public var symbol: String

    public init(value: Double, fractionDigits: Int, symbol: String) {
        self.value = value
        self.fractionDigits = fractionDigits
        self.symbol = symbol
    }

    /// The number with "." as the decimal separator, then the symbol. Non-finite values
    /// show as "--".
    public var text: String {
        let number = value.isFinite ? DecimalText.fixed(value, digits: fractionDigits) : "--"
        return "\(number) \(symbol)"
    }

    /// Rounds `value` to the precision `digits` picks for its magnitude. The precision is
    /// chosen again after rounding, so 99.96 shows as "100" rather than "100.0".
    static func rounded(_ value: Double, symbol: String, digits: (Double) -> Int) -> DisplayQuantity {
        guard value.isFinite else { return DisplayQuantity(value: value, fractionDigits: 0, symbol: symbol) }
        var fractionDigits = digits(abs(value))
        var rounded = round(value, fractionDigits)
        let settled = digits(abs(rounded))
        if settled < fractionDigits {
            fractionDigits = settled
            rounded = round(value, fractionDigits)
        }
        return DisplayQuantity(value: rounded == 0 ? 0 : rounded, fractionDigits: fractionDigits, symbol: symbol)
    }

    private static func round(_ value: Double, _ digits: Int) -> Double {
        var scale = 1.0
        for _ in 0..<digits { scale *= 10 }
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }
}
