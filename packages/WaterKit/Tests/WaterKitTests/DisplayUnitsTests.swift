import Testing

@testable import WaterKit

@Suite struct DisplayUnitsTests {
    @Test func speedFactorsAreExact() {
        #expect(SpeedUnit.knots.metresPerSecond == 1852.0 / 3600.0)
        #expect(SpeedUnit.knots.toSI(1) == 1852.0 / 3600.0)
        #expect(SpeedUnit.kilometresPerHour.metresPerSecond == 1000.0 / 3600.0)
        #expect(SpeedUnit.milesPerHour.metresPerSecond == 1609.344 / 3600.0)
        #expect(SpeedUnit.metresPerSecond.metresPerSecond == 1)
    }

    @Test func knownSpeeds() {
        #expect(SpeedUnit.kilometresPerHour.fromSI(10) == 36)
        #expect(SpeedUnit.knots.fromSI(1852) == 3600)
        #expect(SpeedUnit.milesPerHour.fromSI(1609.344) == 3600)
        #expect(SpeedUnit.knots.toSI(3600) == 1852)
        #expect(SpeedUnit.milesPerHour.toSI(3600) == 1609.344)
        #expect(SpeedUnit.metresPerSecond.fromSI(4.2) == 4.2)
        // 10 kn ≈ 18.52 km/h ≈ 11.508 mph.
        let tenKnots = SpeedUnit.knots.toSI(10)
        #expect(abs(SpeedUnit.kilometresPerHour.fromSI(tenKnots) - 18.52) < 1e-12)
        #expect(abs(SpeedUnit.milesPerHour.fromSI(tenKnots) - 11.507_794_480_235_425) < 1e-12)
    }

    @Test func knownDistances() {
        #expect(DistanceUnit.nauticalMiles.toSI(1) == 1852)
        #expect(DistanceUnit.statuteMiles.toSI(1) == 1609.344)
        #expect(DistanceUnit.metric.toSI(1) == 1000)
        #expect(DistanceUnit.nauticalMiles.fromSI(3704) == 2)
        #expect(DistanceUnit.statuteMiles.fromSI(16_093.44) == 10)
        #expect(DistanceUnit.metric.fromSI(1500) == 1.5)
    }

    @Test(arguments: [0, 1e-3, 0.5, 1, 2.572_222, 12.34, 99.9, 1234.5, 1e6])
    func roundTripsThroughSI(value: Double) {
        for unit in SpeedUnit.allCases {
            #expect(abs(unit.toSI(unit.fromSI(value)) - value) <= 1e-12 * max(1, value))
            #expect(abs(unit.fromSI(unit.toSI(value)) - value) <= 1e-12 * max(1, value))
        }
        for unit in DistanceUnit.allCases {
            #expect(abs(unit.toSI(unit.fromSI(value)) - value) <= 1e-12 * max(1, value))
            #expect(abs(unit.fromSI(unit.toSI(value)) - value) <= 1e-12 * max(1, value))
        }
    }

    @Test func symbolsAndRawValuesAreStable() {
        #expect(SpeedUnit.allCases.map(\.symbol) == ["kn", "km/h", "mph", "m/s"])
        #expect(SpeedUnit.allCases.map(\.rawValue) == ["kn", "kmh", "mph", "mps"])
        #expect(DistanceUnit.allCases.map(\.symbol) == ["km", "nm", "mi"])
        #expect(DistanceUnit.allCases.map(\.rawValue) == ["m", "nm", "mi"])
    }

    @Test func speedDisplay() {
        #expect(SpeedUnit.knots.display(SpeedUnit.knots.toSI(5.24)).text == "5.2 kn")
        #expect(SpeedUnit.knots.display(0).text == "0.0 kn")
        #expect(SpeedUnit.kilometresPerHour.display(10).text == "36.0 km/h")
        #expect(SpeedUnit.kilometresPerHour.display(SpeedUnit.kilometresPerHour.toSI(123.4)).text == "123 km/h")
        // 99.96 rounds to 100.0 at one decimal; precision is chosen again after rounding.
        let nearHundred = SpeedUnit.knots.display(SpeedUnit.knots.toSI(99.96))
        #expect(nearHundred.text == "100 kn")
        #expect(nearHundred.value == 100 && nearHundred.fractionDigits == 0)
        #expect(SpeedUnit.metresPerSecond.display(.nan).text == "-- m/s")
    }

    @Test func distanceDisplay() {
        #expect(DistanceUnit.metric.display(0).text == "0 m")
        #expect(DistanceUnit.metric.display(849.6).text == "850 m")
        #expect(DistanceUnit.metric.display(999.4).text == "999 m")
        #expect(DistanceUnit.metric.display(999.6).text == "1.00 km")
        #expect(DistanceUnit.metric.display(1234).text == "1.23 km")
        #expect(DistanceUnit.metric.display(12_345).text == "12.3 km")
        #expect(DistanceUnit.metric.display(123_456).text == "123 km")
        #expect(DistanceUnit.nauticalMiles.display(1852).text == "1.00 nm")
        #expect(DistanceUnit.nauticalMiles.display(185.2).text == "0.10 nm")
        #expect(DistanceUnit.nauticalMiles.display(1852 * 9.996).text == "10.0 nm")
        #expect(DistanceUnit.statuteMiles.display(1609.344 * 150).text == "150 mi")
        let display = DistanceUnit.nauticalMiles.display(1852 * 2.345)
        #expect(display.value == 2.35 && display.fractionDigits == 2 && display.symbol == "nm")
    }
}
