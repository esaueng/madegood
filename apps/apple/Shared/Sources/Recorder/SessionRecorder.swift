import CoreLocation
import Foundation
import HealthKit
import Observation
import WaterKit

/// Records a raw session (docs/formats.md) on whichever device runs it: GPS, 100 Hz
/// device motion, heart rate, heading, clock anchors, and manual marks.
@MainActor
@Observable
final class SessionRecorder {
    enum State: Equatable {
        case idle
        case starting
        case recording(sessionId: UUID, startedAt: Date, sport: Sport)
        case stopping
    }

    struct Counts: Equatable {
        var gps = 0
        var motion = 0
        var hr = 0
        var heading = 0
        var marks = 0
        var dropped = 0
    }

    static let motionRate = 100.0
    static let flushInterval: Duration = .seconds(5)
    static let clockAnchorInterval: Duration = .seconds(60)

    private(set) var state: State = .idle
    private(set) var counts = Counts()
    private(set) var lastError: String?
    /// Called with the session folder after a recording stops.
    var onFinish: ((URL) -> Void)?

    private let healthStore = HKHealthStore()
    private var writers: [RawFormat.Stream: RawStreamWriter] = [:]
    private var meta: RawFormat.Meta?
    private var folder: URL?
    private var location: LocationSource?
    private var motion: MotionSource?
    private var heading: HeadingSource?
    private var workout: WorkoutSource?
    private var serviceSession: CLServiceSession?
    #if os(iOS)
        private var backgroundActivity: CLBackgroundActivitySession?
    #endif
    private var loops: [Task<Void, Never>] = []
    /// A workout failure reported while `start()` was still running.
    private var startupInterruption: String?
    private var clockObserver: (any NSObjectProtocol)?

    var isRecording: Bool {
        if case .recording = state { true } else { false }
    }

    // MARK: Start

