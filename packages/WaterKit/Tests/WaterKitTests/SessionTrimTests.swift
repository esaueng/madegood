import Foundation
import Testing

@testable import WaterKit

@Suite struct SessionTrimTests {
    private static func fix(_ t: Double, speed: Double = 2) -> GPSFix {
        GPSFix(
            t: t, latitude: 0, longitude: t * 0.000_01, altitude: 3,
            horizontalAccuracy: 3, speed: speed, course: 90)
    }

    private static func session(
        gps: [GPSFix] = [], hr: [HRSample] = [], events: [SessionEvent] = [], end: Double? = nil
    ) -> RawSession {
        let meta = RawSessionReaderTests.meta(endedAt: end.map { RawSessionReaderTests.startUnix + $0 })
        return RawSession(meta: meta, gps: gps, hr: hr, events: events)
    }

    private static let sailing = SportProfile.standard(for: .sailing)

    @Test func bothBoundariesKeepExactSamplesAndWallClockTimes() throws {
        let raw = Self.session(
            gps: [1, 1.5, 2, 3.5, 4].map { Self.fix($0, speed: $0 == 1 || $0 == 4 ? 20 : 2) },
            hr: zip([1, 1.5, 2, 3.5, 4], [170, 70, 80, 90, 180]).map(HRSample.init),
            events: [
                SessionEvent(t: 1, type: .mark),
                SessionEvent(t: 1.5, type: .mark, data: ["n": 1]),
                SessionEvent(t: 3.5, type: .lap),
                SessionEvent(t: 3.5, type: "custom", data: ["n": 2]),
                SessionEvent(t: 4, type: .mark),
                SessionEvent(t: 5, type: .stop),
            ])
        let trim = try SessionTrim(start: 1.5, end: 3.5)
        let selected = try SessionSelection(session: raw, trim: trim, profile: Self.sailing)
        let track = selected.track
        let metrics = selected.replay.metrics

        #expect(track.sessionId == raw.meta.sessionId && track.sport == raw.meta.sport)
        #expect(track.startedAt == raw.startedAt.addingTimeInterval(1.5))
        #expect(track.gps.map(\.t) == [0, 0.5, 2])
        #expect(track.gps.map(\.longitude) == raw.gps[1...3].map(\.longitude))
        #expect(track.gps.map(\.altitude) == [3, 3, 3])
        #expect(track.hr == [HRSample(t: 0, bpm: 70), HRSample(t: 0.5, bpm: 80), HRSample(t: 2, bpm: 90)])
        #expect(
            track.events == [
                SessionEvent(t: 0, type: .start),
                SessionEvent(t: 0, type: .mark, data: ["n": 1]),
                SessionEvent(t: 2, type: .lap),
                SessionEvent(t: 2, type: "custom", data: ["n": 2]),
                SessionEvent(t: 2, type: .stop),
            ])
        #expect(metrics.elapsed == 2 && metrics.movingTime == 2 && metrics.isFinished)
        #expect(metrics.distance > 2 && metrics.distance < 2.3)
        #expect(metrics.maxSpeed2s == 2 && metrics.maxSpeed10s == nil)
        #expect(metrics.heartRateAverage == 80 && metrics.heartRateMax == 90)
        #expect(metrics.laps.map(\.end) == [2])
        #expect(track.summary == selected.replay.summary)
        #expect(SessionReplay(track: track, profile: Self.sailing).metrics == metrics)

