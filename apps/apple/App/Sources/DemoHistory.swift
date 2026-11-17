import Foundation
import WaterKit

/// Synthetic past sessions for UI tests and design review: launch a Debug build with
/// `-demoHistory` and three recordings are written to the store if they are not there
/// yet. Positions are around a fake origin in open water, never a real place.
enum DemoHistory {
    static let launchArgument = "-demoHistory"

    static func seedIfRequested() {
        #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
            let now = Date().timeIntervalSince1970
            let day = 86_400.0
            seed(id: "00000000-0000-4000-8000-00000000d001", sport: .sailing, start: now - 2 * day, minutes: 48) { t in
                // Upwind beats: tack every 4 minutes, slower through each tack.
                let leg = Int(t / 240)
                let intoLeg = t.truncatingRemainder(dividingBy: 240)
                let speed = intoLeg < 12 ? 1.2 + intoLeg * 0.15 : 3.1 + 0.4 * sin(t / 37)
                return (speed, leg.isMultiple(of: 2) ? 45 : 315)
            }
            seed(id: "00000000-0000-4000-8000-00000000d002", sport: .kayak, start: now - 9 * day, minutes: 35) { t in
                // A steady paddle with a short stop in the middle.
                let stopped = (900.0..<1_020).contains(t)
                return (stopped ? 0 : 2.1 + 0.2 * sin(t / 23), 90 + 40 * sin(t / 600))
            }
            seed(id: "00000000-0000-4000-8000-00000000d003", sport: .windsurfing, start: now - 33 * day, minutes: 25) {
                t in
                // Reaching runs with planing bursts.
                let run = Int(t / 150)
                let planing = t.truncatingRemainder(dividingBy: 150) > 40
                return (planing ? 9 + 3 * sin(t / 11) : 3.5, run.isMultiple(of: 2) ? 100 : 280)
            }
        #endif
    }

    #if DEBUG
        private static func seed(
            id: String, sport: Sport, start: Double, minutes: Int, motion: (Double) -> (speed: Double, course: Double)
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
            let events = [
                SessionEvent(t: 0, type: .start), SessionEvent(t: duration / 2, type: .lap),
                SessionEvent(t: duration, type: .stop),
            ]
            let meta = RawFormat.Meta(
                sessionId: sessionId, sport: sport, startedAt: start, endedAt: start + duration,
                clock: RawFormat.ClockAnchor(unix: start, uptime: 1_000),
                device: RawFormat.Device(kind: "watch", model: "Demo", os: "watchOS"),
                app: RawFormat.App(version: AppInfo.version, build: "demo"))
            try? RawSessionWriter.write(
                RawSession(meta: meta, gps: gps, hr: hr, events: events), to: folder)
        }
    #endif
}
