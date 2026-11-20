import CoreLocation
import Foundation
import Observation
import UIKit
import WaterKit

/// Owned by the phone's tab shell so capture continues across navigation.
@MainActor @Observable
final class VoyageRecorder {
    static let shared = VoyageRecorder()

    private var store: VoyageStore?
    var liveSharing: LiveVoyageSharing?
    private var updateTask: Task<Void, Never>?
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?

    private(set) var lastError: String?
    private(set) var locationStatus = "Waiting for a precise location"

    var voyages: [Voyage] { store?.voyages ?? [] }
    var activeVoyage: Voyage? { store?.activeVoyage }
    var activeLeg: VoyageLeg? { store?.activeLeg }
    var fixCount: Int { store?.activeFixCount ?? 0 }
    var lastFix: VoyagePosition? { store?.activeLastFix }
    var latestGap: VoyageGap? { store?.activeLatestGap }
    var isCapturing: Bool { updateTask != nil }
    var isAvailable: Bool { store != nil }

    func openLibrary() {
        guard store == nil else { return }
        do {
            var root = URL.applicationSupportDirectory.appending(path: "Voyages", directoryHint: .isDirectory)
            #if DEBUG
                if let testRoot = Self.testLibraryRoot() { root = testRoot }
            #endif
            let library = try VoyageStore(root: root)
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try root.setResourceValues(attributes)
            store = library
            lastError = nil
        } catch {
            lastError = "Couldn’t open the voyage library. \(error.localizedDescription)"
        }
    }

    func createVoyage(named name: String) -> Voyage? {
        perform { try store?.createVoyage(named: name) }
    }

    func startLeg(in voyageID: UUID) {
        if perform({ try store?.startLeg(in: voyageID, at: Self.now) }) != nil { startUpdates() }
    }

    func resumeLeg() {
        guard !isCapturing else { return }
        if perform({ try store?.resumeLeg(at: Self.now) }) != nil { startUpdates() }
    }

    func resumeAfterLaunch() {
        openLibrary()
        guard !isCapturing, activeLeg != nil,
            [.authorizedAlways, .authorizedWhenInUse].contains(CLLocationManager().authorizationStatus)
        else { return }
        if perform({ try store?.resumeLeg(at: Self.now, acceptQueuedPositions: true) }) != nil {
            startUpdates()
        }
    }

    func endLeg() {
        if perform({ try store?.endLeg(at: Self.now) }) != nil { stopUpdates() }
    }

    func track(for leg: VoyageLeg) throws -> [VoyageTrackPoint] {
        guard let store else { throw CocoaError(.fileReadUnknown) }
        return try store.track(for: leg)
    }

    private static var now: TimeInterval { Date.now.timeIntervalSince1970 }

    #if DEBUG
        /// UI tests (Debug, simulator only): the test's own voyage library, named by
        /// `MADEGOOD_TEST_VOYAGES`. The name is also written to a marker file in the
        /// backup-excluded test directory, so a relaunch of the app by the system within
        /// `testLibraryLifetime` (Core Location can relaunch it during a leg, without the
        /// test's environment) opens the same library. `-resetSettings` and expiry forget it.
        static func testLibraryRoot(now: Date = .now) -> URL? {
            #if targetEnvironment(simulator)
                forgetTestLibraryIfRequested()
                let fileManager = FileManager.default
                if let id = ProcessInfo.processInfo.environment["MADEGOOD_TEST_VOYAGES"]
                    .flatMap(UUID.init(uuidString:))
                {
                    rememberTestLibrary(id, at: now)
                    return testLibrary(id)
                }
                guard let text = try? String(contentsOf: testLibraryMarker, encoding: .utf8) else { return nil }
                let parts = text.split(separator: "\n")
                guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
                    let written = Double(parts[1]),
                    (0...testLibraryLifetime).contains(now.timeIntervalSince1970 - written)
                else {
                    try? fileManager.removeItem(at: testLibraryMarker)
                    return nil
                }
                return testLibrary(id)
            #else
                return nil
            #endif
        }

        /// Writes the marker naming the test library, in the backup-excluded test directory.
        static func rememberTestLibrary(_ id: UUID, at date: Date) {
            do {
                var directory = testLibrariesDirectory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var attributes = URLResourceValues()
                attributes.isExcludedFromBackup = true
                try directory.setResourceValues(attributes)
                let marker = "\(id.uuidString)\n\(date.timeIntervalSince1970)"
                try marker.write(to: testLibraryMarker, atomically: true, encoding: .utf8)
            } catch {
                print("VoyageRecorder: couldn't remember the test library: \(error)")
            }
        }

        /// How long a system relaunch still opens the last UI test's library.
        static let testLibraryLifetime: TimeInterval = 15 * 60

