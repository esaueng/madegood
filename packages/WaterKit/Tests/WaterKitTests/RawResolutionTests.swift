import Foundation
import Testing

@testable import WaterKit

/// Writers round raw values to `RawFormat.Resolution` (docs/formats.md, "Resolution"):
/// the numbers must print short, and analysis must not change.
@Suite struct RawResolutionTests {
    static let start = 1_809_165_600.0

    static func text(_ line: some Encodable) throws -> String {
        String(decoding: try RawFormat.line(line), as: UTF8.self)
    }

    /// No number in `text` has eight or more digits after the point, or an exponent.
    static func expectShortNumbers(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(
            text.range(of: #"\.[0-9]{8,}"#, options: .regularExpression) == nil, "\(text)",
            sourceLocation: sourceLocation)
        #expect(
            text.range(of: #"[0-9][eE]"#, options: .regularExpression) == nil, "\(text)", sourceLocation: sourceLocation
        )
    }

    // MARK: Rounding

    @Test func roundingDividesByAnExactPowerOfTen() {
        #expect(RawFormat.round(0.07949749774802475, to: 1e-3) == 0.079)
        #expect("\(RawFormat.round(0.07949749774802475, to: 1e-3))" == "0.079")
        // Why it divides: multiplying by the step leaves a long tail.
        #expect("\(9 * 0.001)" == "0.009000000000000001")
        #expect("\(RawFormat.round(0.0090004, to: 1e-3))" == "0.009")
        #expect(RawFormat.round(0.000_030_4, to: 1e-5) == 0.00003)
        #expect(RawFormat.round(230.787109375, to: 0.1) == 230.8)
        #expect(RawFormat.round(-9.806649999, to: 1e-3) == -9.807)
        #expect(RawFormat.round(12.5, to: 1) == 13)
    }

    /// The scaling product can be off by one ulp, so a value a hair from a half step may
    /// round the other way; the result is still within half a step plus 1e-14 relative.
    @Test func roundingErrorStaysWithinHalfAStepAtRealMagnitudes() {
        var random = SplitMix64(seed: 3)
        let cases: [(step: Double, magnitude: Double)] = [
            (RawFormat.Resolution.acceleration, 160), (RawFormat.Resolution.rotationRate, 35),
            (RawFormat.Resolution.attitude, 1), (RawFormat.Resolution.heading, 360),
        ]
        for (step, magnitude) in cases {
            var worst: Double = 0
            for _ in 0..<20_000 {
                let unit: Double = random.unit() * 2 - 1
                let value: Double = unit * magnitude
                let error: Double = abs(RawFormat.round(value, to: step) - value)
                let allowed: Double = step / 2 + 1e-14 * magnitude
                worst = max(worst, error / allowed)
            }
            #expect(worst <= 1, "step \(step)")
        }
    }

    @Test func roundingEdgeCases() {
        let negativeZero = RawFormat.round(-0.000_4, to: 1e-3)
        #expect(negativeZero == 0 && negativeZero.sign == .plus)
        #expect(RawFormat.round(.nan, to: 1e-3).isNaN)
        #expect(RawFormat.round(1e300, to: 1e-3) == 1e300)
        #expect(RawFormat.round(-1e300, to: 1e-3) == -1e300)
    }

    // MARK: Lines

    @Test func motionLinesAreRoundedToTheirResolution() throws {
        let line = RawFormat.MotionLine(
            ts: Self.start + 12.345_678_912_3,
            userAcceleration: Vector3(x: 0.079_497_497_748_024_75, y: -36.123_456_789, z: 0.000_000_1),
            gravity: Vector3(x: 0.009_000_4, y: -9.806_649_999_9, z: 0.123_456_789),
            rotationRate: Vector3(x: 1.234_567_89, y: -0.000_049_9, z: 16.999_999_9),
            attitude: Quaternion(x: 0.707_106_781_186_547_5, y: -0.000_003_33, z: 0.1, w: -0.707_106_781_186_547_5))
        let text = try Self.text(line)
        Self.expectShortNumbers(text)
        for part in [
            #""ax":0.079"#, #""ay":-36.123"#, #""az":0"#, #""gx":0.009"#,
            #""gy":-9.807"#, #""gz":0.123"#, #""rx":1.2346"#, #""ry":0"#, #""rz":17"#, #""qx":0.70711"#,
            #""qy":0"#, #""qz":0.1"#, #""qw":-0.70711"#,
        ] {
            let key = String(part.prefix(5))
            let number = try #require(text.range(of: key + #"-?[0-9.]+"#, options: .regularExpression))
            let expected = Double(part.dropFirst(5))!
            #expect(Double(text[number].dropFirst(5)) == expected, "\(part) in \(text)")
        }
        let decoded = try JSONDecoder().decode(RawFormat.MotionLine.self, from: Data(text.utf8))
        typealias R = RawFormat.Resolution
        #expect(decoded.ts == line.ts)
        #expect(decoded.ax == 0.079 && decoded.gy == -9.807 && decoded.rx == 1.2346 && decoded.qw == -0.70711)
        #expect(decoded.az == 0 && decoded.az.sign == .plus)
    }

    @Test func motionLinesStaySmall() throws {
        // A typical sample: 14 values at full double precision were about 346 bytes.
        let line = RawFormat.MotionLine(
            ts: Self.start + 1_234.567_891_234,
            userAcceleration: Vector3(x: -1.234_567_891, y: 2.345_678_912, z: -3.456_789_123),
            gravity: Vector3(x: -4.567_891_234, y: 5.678_912_345, z: -6.789_123_456),
            rotationRate: Vector3(x: -1.234_567_891, y: 2.345_678_912, z: -3.456_789_123),
            attitude: Quaternion(x: -0.123_456_789, y: 0.234_567_891, z: -0.345_678_912, w: 0.456_789_123))
        let data = try RawFormat.line(line)
        #expect(data.count <= 200, "\(data.count) bytes")
    }

    /// Review of #169: rounded GPS changed decisions on replay. A 50.004 m/s fix (over the
    /// 50 m/s limit) read back as 50.00, 0.399 m/s (under auto-pause) as 0.40, and a
    /// 22.001 m jump (over the jump limit) as 21.994 m. GPS is written as reported.
    @Test func gpsLinesAreWrittenAsReported() throws {
        let line = RawFormat.GPSLine(
            ts: Self.start + 1.000_123_4, lat: 47.123_456_789_123, lon: -122.987_654_321_987, alt: 12.345_678,
            hacc: 3.888_888_8, vacc: 4.111_111_1, spd: 1.234_567_8, spdacc: 0.299_999_9, crs: 89.999_999,
            crsacc: 5.050_505)
        let text = try Self.text(line)
        let decoded = try JSONDecoder().decode(RawFormat.GPSLine.self, from: Data(text.utf8))
        #expect(decoded == line)
        // The review's boundary cases come back exactly.
        let speeds: [Double] = [50.004, 0.399]
        for speed in speeds {
            let fix = RawFormat.GPSLine(ts: Self.start, lat: 0, lon: 0.000_000_051, spd: speed, crs: 159.96)
            let reread = try JSONDecoder().decode(RawFormat.GPSLine.self, from: Data(try Self.text(fix).utf8))
            #expect(reread == fix)
        }
        let jump = RawFormat.GPSLine(ts: Self.start, lat: 0, lon: 0.000_197_911)
        let rereadJump = try JSONDecoder().decode(RawFormat.GPSLine.self, from: Data(try Self.text(jump).utf8))
        #expect(rereadJump.lon == 0.000_197_911)
        // Absent optional values stay absent.
        let bare = try Self.text(RawFormat.GPSLine(ts: Self.start, lat: 0.000_123_456_78, lon: 0))
        #expect(!bare.contains("alt") && !bare.contains("spd") && !bare.contains("crs"))
    }

    @Test func headingLinesAreRoundedToATenthOfADegree() throws {
        let text = try Self.text(
            RawFormat.HeadingLine(
                ts: Self.start + 0.019_951_2, mag: 230.787_109_375, trueHeading: 244.212_890_625, acc: 11.637_5))
        Self.expectShortNumbers(text)
        let decoded = try JSONDecoder().decode(RawFormat.HeadingLine.self, from: Data(text.utf8))
        #expect(decoded.ts == Self.start + 0.019_951_2)
        #expect(decoded.mag == 230.8 && decoded.trueHeading == 244.2 && decoded.acc == 11.637_5)
        #expect(text.contains(#""true":244.2"#))
        let noTrue = try Self.text(RawFormat.HeadingLine(ts: Self.start, mag: 1, acc: 2))
        #expect(!noTrue.contains("true"))
    }

    @Test func linesKeepOneKeyOrder() throws {
        let a = try Self.text(RawFormat.HeadingLine(ts: Self.start, mag: 1, trueHeading: 2, acc: 3))
        #expect(a == #"{"acc":3,"mag":1,"true":2,"ts":1809165600}"# + "\n")
        let b = try Self.text(RawFormat.GPSLine(ts: Self.start, lat: 1, lon: 2, hacc: 3, spd: 4))
        #expect(b == #"{"hacc":3,"lat":1,"lon":2,"spd":4,"ts":1809165600}"# + "\n")
    }

    // MARK: Timestamps

    /// Regression: motion `ts` rounded to 1 µs put a sample written just after a clock
    /// anchor onto the anchor itself, and the reader (ties go to the earlier segment)
    /// placed it before a +100 s wall-clock correction.
    @Test func motionJustAfterAClockAnchorStaysAfterIt() throws {
        let temp = try TempFolder()
        let anchorMono: Double = Self.start + 100
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: .kayak, startedAt: Self.start, endedAt: Self.start + 300,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"))
        try temp.write(RawFormat.metaFileName, RawFormat.encodeMeta(meta))
        // The wall clock was corrected 100 s forward at mono `anchorMono`.
        try temp.write("clock.ndjson", RawFormat.line(RawFormat.ClockAnchor(unix: anchorMono + 100, mono: anchorMono)))
        let monos: [Double] = [
            anchorMono - 0.01, anchorMono, anchorMono.nextUp, anchorMono + 0.4e-6, anchorMono + 0.01,
        ]
        var motion = Data()
        for mono in monos {
            motion.append(
                try RawFormat.line(
                    RawFormat.MotionLine(
                        ts: mono, userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -9.80665),
                        rotationRate: .zero, attitude: .identity)))
        }
        try temp.write("motion.ndjson", motion)
        let session = try RawSessionReader.read(folder: temp.url)
        let times: [Double] = session.motion.map(\.t)
        #expect(session.motion.map(\.monotonic) == monos)
        #expect(times.count == 5)
        // Up to and including the anchor: before the correction; after it: 100 s later.
        let expected: [Double] = [99.99, 100, 200, 200, 200.01]
        for (time, want) in zip(times, expected) {
            let difference: Double = abs(time - want)
            #expect(difference < 1e-5, "\(time) vs \(want)")
        }
    }

