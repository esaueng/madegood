import Foundation
import WaterKit

/// Synthetic past sessions for UI tests and design review: launch a Debug build with
/// `-demoHistory` and three recordings are written to the store if they are not there
/// yet. Positions are around a fake origin in open water, never a real place.
enum DemoHistory {
    static let launchArgument = "-demoHistory"

    static func seedIfRequested() {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            let now = Date().timeIntervalSince1970
            let day = 86_400.0
            if arguments.contains("-demoMoments") {
                seedMoments(start: now - day)
            }
            guard arguments.contains(launchArgument) else { return }
            // Past sessions start mid-morning, local time, so History and the App Store
            // screenshots show a plausible time of day rather than whenever the test ran.
            let morning = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 + 10.5 * 3_600
            seed(
                id: "00000000-0000-4000-8000-00000000d001", sport: .sailing, start: morning - 2 * day, minutes: 48
            ) { t in
                // Upwind beats, wind from north: tack every 4 minutes, turning through the
                // wind over 8 s and slower through each tack.
                let leg = Int(t / 240)
                let intoLeg = t.truncatingRemainder(dividingBy: 240)
                let speed = intoLeg < 12 ? 1.2 + intoLeg * 0.15 : 3.1 + 0.4 * sin(t / 37)
                let course: Double = leg.isMultiple(of: 2) ? 45 : 315
                guard leg > 0, intoLeg < 8 else { return (speed, course) }
                // From the previous leg's course to this one, through 0°.
                let from: Double = leg.isMultiple(of: 2) ? -45 : 45
                let turning = from + (course - from + (leg.isMultiple(of: 2) ? 0 : -360)) * intoLeg / 8
                return (speed, (turning + 360).truncatingRemainder(dividingBy: 360))
            }
            seed(
                id: "00000000-0000-4000-8000-00000000d002", sport: .kayak, start: morning - 9 * day, minutes: 35,
                // Wrist motion for strokes: a little faster after the stop.
                paddling: [.init(duration: 900, strokeRate: 66), .init(duration: 120, strokeRate: 0),
                           .init(duration: 1_080, strokeRate: 72)]
            ) { t in
                // A steady paddle with a short stop in the middle.
                let stopped = (900.0..<1_020).contains(t)
                return (stopped ? 0 : 2.1 + 0.2 * sin(t / 23), 90 + 40 * sin(t / 600))
            }
            seed(
                id: "00000000-0000-4000-8000-00000000d003", sport: .windsurfing, start: morning - 33 * day,
                minutes: 25
            ) { t in
                // Reaching runs with planing bursts.
                let run = Int(t / 150)
                let planing = t.truncatingRemainder(dividingBy: 150) > 40
                return (planing ? 9 + 3 * sin(t / 11) : 3.5, run.isMultiple(of: 2) ? 100 : 280)
            }
        #endif
    }

    #if DEBUG
        private static func seedMoments(start: Double) {
            seed(id: "00000000-0000-4000-8000-00000000d011", sport: .sailing, start: start, minutes: 1) { t in
                // An observed turn through true north with a speed dip at the crossing.
                let progress = min(1, max(0, (t - 12) / 8))
                let speed = min(5, 2 + abs(t - 16) * 0.75)
                return (speed, (315 + 90 * progress).truncatingRemainder(dividingBy: 360))
            }
            seed(
                id: "00000000-0000-4000-8000-00000000d012", sport: .kayak, start: start, minutes: 10,
                extraEvents: [.init(t: 90.5, type: .pause), .init(t: 150.5, type: .resume)]
            ) { _ in
                // A moving route through the manual pause makes the highlight gap visible.
                (3, 90)
            }
        }

        private static func seed(
            id: String, sport: Sport, start: Double, minutes: Int, extraEvents: [SessionEvent] = [],
            paddling: [PaddleMotionSimulator.Segment] = [],
            motion: (Double) -> (speed: Double, course: Double)
        ) {
            let sessionId = UUID(uuidString: id)!
            let folder = RecordingStore.folder(for: sessionId)
            guard !FileManager.default.fileExists(atPath: folder.path) else { return }
            var lat = 10.0
            var lon = -30.0
            var gps: [GPSFix] = []
            var hr: [HRSample] = []
            let duration = Double(minutes * 60)
            for second in 0...Int(duration) {
                let t = Double(second)
                let (speed, course) = motion(t)
                gps.append(
                    GPSFix(
                        t: t, latitude: lat, longitude: lon, horizontalAccuracy: 5, speed: speed, course: course))
                (lat, lon) = Geo.destination(lat: lat, lon: lon, bearing: course, distance: speed)
                hr.append(HRSample(t: t, bpm: 105 + 25 * min(1, speed / 4) + 4 * sin(t / 50)))
            }
            let events =
                ([
                    SessionEvent(t: 0, type: .start), SessionEvent(t: duration / 2, type: .lap),
                    SessionEvent(t: duration, type: .stop),
                ] + extraEvents).sorted { $0.t < $1.t }
            let meta = RawFormat.Meta(
                sessionId: sessionId, sport: sport, startedAt: start, endedAt: start + duration,
                device: RawFormat.Device(kind: "watch", model: "Demo", os: "watchOS"),
                app: RawFormat.App(version: AppInfo.version, build: "demo"))
            var wrist: [MotionSample] = []
            if !paddling.isEmpty {
                var simulator = PaddleMotionSimulator(sport: sport, segments: paddling)
                simulator.sampleRate = 25
                simulator.seed = 3
                wrist = simulator.generate().samples.filter { $0.t >= 0 && $0.t <= duration }
            }
            try? RawSessionWriter.write(
                RawSession(meta: meta, gps: gps, motion: wrist, hr: hr, events: events), to: folder)
        }
    #endif
}
