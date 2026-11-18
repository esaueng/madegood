import Foundation
import WaterKit

/// A Debug-only history with its own recording and trim directories.
enum DemoOffWater {
    static var storage: URL? {
        #if DEBUG
            let process = ProcessInfo.processInfo
            guard process.arguments.contains("-demoOffWater") else { return nil }
            let run = process.environment["MADEGOOD_OFF_WATER_TEST_RUN"].flatMap(UUID.init(uuidString:))
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return support.appendingPathComponent("DemoOffWater", isDirectory: true)
                .appendingPathComponent(run?.uuidString ?? "Default", isDirectory: true)
        #else
            nil
        #endif
    }

    static func boundaryPack(for sessionID: UUID) -> Data? {
        #if DEBUG
            guard storage != nil, sessionID == Self.sessionID else { return nil }
            let contents =
                ProcessInfo.processInfo.arguments.contains("-demoUnsupportedBoundaryPack")
                ? "MGWB b659bb55\n{\"manifest\":{\"formatVersion\":2}}" : fixturePack
            return Data(contents.utf8)
        #else
            nil
        #endif
    }

    static func seedIfRequested() throws {
        #if DEBUG
            guard let storage else { return }
            let folder = RecordingStore.folder(for: sessionID)
            guard !FileManager.default.fileExists(atPath: folder.path) else { return }
            let duration = 280.0
            let start = Date().timeIntervalSince1970
            let meta = RawFormat.Meta(
                sessionId: sessionID, sport: .kayak, startedAt: start, endedAt: start + duration,
                clock: RawFormat.ClockAnchor(unix: start, uptime: 1_000),
                device: RawFormat.Device(kind: "phone", model: "Synthetic Boundary Demo", os: "iOS"),
                app: RawFormat.App(version: AppInfo.version, build: "demo"))
            let gps = (0...Int(duration)).map { second in
                GPSFix(
                    t: Double(second), latitude: 0, longitude: Double(-1_100 + 8 * second) / 1_000_000,
                    horizontalAccuracy: 3, speed: 0.89, course: 90)
            }
            let session = RawSession(
                meta: meta, gps: gps,
                events: [SessionEvent(t: 0, type: .start), SessionEvent(t: duration, type: .stop)])
            try RawSessionWriter.write(session, to: folder)
            if ProcessInfo.processInfo.arguments.contains("-demoOffWaterV1Trim") {
                let store = SessionTrimStore(directory: storage.appendingPathComponent("SessionTrims"))
                try store.save(SessionTrim(start: 10, end: duration), for: session)
            }
        #endif
    }

    #if DEBUG
        private static let sessionID = UUID(uuidString: "00000000-0000-4000-8000-00000000d004")!

        // Hand-authored rectangle and island. The header checksums the exact JSON bytes.
        private static let fixturePack = """
            MGWB 9f06a339
            {
              "manifest": {
                "formatVersion": 1, "packID": "madegood-editor-fixture", "revision": 1,
                "provenance": {"kind": "synthetic", "source": "Hand-authored test island", "revision": "fixture-v1", "license": "Apache-2.0"},
                "uncertaintyMeters": 4
              },
              "coverage": {"westE6": -2200, "eastE6": 2200, "southE6": -2200, "northE6": 2200},
              "coastalWater": [],
              "inlandWater": [{
                "outer": [[-1800,-1800],[1800,-1800],[1800,1800],[-1800,1800]],
                "holes": [[[-500,-800],[500,-800],[500,800],[-500,800]]]
              }],
              "docks": [], "bridges": [], "unverified": []
            }
            """
    #endif
}