    func start(sport: Sport) async {
        guard state == .idle else { return }
        state = .starting
        startupInterruption = nil
        lastError = nil
        counts = Counts()

        // Ask for location while the app is in use (shows the prompt the first time).
        serviceSession = CLServiceSession(authorization: .whenInUse)
        if WorkoutSource.isAvailable {
            do {
                try await WorkoutSource.requestAuthorization(store: healthStore)
            } catch {
                lastError = "Health access failed: \(error.localizedDescription)"
            }
        }

        let sessionId = UUID()
        let startedAt = Date()
        let folder = RecordingStore.folder(for: sessionId)
        // Before the folder exists, so the watch never sends or deletes it while recording.
        RecordingTransfer.shared.markActive(folder, true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastError = "Could not create the recording folder: \(error.localizedDescription)"
            RecordingTransfer.shared.markActive(folder, false)
            state = .idle
            return
        }
        self.folder = folder

        let anchor = RawFormat.ClockAnchor(
            unix: startedAt.timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime)
        let meta = RawFormat.Meta(
            sessionId: sessionId, sport: sport, startedAt: anchor.unix, clock: anchor,
            device: DeviceInfo.current, app: DeviceInfo.app,
            requestedRates: ["gps": 1, "motion": Self.motionRate])
        self.meta = meta
        writeMeta()

        let writers = Dictionary(
            uniqueKeysWithValues: RawFormat.Stream.allCases.map { ($0, RawStreamWriter(stream: $0, folder: folder)) })
        self.writers = writers

        // A workout session keeps the app running with the screen off (watch and iPhone).
        if WorkoutSource.isAvailable, let hrWriter = writers[.hr] {
            let workout = WorkoutSource(store: healthStore, writer: hrWriter) { [weak self] message in
                Task { @MainActor in await self?.workoutInterrupted(message) }
            }
            do {
                try await workout.start(sport: sport, at: startedAt)
                if let message = startupInterruption {
                    // It failed while starting; don't rely on it.
                    await workout.stop(at: Date())
                    lastError = message
                } else {
                    self.workout = workout
                }
            } catch {
                lastError = "Workout session failed: \(error.localizedDescription)"
            }
        }
        #if os(watchOS)
            // Without a workout the watch suspends the app when the wrist drops, so a
            // recording would silently stop. Don't start one.
            if workout == nil {
                if lastError == nil {
                    lastError = "Health is unavailable, so the watch can't record in the background."
                }
                abandonStart(folder: folder)
                return
            }
        #endif
        #if os(iOS)
            backgroundActivity = CLBackgroundActivitySession()
        #endif

        if let writer = writers[.gps] {
            let location = LocationSource(writer: writer)
            location.start()
            self.location = location
        }
        if let writer = writers[.motion] {
            let motion = MotionSource(writer: writer)
            motion.start(rate: Self.motionRate)
            self.motion = motion
        }
        if let writer = writers[.heading] {
            let heading = HeadingSource(writer: writer)
            heading.start()
            self.heading = heading
        }

        writers[.events]?.append(RawFormat.EventLine(ts: anchor.unix, type: .start))
        startLoops()
        clockObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeClockAnchor() }
        }
        state = .recording(sessionId: sessionId, startedAt: startedAt, sport: sport)
    }

    /// Undoes a start that cannot continue: nothing has been recorded yet.
    private func abandonStart(folder: URL) {
        writers = [:]
        meta = nil
        self.folder = nil
        try? FileManager.default.removeItem(at: folder)
        RecordingTransfer.shared.markActive(folder, false)
        serviceSession?.invalidate()
        serviceSession = nil
        state = .idle
    }

    /// The workout failed or ended on its own. On the watch that means no more background
    /// time, so the recording is finished cleanly with what it has; the iPhone keeps
    /// recording on its background location session and shows the warning.
    private func workoutInterrupted(_ message: String) async {
        if state == .starting {
            startupInterruption = message
            return
        }
        guard isRecording else { return }
        lastError = message
        #if os(watchOS)
            await stop()
            lastError = message + " The recording was saved up to this point."
        #endif
    }

    // MARK: During

    func mark() {
        guard isRecording else { return }
        writers[.events]?.append(RawFormat.EventLine(ts: Date().timeIntervalSince1970, type: .mark))
        counts.marks += 1
    }

    private func startLoops() {
        loops.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.flushInterval)
                    guard let self else { return }
                    self.flushAll()
                    self.refreshCounts()
                }
            })
        loops.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.clockAnchorInterval)
                    self?.writeClockAnchor()
                }
            })
    }

    private func writeClockAnchor() {
        writers[.clock]?.append(
            RawFormat.ClockAnchor(
                unix: Date().timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime))
    }

    private func flushAll() {
        for writer in writers.values { writer.flush() }
    }

    private func refreshCounts() {
        func lines(_ stream: RawFormat.Stream) -> Int { writers[stream]?.status.lines ?? 0 }
        counts.gps = lines(.gps)
        counts.motion = lines(.motion)
        counts.hr = lines(.hr)
        counts.heading = lines(.heading)
        let statuses = writers.values.map(\.status)
        counts.dropped = statuses.reduce(0) { $0 + $1.dropped }
        if let error = statuses.compactMap(\.lastError).first {
            lastError = "Saving data failed (retrying): \(error)"
        }
    }

    // MARK: Stop

    func stop() async {
        guard isRecording else { return }
        state = .stopping
        let endedAt = Date()

        for loop in loops { loop.cancel() }
        loops = []
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
        clockObserver = nil
        location?.stop()
        motion?.stop()
        heading?.stop()
        await workout?.stop(at: endedAt)
        #if os(iOS)
            backgroundActivity?.invalidate()
            backgroundActivity = nil
        #endif
        serviceSession?.invalidate()
        serviceSession = nil

        writers[.events]?.append(RawFormat.EventLine(ts: endedAt.timeIntervalSince1970, type: .stop))
        writeClockAnchor()
        refreshCounts()
        let writers = Array(writers.values)
        let savedEverything = await Task.detached(priority: .userInitiated) {
            // Complete only if the final flush worked and nothing was ever dropped.
            writers.map { $0.flushAndWait() }.allSatisfy { $0 } && writers.allSatisfy { $0.status.dropped == 0 }
        }.value
        refreshCounts()

        // endedAt marks a clean, complete recording. If data is missing, leave it out so
        // readers treat the recording as interrupted.
        if savedEverything {
            meta?.endedAt = endedAt.timeIntervalSince1970
            writeMeta()
        } else {
            lastError = "Some data could not be saved or was dropped. The recording is marked as incomplete."
        }

        let folder = folder
        if let folder { RecordingTransfer.shared.markActive(folder, false) }
        location = nil
        motion = nil
        heading = nil
        workout = nil
        self.writers = [:]
        meta = nil
        self.folder = nil
        state = .idle
        if let folder { onFinish?(folder) }
    }

    private func writeMeta() {
        guard let meta, let folder else { return }
        do {
            let data = try RawFormat.encodeMeta(meta)
            try data.write(to: folder.appendingPathComponent(RawFormat.metaFileName), options: .atomic)
        } catch {
            lastError = "Could not write meta.json: \(error.localizedDescription)"
        }
    }
}
