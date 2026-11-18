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
                if let id = ProcessInfo.processInfo.environment["MADEGOOD_TEST_VOYAGES"].flatMap(UUID.init(uuidString:))
                {
                    root = URL.temporaryDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
                }
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
        guard !isReplayDemo else { return }
        // Recreate the location sessions promptly for an authorized, unfinished leg.
        // Core Location can deliver queued fixes after any kind of process launch.
        restore()
    }
}