    @Test func timestampsAreWrittenExactly() throws {
        let ts: Double = Self.start + 0.000_000_3
        let motion = RawFormat.MotionLine(
            ts: ts, userAcceleration: .zero, gravity: .zero, rotationRate: .zero, attitude: .identity)
        let motionText = try Self.text(motion)
        let gpsText = try Self.text(RawFormat.GPSLine(ts: ts, lat: 0, lon: 0))
        let headingText = try Self.text(RawFormat.HeadingLine(ts: ts, mag: 1))
        let decoder = JSONDecoder()
        #expect(try decoder.decode(RawFormat.MotionLine.self, from: Data(motionText.utf8)).ts == ts)
        #expect(try decoder.decode(RawFormat.GPSLine.self, from: Data(gpsText.utf8)).ts == ts)
        #expect(try decoder.decode(RawFormat.HeadingLine.self, from: Data(headingText.utf8)).ts == ts)
    }

    // MARK: Conversion

    /// Review finding: converting a version 1 recording re-encoded its motion lines and
    /// rounded them (0.00049 m/s² became 0), while GPS and heading were copied as they
    /// were. Conversion changes clocks only; every value must come back exactly.
    @Test func convertingVersion1KeepsEveryValueExactly() throws {
        let temp = try TempFolder()
        let v1Folder = temp.url.appendingPathComponent("v1")
        let v2Folder = temp.url.appendingPathComponent("v2")
        try FileManager.default.createDirectory(at: v1Folder, withIntermediateDirectories: true)
        let uptime0: Double = 5_000
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: .kayak, startedAt: Self.start, endedAt: Self.start + 10,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"))
        try RawFormat.V1.encodeMeta(meta, clock: .init(unix: Self.start, uptime: uptime0))
            .write(to: v1Folder.appendingPathComponent(RawFormat.metaFileName))
        var original: [RawFormat.MotionLine] = []
        var random = SplitMix64(seed: 5)
        for index in 0..<200 {
            let t: Double = uptime0 + Double(index) * 0.01 + random.unit() * 1e-4
            let small: Double = 0.000_49 * random.unit()
            let x: Double = random.unit() * 4 - 2
            original.append(
                RawFormat.MotionLine(
                    ts: t, userAcceleration: Vector3(x: small, y: x, z: -x / 3),
                    gravity: Vector3(x: x / 7, y: -9.806_649_9, z: small),
                    rotationRate: Vector3(x: x * 1.000_000_1, y: small, z: 0.123_456_789_012),
                    attitude: Quaternion(x: x / 10, y: 0.707_106_781_186_547_5, z: small, w: -0.707_106_781_186_547_5)))
        }
        var motion = Data()
        for line in original { motion.append(try RawFormat.line(line, exactValues: true)) }
        try motion.write(to: v1Folder.appendingPathComponent(RawFormat.Stream.motion.fileName))

        #expect(try RawFormatConversion.convertToCurrent(folder: v1Folder, into: v2Folder))
        let converted = try Data(contentsOf: v2Folder.appendingPathComponent(RawFormat.Stream.motion.fileName))
        let decoder = JSONDecoder()
        let lines: [RawFormat.MotionLine] = try converted.split(separator: 0x0A).map {
            try decoder.decode(RawFormat.MotionLine.self, from: Data($0))
        }
        #expect(lines.count == original.count)
        for (line, recorded) in zip(lines, original) {
            var expected = recorded
            expected.ts = Self.start + (recorded.ts - uptime0)
            #expect(line == expected)
        }
    }

