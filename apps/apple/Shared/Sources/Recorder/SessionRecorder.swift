import CoreLocation
import Foundation
import HealthKit
import Observation
import WaterKit

/// Records a raw session (docs/formats.md) on whichever device runs it: GPS, 100 Hz
/// device motion, heart rate, heading, clock anchors, and manual events. GPS and heart
/// rate also feed WaterKit's `SessionEngine` for the live metrics on screen.
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

    /// A position for the live map.
    struct TrackPoint: Equatable {
        var latitude: Double
        var longitude: Double
    }

    /// The live map keeps at most this many points, thinning older ones evenly.
    static let maxTrackPoints = 2_000

    private(set) var state: State = .idle
    private(set) var counts = Counts()
    /// Live metrics while recording; after a stop, the final values for the summary.
    private(set) var metrics: LiveMetrics?
    /// Whether the last session's workout was saved to Apple Health.
    private(set) var savedToHealth = false
    /// Accepted positions for the live map, oldest first.
    private(set) var trackPoints: [TrackPoint] = []
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
    private var engine: SessionEngine?
    private var liveSport: Sport?
    #if os(iOS)
        private let liveActivity = SessionActivityController()
    #endif
    /// The session the engine belongs to. Sensor callbacks carry the session they came
    /// from, so a late one from an earlier session never reaches this engine.
    private var liveSession: UUID?
    /// Unix time of the session start; engine times are seconds since it.
    private var startUnix = 0.0
    /// How many of the engine's generated events are already in events.ndjson.
    private var writtenGeneratedEvents = 0

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
        let demo = DemoFeed.isEnabled
        if !demo { serviceSession = CLServiceSession(authorization: .whenInUse) }
        if WorkoutSource.isAvailable, !demo {
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
        engine = SessionEngine(profile: UserSettings.profile(for: sport))
        liveSession = sessionId
        startUnix = anchor.unix
        writtenGeneratedEvents = 0
        metrics = engine?.snapshot
        trackPoints = []

        let writers = Dictionary(
            uniqueKeysWithValues: RawFormat.Stream.allCases.map { ($0, RawStreamWriter(stream: $0, folder: folder)) })
        self.writers = writers

        // A workout session keeps the app running with the screen off (watch and iPhone).
        if WorkoutSource.isAvailable, !demo, let hrWriter = writers[.hr] {
            let workout = WorkoutSource(
                store: healthStore, writer: hrWriter,
                onInterruption: { [weak self] message in
                    Task { @MainActor in await self?.workoutInterrupted(message) }
                },
                onHeartRate: { [weak self] line in
                    Task { @MainActor in self?.ingestHeartRate(line, session: sessionId) }
                })
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
            if workout == nil, !demo {
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

        if demo {
            startDemoFeed(session: sessionId)
        } else if let writer = writers[.gps] {
            let location = LocationSource(writer: writer) { [weak self] line in
                Task { @MainActor in self?.ingestFix(line, session: sessionId) }
            }
            location.start()
            self.location = location
        }
        if !demo, let writer = writers[.motion] {
            let motion = MotionSource(writer: writer)
            motion.start(rate: Self.motionRate)
            self.motion = motion
        }
        if !demo, let writer = writers[.heading] {
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
        liveSport = sport
        #if os(iOS)
            liveActivity.start(sport: sport, startedAt: startedAt)
        #endif
    }

    /// Undoes a start that cannot continue: nothing has been recorded yet.
    private func abandonStart(folder: URL) {
        engine = nil
        liveSession = nil
        metrics = nil
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

    func lap() { userEvent(.lap) }

    /// Marks man-overboard (PLAN §5) at the latest position in `ManOverboard`, and
    /// records a `mob` event with that position and how old it was.
    func markManOverboard() {
        guard isRecording else { return }
        let now = Date()
        let mark = ManOverboard.shared.markNow(at: now)
        var data: [String: JSONValue]?
        if let mark {
            data = [
                "lat": .number(mark.latitude), "lon": .number(mark.longitude),
                "positionAge": .number((mark.positionAge * 10).rounded() / 10),
            ]
        }
        writers[.events]?.append(RawFormat.EventLine(ts: now.timeIntervalSince1970, type: .mob, data: data))
        ingest(.event(SessionEvent(t: now.timeIntervalSince1970 - startUnix, type: .mob, data: data)))
    }

    func pause() { userEvent(.pause) }

    func resume() { userEvent(.resume) }

    var isPaused: Bool {
        switch metrics?.pauseState {
        case .autoPaused, .manuallyPaused: true
        case .moving, nil: false
        }
    }

    private func userEvent(_ type: EventType) {
        guard isRecording else { return }
        let now = Date().timeIntervalSince1970
        writers[.events]?.append(RawFormat.EventLine(ts: now, type: type))
        ingest(.event(SessionEvent(t: now - startUnix, type: type)))
    }

    // MARK: Live analysis

    // Callbacks are accepted from the start of `start()` until `stop()` has fed the engine
    // its stop event, so readings queued while starting or stopping are not lost.

    private func ingestFix(_ line: RawFormat.GPSLine, session: UUID) {
        guard session == liveSession, let before = engine?.snapshot.acceptedFixes else { return }
        let fix = GPSFix(
            t: line.ts - startUnix, latitude: line.lat, longitude: line.lon, altitude: line.alt,
            horizontalAccuracy: line.hacc, verticalAccuracy: line.vacc, speed: line.spd,
            speedAccuracy: line.spdacc, course: line.crs, courseAccuracy: line.crsacc)
        ingest(.gps(fix))
        if let after = engine?.snapshot.acceptedFixes, after > before {
            appendTrackPoint(TrackPoint(latitude: line.lat, longitude: line.lon))
            workout?.addRoute([Self.location(line)])
            ManOverboard.shared.update(
                ManOverboard.Position(
                    latitude: line.lat, longitude: line.lon, at: Date(timeIntervalSince1970: line.ts),
                    speed: line.spd, course: line.crs))
        }
    }

    private func ingestHeartRate(_ line: RawFormat.HRLine, session: UUID) {
        guard session == liveSession else { return }
        ingest(.hr(HRSample(t: line.ts - startUnix, bpm: line.bpm)))
    }

    /// Feeds the engine, stores any events it generated, and publishes the new metrics.
    private func ingest(_ sample: Sample) {
        guard var engine else { return }
        engine.ingest(sample)
        let generated = engine.generatedEvents
        for event in generated.dropFirst(writtenGeneratedEvents) {
            writers[.events]?.append(
                RawFormat.EventLine(ts: startUnix + event.t, type: event.type, data: event.data))
        }
        writtenGeneratedEvents = generated.count
        self.engine = engine
        metrics = engine.snapshot
        #if os(iOS)
            if let liveSport { liveActivity.update(metrics, sport: liveSport) }
        #endif
    }

    /// Moves the engine's clock to now, so elapsed time and a stale speed update even when
    /// no sensor is reporting.
    private func tick() {
        guard isRecording, var engine else { return }
        engine.advance(to: Date().timeIntervalSince1970 - startUnix)
        self.engine = engine
        metrics = engine.snapshot
        #if os(iOS)
            if let liveSport { liveActivity.update(metrics, sport: liveSport) }
        #endif
    }

    static func location(_ line: RawFormat.GPSLine) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: line.lat, longitude: line.lon),
            altitude: line.alt ?? 0, horizontalAccuracy: line.hacc ?? 0, verticalAccuracy: line.vacc ?? -1,
            course: line.crs ?? -1, courseAccuracy: line.crsacc ?? -1, speed: line.spd ?? -1,
            speedAccuracy: line.spdacc ?? -1, timestamp: Date(timeIntervalSince1970: line.ts))
    }

    private func appendTrackPoint(_ point: TrackPoint) {
        trackPoints.append(point)
        if trackPoints.count > Self.maxTrackPoints {
            // Keep the newest point and every other older one.
            let newest = trackPoints.removeLast()
            trackPoints = trackPoints.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element) + [newest]
        }
    }

    /// Feeds the synthetic route through the same path as real sensors (see `DemoFeed`).
    private func startDemoFeed(session: UUID) {
        loops.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.isRecording else { return }
                    let now = Date().timeIntervalSince1970
                    let fix = DemoFeed.fix(at: now, startUnix: self.startUnix)
                    let hr = DemoFeed.heartRate(at: now, startUnix: self.startUnix)
                    self.writers[.gps]?.append(fix)
                    self.writers[.hr]?.append(hr)
                    self.ingestFix(fix, session: session)
                    self.ingestHeartRate(hr, session: session)
                }
            })
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
        loops.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.tick()
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
        let stoppingSport: Sport? = if case .recording(_, _, let sport) = state { sport } else { nil }
        state = .stopping
        let endedAt = Date()

        for loop in loops { loop.cancel() }
        loops = []
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
        clockObserver = nil
        location?.stop()
        motion?.stop()
        heading?.stop()
        savedToHealth =
            await workout?.stop(at: endedAt, save: stoppingSport.map(UserSettings.savesWorkout) ?? false) ?? false
        #if os(iOS)
            backgroundActivity?.invalidate()
            backgroundActivity = nil
        #endif
        serviceSession?.invalidate()
        serviceSession = nil

        ingest(.event(SessionEvent(t: endedAt.timeIntervalSince1970 - startUnix, type: .stop)))
        writers[.events]?.append(RawFormat.EventLine(ts: endedAt.timeIntervalSince1970, type: .stop))
        #if os(iOS)
            if let liveSport { liveActivity.end(metrics, sport: liveSport) }
        #endif
        liveSport = nil
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
        engine = nil
        liveSession = nil
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
