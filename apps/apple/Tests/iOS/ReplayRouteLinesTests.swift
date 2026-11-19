import CoreLocation
import XCTest

@testable import MadeGood

final class ReplayRouteLinesTests: XCTestCase {
    private typealias Line = SessionReplayView.Data.RouteLine

    /// Lines the way `Data` builds them: each starts at the previous line's last fix.
    private func run(levels: [Int], pointsEach: Int = 1, segment: Int = 0, from start: Int = 0) -> [Line] {
        var fix = start
        return levels.map { level in
            let coordinates = (fix...(fix + pointsEach)).map {
                CLLocationCoordinate2D(latitude: 0, longitude: Double($0) * 0.0001)
            }
            fix += pointsEach
            return Line(level: level, coordinates: coordinates, segment: segment)
        }
    }

    private func fixes(_ lines: [Line]) -> [Double] {
        lines.enumerated().flatMap { index, line in
            (index == 0 || lines[index - 1].segment != line.segment ? line.coordinates : Array(line.coordinates.dropFirst()))
                .map(\.longitude)
        }
    }

    /// The CI crash: a noisy speed trace gave the map one polyline per color change.
    func testNoisySpeedTraceStaysUnderTheLineLimit() {
        let noisy = run(levels: (0..<1_500).map { $0 % 2 == 0 ? 1 : 4 })
        let lines = SessionReplayView.Data.simplified(noisy, maxCount: 64)
        XCTAssertLessThanOrEqual(lines.count, 64)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(fixes(lines), fixes(noisy), "every fix stays on the route, once")
    }

    func testEachLineTakesTheColorCoveringMostOfIt() {
        // Mostly fast with brief slow blips: the joined lines stay fast.
        let noisy = run(levels: (0..<300).map { $0 % 5 == 0 ? 0 : 4 })
        let lines = SessionReplayView.Data.simplified(noisy, maxCount: 10)
        XCTAssertLessThanOrEqual(lines.count, 10)
        XCTAssertEqual(Set(lines.map(\.level)), [4])
    }

    func testFewLinesAreLeftAlone() {
        let lines = run(levels: [0, 3, 1, 4], pointsEach: 1)
        let simplified = SessionReplayView.Data.simplified(lines, maxCount: 64)
        XCTAssertEqual(simplified.map(\.level), [0, 3, 1, 4])
        XCTAssertEqual(simplified.map(\.coordinates.count), lines.map(\.coordinates.count))
    }

    func testShortRunsTakeTheLongerNeighborsColor() {
        // A long slow run, a one-fix blip of fast, then a long medium run.
        let lines = run(levels: [0], pointsEach: 40) + run(levels: [4], from: 40) + run(levels: [2], pointsEach: 40, from: 41)
        let simplified = SessionReplayView.Data.simplified(lines, maxCount: 2)
        XCTAssertEqual(simplified.map(\.level), [0, 2])
        XCTAssertEqual(fixes(simplified), fixes(lines))
    }

    func testSeparateGPSRunsNeverJoin() {
        let first = run(levels: (0..<50).map { $0 % 5 }, segment: 0)
        let second = run(levels: (0..<50).map { $0 % 5 }, segment: 1, from: 100)
        let simplified = SessionReplayView.Data.simplified(first + second, maxCount: 1)
        XCTAssertEqual(simplified.map(\.segment), [0, 1], "a gap in the GPS stays a gap")
        XCTAssertEqual(fixes(simplified), fixes(first + second))
    }
}