    // MARK: Accuracy thresholds

    /// Every accuracy limit analysis compares readings with.
    static let accuracyLimits: [Double] = [
        SessionStats.maxHorizontalAccuracy, GPSFilter.Config().maxHorizontalAccuracy, AnchorAlarm.maximumAccuracy,
        StartLineState.venueFixMaxAccuracy, StartLinePingAverager.maximumAccuracy,
        SailingManeuverDetector.axisProximity,
    ]

    /// Regression: `hacc` 25.04 m was written as 25.0 m, so replay accepted a fix the live
    /// filter rejected. Accuracies must come back exactly as reported.
    @Test func accuracyFieldsAreWrittenAsReported() throws {
        for limit in Self.accuracyLimits {
            let below: Double = limit - 0.04
            let above: Double = limit + 0.04
            for value in [below, limit.nextDown, limit, limit.nextUp, above] {
                let gps = RawFormat.GPSLine(
                    ts: Self.start, lat: 1, lon: 2, hacc: value, vacc: value, spdacc: value, crsacc: value)
                let gpsText = try Self.text(gps)
                let decodedGPS = try JSONDecoder().decode(RawFormat.GPSLine.self, from: Data(gpsText.utf8))
                #expect(decodedGPS.hacc == value && decodedGPS.vacc == value, "\(value)")
                #expect(decodedGPS.spdacc == value && decodedGPS.crsacc == value, "\(value)")
                let headingText = try Self.text(RawFormat.HeadingLine(ts: Self.start, mag: 1, acc: value))
                let decodedHeading = try JSONDecoder().decode(RawFormat.HeadingLine.self, from: Data(headingText.utf8))
                #expect(decodedHeading.acc == value, "\(value)")
            }
        }
    }

