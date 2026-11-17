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
    private var writers: [RawFormat.Stream: StreamWriter] = [:]
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
    private var clockObserver: (any NSObjectProtocol)?

    var isRecording: Bool {
        if case .recording = state { true } else { false }
    }

    // MARK: Start

    func start(sport: Sport) async {
        guard state == .idle else { return }
        state = .starting
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
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastError = "Could not create the recording folder: \(error.localizedDescription)"
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
            uniqueKeysWithValues: RawFormat.Stream.allCases.map { ($0, StreamWriter(stream: $0, folder: folder)) })
        self.writers = writers

        // A workout session keeps the app running with the screen off (watch and iPhone).
        if WorkoutSource.isAvailable, let hrWriter = writers[.hr] {
            let workout = WorkoutSource(store: healthStore, writer: hrWriter)
            do {
                try await workout.start(sport: sport, at: startedAt)
                self.workout = workout
            } catch {
                lastError = "Workout session failed: \(error.localizedDescription)"
            }
        }
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
        func lines(_ stream: RawFormat.Stream) -> Int { writers[stream]?.counts.lines ?? 0 }
        counts.gps = lines(.gps)
        counts.motion = lines(.motion)
        counts.hr = lines(.hr)
        counts.heading = lines(.heading)
        counts.dropped = writers.values.reduce(0) { $0 + $1.counts.dropped }
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
        await Task.detached(priority: .userInitiated) {
            for writer in writers { writer.flushAndWait() }
        }.value

        meta?.endedAt = endedAt.timeIntervalSince1970
        writeMeta()

        let folder = folder
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
