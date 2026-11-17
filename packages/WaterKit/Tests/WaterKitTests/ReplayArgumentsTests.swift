import Testing

@testable import WaterKit

@Suite struct ReplayArgumentsTests {
    private func run(_ arguments: [String]) throws -> ReplayArguments {
        guard case .run(let parsed) = try ReplayArguments.parse(arguments) else {
            Issue.record("expected options, got help")
            return ReplayArguments(path: "")
        }
        return parsed
    }

    @Test func parsesAllOptions() throws {
        let parsed = try run(["track.json", "--sport", "kayak", "--json", "--gpx", "out.gpx"])
        #expect(parsed == ReplayArguments(path: "track.json", sport: .kayak, json: true, gpxPath: "out.gpx"))
    }

    @Test func help() throws {
        #expect(try ReplayArguments.parse(["track.json", "--help"]) == .help)
    }

    // Regression test from the PR #24 review: `--gpx --json` wrote GPX to a file named
    // "--json" and silently dropped JSON output.
    @Test func optionValuesCannotBeOptions() {
        #expect(throws: ReplayArguments.Error.self) { try ReplayArguments.parse(["track.json", "--gpx", "--json"]) }
        #expect(throws: ReplayArguments.Error.self) { try ReplayArguments.parse(["track.json", "--gpx"]) }
        #expect(throws: ReplayArguments.Error.self) { try ReplayArguments.parse(["track.json", "--sport", "--json"]) }
    }

    @Test func dotSlashAllowsADashFileName() throws {
        #expect(try run(["track.json", "--gpx", "./-out.gpx"]).gpxPath == "./-out.gpx")
    }

    @Test func rejectsBadInput() {
        for arguments in [[], ["a", "b"], ["track.json", "--nope"], ["track.json", "--sport", "rowing"]] {
            #expect(throws: ReplayArguments.Error.self) { try ReplayArguments.parse(arguments) }
        }
    }
}