    @Test func fixesJustOutsideAnAccuracyLimitStayRejectedAfterWriting() throws {
        let limit: Double = SessionStats.maxHorizontalAccuracy
        var fixes: [GPSFix] = []
        for second in 0..<120 {
            let t: Double = Double(second)
            let latitude: Double = 10 + t * 1e-5
            // Every third fix is just too inaccurate; its position would add distance.
            let isBad: Bool = second % 3 == 1
            let hacc: Double = isBad ? limit + 0.04 : limit - 0.04
            let crsacc: Double = isBad ? SailingManeuverDetector.axisProximity + 0.04 : 5
            let offset: Double = isBad ? 5e-4 : 0
            fixes.append(
                GPSFix(
                    t: t, latitude: latitude + offset, longitude: 20, horizontalAccuracy: hacc, speed: 1.1,
                    course: 0, courseAccuracy: crsacc))
        }
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: .sailing, startedAt: Self.start, endedAt: Self.start + 120,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"))
        let original = RawSession(meta: meta, gps: fixes)
        let reread = try Self.roundTrip(original)
        let before = SessionStats(session: original)
        let after = SessionStats(session: reread)
        #expect(before.acceptedFixes == 80)
        #expect(after.acceptedFixes == before.acceptedFixes)
        #expect(after.rejectedFixes == before.rejectedFixes)
        let distanceChange: Double = abs(after.distance - before.distance)
        #expect(distanceChange <= 0.01)
        let reliable: [Bool] = reread.gps.map { SailingManeuverDetector.reliableCourseAccuracy($0.courseAccuracy) }
        let reliableBefore: [Bool] = fixes.map { SailingManeuverDetector.reliableCourseAccuracy($0.courseAccuracy) }
        #expect(reliable == reliableBefore)
    }