        let writer = GPXWriter()
        let exported = writer.segments(of: track).flatMap { $0 }
        let exportTimes = exported.map { track.startedAt.addingTimeInterval($0.t) }
        #expect(exportTimes == raw.gps[1...3].map { raw.startedAt.addingTimeInterval($0.t) })
        let xml = writer.string(for: track)
        #expect(xml.components(separatedBy: "<trkpt ").count - 1 == 3)
        #expect(xml.contains("<time>\(Timestamp.format(exportTimes[2]))</time>"))
    }

    @Test func selectedGPXPreservesOriginalTimesAtMillisecondBoundaries() throws {
        var raw = Self.session(gps: [Self.fix(0), Self.fix(0.004), Self.fix(0.009), Self.fix(0.02)])
        raw.meta.startedAt = 1_793_700_000
        let trim = try SessionTrim(start: 0.000_138_749, end: 0.01)
        let selection = try SessionSelection(session: raw, trim: trim)
        let writer = GPXWriter()
        let original = writer.string(for: raw.track())
        let selected = String(decoding: writer.data(for: selection), as: UTF8.self)

        // Compare entire point records, including precise times, for only the retained fixes.
        let originalPoints = original.split(separator: "\n").filter { $0.contains("<trkpt ") }
        let selectedPoints = selected.split(separator: "\n").filter { $0.contains("<trkpt ") }
        #expect(selectedPoints == Array(originalPoints[1...2]))
    }

    @Test func carriesManualPauseAcrossTheOpeningBoundary() throws {
        let raw = Self.session(
            gps: (0...9).map { Self.fix(Double($0)) },
            events: [SessionEvent(t: 1.5, type: .pause), SessionEvent(t: 6, type: .resume)])
        let trim = try SessionTrim(start: 3, end: 8.5)
        let selected = try SessionSelection(session: raw, trim: trim, profile: Self.sailing)
        #expect(selected.track.events.filter { $0.type == .pause } == [SessionEvent(t: 0, type: .pause)])
        #expect(selected.replay.metrics.movingTime == 1)
        #expect(selected.replay.metrics.elapsed == 5.5)
        #expect(GPXWriter().segments(of: selected.track).map { $0.map(\.t) } == [[0, 1, 2], [3, 4, 5]])

        let paused = try SessionSelection(session: raw, trim: SessionTrim(start: 3, end: 5), profile: Self.sailing)
        #expect(paused.replay.metrics.movingTime == 0 && paused.replay.metrics.distance == 0)
        let resumed = try SessionSelection(session: raw, trim: SessionTrim(start: 6, end: 8), profile: Self.sailing)
        #expect(resumed.replay.metrics.movingTime == 2)
        #expect(resumed.track.events.map(\.type) == [.start, .resume, .stop])
    }

    @Test func recomputesAutoPauseWithTheSelectedProfileAndFixes() throws {
        let raw = Self.session(
            gps: (0...9).map { Self.fix(Double($0), speed: $0 < 6 ? 0.1 : 2) },
            events: [
                SessionEvent(t: 0, type: .pause, data: ["auto": true]),
                SessionEvent(t: 1, type: .lap, data: ["auto": true]),
                SessionEvent(t: 6, type: .resume, data: ["auto": true]),
            ])
        var profile = SportProfile.standard(for: .kayak)
        profile.autoPause.pauseAfter = 2
        profile.autoPause.resumeAfter = 1
        let trim = try SessionTrim(start: 2, end: 8)
        let selected = try SessionSelection(session: raw, trim: trim, profile: profile)
        let autoEvents = selected.track.events.filter { $0.data?["auto"] == .bool(true) }
        #expect(autoEvents.map(\.type) == [.pause, .resume])
        #expect(autoEvents.map(\.t) == [0, 3])
        #expect(selected.replay.metrics.movingTime == 3)
        #expect(GPXWriter().segments(of: selected.track).map { $0.map(\.t) } == [[0, 1, 2], [3, 4, 5, 6]])

        profile.autoPause.enabled = false
        let disabled = try SessionSelection(session: raw, trim: trim, profile: profile)
        #expect(disabled.replay.metrics.movingTime == 6)
        #expect(disabled.track.events.map(\.type) == [.start, .stop])
    }

    @Test func subsecondAndSampleFreeSelectionsKeepTheirElapsedTime() throws {
        let raw = Self.session(gps: [Self.fix(0.5)], end: 1)
        let short = try SessionSelection(session: raw, trim: SessionTrim(start: 0.25, end: 0.875))
        #expect(short.track.gps.map(\.t) == [0.25])
        #expect(short.replay.metrics.elapsed == 0.625 && short.replay.metrics.isFinished)
        #expect(short.replay.metrics.maxSpeed2s == nil && short.replay.metrics.distance == 0)

        let quiet = try SessionSelection(session: raw, trim: SessionTrim(start: 0.625, end: 1))
        #expect(quiet.replay.metrics.elapsed == 0.375 && quiet.replay.metrics.movingTime == 0)
        #expect(GPXWriter().segments(of: quiet.track).isEmpty)
    }

    @Test func originalDisplayClockIncludesTheQuietTailOfAnEventlessRecording() throws {
        let raw = Self.session(gps: [Self.fix(4), Self.fix(5), Self.fix(8)], end: 10)
        let original = try SessionSelection(session: raw)
        let timeline = SessionReplayTimeline(
            replay: original.replay, recordedFixes: original.track.gps, endTime: original.duration)
        #expect(SessionTrim.availableEnd(in: raw) == 10)
        #expect(original.duration == 10)
        #expect(original.replay.metrics.elapsed == 8)
        #expect(timeline.selection(at: 10).elapsed == 10)
        #expect(timeline.selection(at: 10).position == nil)

        let shorter = try SessionSelection(session: raw, trim: SessionTrim(start: 0, end: 9))
        #expect(shorter.duration == 9)

        let betweenFixes = try SessionSelection(session: raw, trim: SessionTrim(start: 4.2, end: 4.8))
        let kept = SessionReplayTimeline(replay: betweenFixes.replay, recordedFixes: betweenFixes.track.gps)
        #expect(kept.points.isEmpty)
        #expect(GPXWriter().segments(of: betweenFixes.track).isEmpty)
    }

    @Test(arguments: [(-1.0, 1.0), (2, 1), (1, 1), (.nan, 1), (0, .infinity)])
    func rejectsInvalidBounds(start: Double, end: Double) {
        #expect(throws: SessionTrim.Error.invalidBounds) { try SessionTrim(start: start, end: end) }
    }

    @Test func boundsRespectTheAvailableRecording() throws {
        let trim = try SessionTrim(start: 0, end: 2)
        let stopped = Self.session(gps: [Self.fix(3)], events: [SessionEvent(t: 1, type: .stop)], end: 3)
        #expect(throws: SessionTrim.Error.exceedsRecording(availableEnd: 1)) {
            try SessionSelection(session: stopped, trim: trim)
        }
        #expect(throws: SessionTrim.Error.exceedsRecording(availableEnd: 0)) {
            try SessionSelection(session: Self.session(), trim: trim)
        }
    }

    @Test func interruptedRecordingCanReplaceAndRestoreWithoutChangingSourceFiles() throws {
        let root = try TempFolder()
        let folder = root.url.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let start = RawSessionReaderTests.startUnix
        let meta = RawSessionReaderTests.meta(endedAt: nil)
        var gps = try lines([
            RawFormat.GPSLine(ts: start + 0.25, lat: 0, lon: 0, hacc: 3, spd: 2),
            RawFormat.GPSLine(ts: start + 0.5, lat: 0, lon: 0.000_01, hacc: 3, spd: 2),
        ])
        gps.append(Data("{\"ts\":".utf8))
        let source = [RawFormat.metaFileName: try RawFormat.encodeMeta(meta), "gps.ndjson": gps]
        for (name, data) in source { try data.write(to: folder.appendingPathComponent(name)) }
        let raw = try RawSessionReader.read(folder: folder, includeMotion: false)
        #expect(raw.issues.map(\.kind) == [.truncatedLine])
        #expect(SessionTrim.availableEnd(in: raw) == 0.5)

        let directory = root.url.appendingPathComponent("SessionEdits")
        let store = SessionTrimStore(directory: directory)
        #expect(try store.load(sessionId: meta.sessionId) == nil)
        let first = try SessionTrim(start: 0.25, end: 0.5)
        try store.save(first, for: raw)
        #expect(try store.load(sessionId: meta.sessionId) == first)
        let replacement = try SessionTrim(start: 0.125, end: 0.25)
        try store.save(replacement, for: raw)
        let loaded = try SessionTrimStore(directory: directory).load(sessionId: meta.sessionId)
        #expect(loaded == replacement)
        let selected = try SessionSelection(session: raw, trim: loaded)
        #expect(selected.track.gps.map(\.t) == [0.125])
        #expect(selected.track.startedAt == raw.startedAt.addingTimeInterval(0.125))
        #expect(throws: SessionTrim.Error.exceedsRecording(availableEnd: 0.5)) {
            try store.save(SessionTrim(start: 0, end: 1), for: raw)
        }
        #expect(try store.load(sessionId: meta.sessionId) == replacement)

        try store.restoreOriginal(sessionId: meta.sessionId)
        try store.restoreOriginal(sessionId: meta.sessionId)
        let restored = try SessionSelection(session: raw, trim: store.load(sessionId: meta.sessionId))
        let original = raw.track()
        #expect(restored.track == original)
        #expect(restored.replay.metrics == SessionReplay(track: original).metrics)
        #expect(GPXWriter().data(for: restored.track) == GPXWriter().data(for: original))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == Set(source.keys))
        for (name, data) in source { #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == data) }
    }

    @Test func unknownEditVersionIsReportedAndItsBytesArePreserved() throws {
        let folder = try TempFolder()
        let id = RawSessionReaderTests.meta().sessionId
        let name = id.uuidString.lowercased() + ".json"
        let data = Data(#"{"version":3}"#.utf8)
        try folder.write(name, data)
        let store = SessionTrimStore(directory: folder.url)
        #expect(throws: SessionTrimStore.Error.unsupportedVersion(3)) { try store.load(sessionId: id) }
        #expect(try Data(contentsOf: folder.url.appendingPathComponent(name)) == data)
    }

    @Test func shortCutResetsDistanceAndSpeedAndKeepsBothBoundaryFixes() throws {
        let times = [0.0, 1, 2, 2.25, 2.5, 3.5, 4.5]
        let gps = times.map { t in
            var fix = Self.fix(t, speed: t < 2.5 ? 2 : 8)
            if t >= 2.5 { fix.longitude += 0.01 }
            return fix
        }
        let raw = Self.session(
            gps: gps, hr: times.map { HRSample(t: $0, bpm: $0 == 2.25 ? 200 : 100) },
            events: [2.0, 2.25, 2.5].map { SessionEvent(t: $0, type: .mark) }, end: 5)
        let trim = try SessionTrim(start: 1, end: 5, removing: [2...2.5])
        let selected = try SessionSelection(session: raw, trim: trim, profile: Self.sailing)
        let timeline = SessionReplayTimeline(replay: selected.replay, recordedFixes: selected.track.gps)
        let left = try SessionSelection(session: raw, trim: SessionTrim(start: 1, end: 2), profile: Self.sailing)
        let right = try SessionSelection(session: raw, trim: SessionTrim(start: 2.5, end: 5), profile: Self.sailing)

        #expect(selected.retainedRanges == [1...2, 2.5...5])
        #expect(selected.replayRanges == [0...1, 1.5...4])
        #expect(selected.sourceTime(forReplayTime: 1.5) == 2.5)
        #expect(selected.replayTime(forSourceTime: 2) == 1)
        #expect(selected.duration == 4 && selected.retainedDuration == 3.5)
        #expect(selected.replay.fixSpans.map { $0.map(\.t) } == [[0, 1], [1.5, 2.5, 3.5]])
        #expect(selected.replay.metrics.rejectedFixes == 0)
        #expect(selected.replay.metrics.distance == left.replay.metrics.distance + right.replay.metrics.distance)
        #expect(selected.replay.metrics.movingTime == 3)
        #expect(selected.replay.metrics.maxSpeed2s == 8)
        #expect(selected.replay.metrics.maxSpeed2sRange == 1.5...3.5)
        #expect(selected.replay.metrics.maxSpeed10s == nil)
        #expect(selected.replay.metrics.heartRateMax == 100)
        #expect(selected.replay.events.filter { $0.type == .mark }.map(\.t) == [1, 1.5])
        #expect(selected.replay.metrics.laps.map(\.end) == [1])
        #expect(selected.replay.metrics.currentLap.start == 1.5)

        #expect(timeline.points.map(\.routeSegment) == [0, 0, 1, 1, 1])
        #expect(timeline.selection(at: 1.25, speedWindow: 0...2).position == nil)
        #expect(timeline.selection(at: 1.25, speedWindow: 0...2).speed == nil)
        #expect(timeline.selection(at: 1).position != nil && timeline.selection(at: 1.5).position != nil)
        #expect(timeline.selection(at: 1).routeDistance == timeline.selection(at: 1.5).routeDistance)
        #expect(timeline.speedCurve(in: 0...2).isEmpty)
        #expect(timeline.speedCurve(in: 1.5...3.5).map(\.speed) == [8, 8, 8])

        let writer = GPXWriter()
        let selectedGPX = String(decoding: writer.data(for: selected), as: UTF8.self)
        #expect(writer.segments(of: selected).map { $0.map(\.t) } == [[0, 1], [1.5, 2.5, 3.5]])
        #expect(selectedGPX.contains(#"<mg:removedInterval start="1.0" end="1.5"/>"#))
        let originalPoints = writer.string(for: raw.track()).split(separator: "\n").filter { $0.contains("<trkpt ") }
        let selectedPoints = selectedGPX.split(separator: "\n").filter { $0.contains("<trkpt ") }
        #expect(selectedPoints == [1, 2, 4, 5, 6].map { originalPoints[$0] })
    }

    @Test(arguments: [2, 10])
    func bestSpeedCannotSpanCutEvenWhenBothSidesHaveDoppler(window: Int) throws {
        let end = Double(window) + 0.5
        let cut = (end / 2 - 0.25)...(end / 2 + 0.25)
        let times = [0, cut.lowerBound, cut.upperBound, end]
        let raw = Self.session(gps: times.map { Self.fix($0) }, end: end)
        let trim = try SessionTrim(start: 0, end: end, removing: [cut])
        let original = try SessionSelection(session: raw, profile: Self.sailing)
        let selected = try SessionSelection(session: raw, trim: trim, profile: Self.sailing)
        if window == 2 {
            #expect(original.replay.metrics.maxSpeed2s == 2)
            #expect(selected.replay.metrics.maxSpeed2s == nil)
        } else {
            #expect(original.replay.metrics.maxSpeed10s == 2)
            #expect(selected.replay.metrics.maxSpeed10s == nil)
        }
    }

    @Test func manualPauseStateIsReadFromSourceAtEachSpan() throws {
        let raw = Self.session(
            gps: (0...12).map { Self.fix(Double($0)) },
            events: [
                SessionEvent(t: 1, type: .pause),
                SessionEvent(t: 3, type: .resume),  // Removed; the right span starts moving.
                SessionEvent(t: 6, type: .pause),  // Removed; the next span starts paused.
                SessionEvent(t: 9, type: .resume),
                SessionEvent(t: 11, type: .pause),
                SessionEvent(t: 11, type: .resume),
            ], end: 12)
        let trim = try SessionTrim(start: 0, end: 12, removing: [2...4, 5...7, 10...11])
        let selected = try SessionSelection(session: raw, trim: trim, profile: Self.sailing)

        #expect(selected.replay.metrics.movingTime == 3)  // 0–1, 4–5 and 11–12.
        #expect(selected.track.events.filter { $0.type == .pause }.map(\.t) == [1, 7, 11])
        #expect(selected.track.events.filter { $0.type == .resume }.map(\.t) == [9, 11])
        #expect(selected.replay.fixSpans.map { $0.map(\.t) } == [[0, 1, 2], [4, 5], [7, 8, 9, 10], [11, 12]])
    }

    @Test func emptyAcceptedSpanRetainsItsClockAndBothCuts() throws {
        var rejected = Self.fix(3)
        rejected.latitude = 91
        let raw = Self.session(gps: [Self.fix(1), rejected, Self.fix(5)], end: 6)
        let trim = try SessionTrim(retaining: [0...1, 2...3, 4...6])
        let selected = try SessionSelection(session: raw, trim: trim, profile: Self.sailing)
        let timeline = SessionReplayTimeline(replay: selected.replay, recordedFixes: selected.track.gps)
        #expect(selected.replay.fixSpans.map(\.count) == [1, 0, 1])
        #expect(selected.replay.removedIntervals == [1...2, 3...4])
        #expect(selected.replay.metrics.rejectedFixes == 1)
        #expect(selected.replay.metrics.distance == 0)
        #expect(selected.retainedDuration == 4)
        #expect(timeline.points.map(\.routeSegment) == [0, 1])
        #expect(timeline.selection(at: 3).position == nil)
        let writer = GPXWriter()
        #expect(writer.segments(of: selected).map { $0.map(\.t) } == [[1], [5]])
        let gpx = String(decoding: writer.data(for: selected), as: UTF8.self)
        #expect(gpx.components(separatedBy: "<mg:removedInterval").count - 1 == 2)
    }

    @Test func readsLegacyAndVersionTwoSidecarsAndRestoresOriginal() throws {
        let raw = Self.session(gps: (0...6).map { Self.fix(Double($0)) }, end: 6)
        let folder = try TempFolder()
        let id = raw.meta.sessionId
        let name = id.uuidString.lowercased() + ".json"
        try folder.write(name, Data(#"{"version":1,"start":1,"end":6}"#.utf8))
        let store = SessionTrimStore(directory: folder.url)
        #expect(try store.load(sessionId: id)?.retainedRanges == [1...6])
        let trimmed = try SessionTrim(retaining: [1...2, 3...4, 5...6])
        try store.save(trimmed, for: raw)
        let sidecar = try Data(contentsOf: folder.url.appendingPathComponent(name))
        let json = try #require(JSONSerialization.jsonObject(with: sidecar) as? [String: Any])
        #expect(json["version"] as? Int == 2)
        #expect((json["keptSpans"] as? [[String: Double]])?.map { $0["start"] } == [1, 3, 5])
        #expect(try store.load(sessionId: id) == trimmed)
        try store.restoreOriginal(sessionId: id)
        let restored = try SessionSelection(session: raw, trim: store.load(sessionId: id))
        #expect(restored.track == raw.track())
        #expect(restored.replay.removedIntervals.isEmpty)
        #expect(throws: SessionTrim.Error.invalidRemoval) { try SessionTrim(retaining: [1...3, 3...4]) }
    }
}