        /// Forgets the remembered test library when launched with `-resetSettings`. Runs on
        /// every launch path, including the off-water demo's.
        static func forgetTestLibraryIfRequested() {
            guard ProcessInfo.processInfo.arguments.contains("-resetSettings") else { return }
            try? FileManager.default.removeItem(at: testLibraryMarker)
        }

        /// Whether this launch is a UI test's, which shows the test-only controls.
        static var isUITestLaunch: Bool {
            #if targetEnvironment(simulator)
                ProcessInfo.processInfo.environment["MADEGOOD_TEST_VOYAGES"] != nil
            #else
                false
            #endif
        }

        /// UI tests: stops the location updates and sessions of the active leg without
        /// ending it, so the test can terminate the app without Core Location relaunching
        /// it in the background. The leg resumes on the next launch, like after any exit.
        func stopUpdatesForTest() {
            stopUpdates()
        }

        private static var testLibrariesDirectory: URL {
            URL.applicationSupportDirectory.appending(path: "TestVoyages", directoryHint: .isDirectory)
        }

        private static var testLibraryMarker: URL {
            testLibrariesDirectory.appending(path: "current-library", directoryHint: .notDirectory)
        }

        private static func testLibrary(_ id: UUID) -> URL {
            testLibrariesDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
        }
    #endif

    private func perform<Result>(_ operation: () throws -> Result?) -> Result? {
        do {
            let result = try operation()
            lastError = nil
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func startUpdates() {
        locationStatus = "Waiting for a precise location"
        serviceSession = CLServiceSession(authorization: .whenInUse)
        backgroundSession = CLBackgroundActivitySession()
        updateTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard !Task.isCancelled, let self else { return }
                    if !self.receive(update) { return }
                }
                if !Task.isCancelled {
                    self?.interrupt("Location updates stopped. Resume the leg to continue.")
                }
            } catch {
                if !Task.isCancelled {
                    self?.interrupt("Location updates failed. Resume the leg to continue.")
                }
            }
        }
    }

    private func receive(_ update: CLLocationUpdate) -> Bool {
        if update.authorizationDeniedGlobally {
            interrupt("Location Services is off. Turn it on in Settings, then resume the leg.")
            return false
        }
        if update.authorizationRestricted {
            interrupt("Location access is restricted on this iPhone. Check the device restrictions before resuming.")
            return false
        }
        if update.authorizationDenied {
            interrupt("Location access is denied for MadeGood. Allow it in Settings, then resume the leg.")
            return false
        }
        if update.locationUnavailable || update.accuracyLimited || update.insufficientlyInUse {
            store?.setStationaryPause(false)
            if update.accuracyLimited {
                locationStatus = "Precise Location is off for MadeGood. Turn it on in Settings to save positions."
            } else if update.insufficientlyInUse {
                locationStatus = "Open MadeGood to continue receiving location updates."
            } else {
                locationStatus = "Location is temporarily unavailable."
            }
            return true
        }
        let position = update.location.flatMap { location -> VoyagePosition? in
            guard let line = LocationSource.line(for: location) else { return nil }
            return VoyagePosition(
                timestamp: line.ts, latitude: line.lat, longitude: line.lon,
                horizontalAccuracy: location.horizontalAccuracy, speed: line.spd, course: line.crs)
        }
        do {
            let previousCount = fixCount
            let previousGap = latestGap
            if try store?.record(position, isStationary: update.stationary, receivedAt: Self.now) == true {
                locationStatus = "Recording positions"
                if fixCount > previousCount, let position, let voyageID = activeVoyage?.id, let legID = activeLeg?.id {
                    liveSharing?.savedPosition(
                        voyageID: voyageID, legID: legID, position: position,
                        gapBefore: latestGap != previousGap
                    )
                }
            }
        } catch VoyageStore.StoreError.clockBehind {
            interrupt(VoyageStore.StoreError.clockBehind.localizedDescription)
            return false
        } catch {
            interrupt("Couldn’t save a position. \(error.localizedDescription)")
            return false
        }
        if update.stationary {
            store?.setStationaryPause(true)
            if fixCount > 0 { locationStatus = "Stationary" }
        }
        return true
    }

    private func interrupt(_ message: String) {
        store?.interruptCapture()
        stopUpdates()
        lastError = message
    }

    private func stopUpdates() {
        updateTask?.cancel()
        updateTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        serviceSession?.invalidate()
        serviceSession = nil
    }
}

@MainActor
class VoyageLaunchDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.restoreActiveLeg(isReplayDemo: DemoOffWater.storage != nil) {
            VoyageRecorder.shared.resumeAfterLaunch()
        }
        return true
    }

    static func restoreActiveLeg(isReplayDemo: Bool, using restore: () -> Void) {
        #if MADEGOOD_VOYAGES
            guard !isReplayDemo else { return }
            // Recreate the location sessions promptly for an authorized, unfinished leg.
            // Core Location can deliver queued fixes after any kind of process launch.
            restore()
        #endif
    }
}