    // MARK: Heading rate

    @Test func headingThrottleKeepsAboutOneLinePerSecond() {
        var throttle = RawFormat.HeadingThrottle()
        // CoreLocation with no heading filter: about 50 Hz with a little jitter.
        var random = SplitMix64(seed: 7)
        var times: [Double] = []
        for index in 0..<3_000 {
            let nominal: Double = Double(index) * 0.02
            let jitter: Double = random.unit() * 0.002
            times.append(Self.start + nominal + jitter)
        }
        let kept = times.filter { throttle.admit($0) }
        #expect((59...61).contains(kept.count))
        let gaps: [Double] = zip(kept, kept.dropFirst()).map { (a: Double, b: Double) -> Double in b - a }
        #expect(gaps.allSatisfy { (gap: Double) -> Bool in gap >= 1 && gap < 1.05 })
        #expect(kept.first == times.first)
    }

    @Test func headingThrottleRestartsAfterTheClockGoesBack() {
        var throttle = RawFormat.HeadingThrottle(interval: 1)
        let admitted = [100, 100.5, 50, 50.5, 51].map { throttle.admit($0) }
        #expect(admitted == [true, false, true, false, true])
    }

    // MARK: Analysis is unchanged

    /// A paddling session with full-precision motion and a wandering GPS track.
    static func paddlingSession(sport: Sport, seed: UInt64) -> RawSession {
        var simulator = PaddleMotionSimulator(
            sport: sport,
            segments: [
                .init(duration: 90, strokeRate: 62, side: 0), .init(duration: 20, strokeRate: 0),
                .init(duration: 90, strokeRate: 48, side: 1), .init(duration: 60, strokeRate: 70, side: 0),
            ])
        simulator.seed = seed
        let motion = simulator.generate().samples
        let lastT: Double = motion.last?.t ?? 0
        let duration: Double = lastT.rounded(.up)
        // Plain statements with explicit types: Linux's many `sin`/`cos` overloads make
        // long literal expressions too slow to type-check.
        var fixes: [GPSFix] = []
        for second in 0...Int(duration) {
            let t: Double = Double(second)
            let latitudeWiggle: Double = 3e-6 * sin(t / 7)
            let latitude: Double = 10 + t * 1.234_567_891e-5 + latitudeWiggle
            let longitudeWiggle: Double = 2e-6 * cos(t / 5)
            let longitude: Double = -30 + t * 9.876_543_219e-6 + longitudeWiggle
            let speed: Double = 1.6 + 0.3 * sin(t / 11)
            let course: Double = 37 + 20 * sin(t / 13)
            fixes.append(
                GPSFix(
                    t: t + 0.000_123_456_7, latitude: latitude, longitude: longitude, altitude: 1.234_567,
                    horizontalAccuracy: 3.141_592_6, verticalAccuracy: 5.432_1, speed: speed,
                    speedAccuracy: 0.271_828, course: course, courseAccuracy: 4.444_44))
        }
        var heading: [HeadingSample] = []
        for index in 0...Int(duration * 50) {
            let t: Double = Double(index) * 0.02
            let swing: Double = sin(t)
            heading.append(
                HeadingSample(t: t, magnetic: 123.456_789 + swing, trueHeading: 135.678_9 + swing, accuracy: 11.637_5))
        }
        let meta = RawFormat.Meta(
            sessionId: UUID(uuidString: "6F1C2A3E-8A5B-4C1D-9E2F-0A1B2C3D4E5F")!, sport: sport,
            startedAt: start, endedAt: start + duration,
            device: .init(kind: "watch", model: "Watch0,0", os: "watchOS 26.0"), app: .init(version: "0", build: "0"),
            requestedRates: ["motion": 100, "gps": 1])
        return RawSession(
            meta: meta, gps: fixes, motion: motion, heading: heading,
            events: [SessionEvent(t: 0, type: .start), SessionEvent(t: duration, type: .stop)])
    }

    static func roundTrip(_ session: RawSession) throws -> RawSession {
        let temp = try TempFolder()
        try RawSessionWriter.write(session, to: temp.url)
        return try RawSessionReader.read(folder: temp.url)
    }

    static func expectSameAnalysis(
        _ original: RawSession, _ reread: RawSession, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        // Every motion value moved by at most half a step (plus double rounding).
        #expect(reread.motion.count == original.motion.count, sourceLocation: sourceLocation)
        let slack: Double = 1e-12
        let timeLimit: Double = 1e-6
        let accelerationLimit: Double = RawFormat.Resolution.acceleration / 2 + slack
        let rotationLimit: Double = RawFormat.Resolution.rotationRate / 2 + slack
        let attitudeLimit: Double = RawFormat.Resolution.attitude / 2 + slack
        for (a, b) in zip(original.motion, reread.motion) {
            let dt: Double = abs(a.t - b.t)
            let da: Double = abs(a.userAcceleration.x - b.userAcceleration.x)
            let dr: Double = abs(a.rotationRate.z - b.rotationRate.z)
            let dq: Double = abs(a.attitude.w - b.attitude.w)
            #expect(dt <= timeLimit)
            #expect(da <= accelerationLimit)
            #expect(dr <= rotationLimit)
            #expect(dq <= attitudeLimit)
        }

        let before = StrokeAnalysis.detect(session: original)
        let after = StrokeAnalysis.detect(session: reread)
        #expect(before.strokes.count > 100, sourceLocation: sourceLocation)
        #expect(after.cycles.count == before.cycles.count, sourceLocation: sourceLocation)
        #expect(after.strokes.count == before.strokes.count, sourceLocation: sourceLocation)
        // Peaks are interpolated between 40 ms bins; rounding may nudge one by a few ms.
        let shift = zip(after.cycles, before.cycles).map { abs($0.t - $1.t) }.max() ?? 0
        #expect(shift <= 0.01, "a cycle moved by \(shift) s", sourceLocation: sourceLocation)
        #expect(after.cycles.map(\.side) == before.cycles.map(\.side), sourceLocation: sourceLocation)

        let a = SessionStats(session: original)
        let b = SessionStats(session: reread)
        // GPS is written as reported, so everything derived from it comes back exactly.
        #expect(a.distance == b.distance, "\(a.distance) vs \(b.distance)", sourceLocation: sourceLocation)
        #expect(a.acceptedFixes == b.acceptedFixes, sourceLocation: sourceLocation)
        #expect(b.strokes?.count == a.strokes?.count, sourceLocation: sourceLocation)
        #expect(b.strokes?.sideSwitches == a.strokes?.sideSwitches, sourceLocation: sourceLocation)
        let rateA = try #require(a.strokes?.averageRate)
        let rateB = try #require(b.strokes?.averageRate)
        #expect(abs(rateA - rateB) <= 0.01, sourceLocation: sourceLocation)
        #expect(a.averageSpeed == b.averageSpeed, sourceLocation: sourceLocation)
        #expect(a.maxSpeed2s == b.maxSpeed2s && a.maxSpeed10s == b.maxSpeed10s, sourceLocation: sourceLocation)
        if let maxA = a.maxSpeed2s, let maxB = b.maxSpeed2s {
            #expect(abs(maxA - maxB) <= 0.01, sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: [Sport.kayak, .canoe, .sup])
    func strokesAndMetricsSurviveTheRoundedEncoding(sport: Sport) throws {
        let session = Self.paddlingSession(sport: sport, seed: 11)
        try Self.expectSameAnalysis(session, try Self.roundTrip(session))
    }

    @Test func repositoryFixtureSurvivesTheRoundedEncoding() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = repository.appendingPathComponent("fixtures/sailing/synthetic-straight-line")
        let original = try RawSessionReader.read(folder: folder)
        let reread = try Self.roundTrip(original)
        #expect(reread.motion.count == original.motion.count)
        #expect(reread.gps.count == original.gps.count)
        let a = SessionStats(session: original)
        let b = SessionStats(session: reread)
        #expect(abs(a.distance - b.distance) <= 0.01)
        #expect(a.acceptedFixes == b.acceptedFixes)
        #expect(a.events == b.events)
        #expect((a.averageSpeed == nil) == (b.averageSpeed == nil))
        if let speedA = a.averageSpeed, let speedB = b.averageSpeed {
            let difference: Double = abs(speedA - speedB)
            #expect(difference <= 0.001)
        }
        #expect(StrokeAnalysis(motion: reread.motion, sport: .kayak, distance: 332).strokeCount == 0)
    }
}
