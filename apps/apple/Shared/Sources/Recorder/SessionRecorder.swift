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
    /// Live paddle strokes for kayak, canoe and SUP (nil for other sports), updated about
    /// once a second; after a stop, the final values.
    private(set) var strokes: StrokeDetector.Metrics?
    /// Whether the last session's workout was saved to Apple Health.
    private(set) var savedToHealth = false
    /// Accepted positions for the live map, oldest first.
    private(set) var trackPoints: [TrackPoint] = []
    private(set) var lastError: String?
    /// The latest distance alert (the sport's "alert every N" setting), for a banner and
    /// a haptic. Not recorded: alerts are a display feature, not session data.
    private(set) var distanceAlert: DistanceAlertEvent?
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
    /// The workout session held in its prepared state during a countdown; `start` begins it.
    private var prepared: (id: UUID, sport: Sport, workout: WorkoutSource)?
    /// Identifies the latest `prepare` call, so one that finishes after a cancel or start
    /// does not leave a session behind.
    private var prepareID: UUID?
    private var serviceSession: CLServiceSession?
    #if os(iOS)
        private var backgroundActivity: CLBackgroundActivitySession?
    #endif
    private var loops: [Task<Void, Never>] = []
    /// A workout failure reported while `start()` was still running.
    /// With the session it was about, so a session that `start` replaced afterwards (an
    /// ended prepared one) does not fail the start.
    private var startupInterruption: (message: String, source: WorkoutSource, generation: Int)?
    private var clockObserver: (any NSObjectProtocol)?
    /// The recording's monotonic clock; its uptime reading stays in memory.
    private var monotonicClock: RawFormat.MonotonicClock?
    private var engine: SessionEngine?
    private var liveStrokes: LiveStrokes?
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

    struct DistanceAlertEvent: Equatable, Identifiable {
        /// Counts alerts in the session, so the same distance twice is still a change.
        var id: Int
        /// The milestone reached, m.
        var distance: Double
    }

    private var distanceAlertTracker: DistanceAlert?

    var isRecording: Bool {
        if case .recording = state { true } else { false }
    }

    // MARK: Start

    /// For a countdown: puts a workout session for `sport` into its prepared state, which
    /// keeps the watch app running (and its countdown haptics on time) with the wrist
    /// down. `start` begins this session; `cancelPrepared` ends it. Returns this
    /// preparation's ID for `cancelPrepared(_:)`, or nil if it did nothing.
    /// `startWorkout` also starts the session's activity now (an Action button press must
    /// start a workout within 30 s); data is still collected only from `start`.
    @discardableResult
    func prepare(sport: Sport, startWorkout: Bool = false) async -> UUID? {
        guard state == .idle, WorkoutSource.isAvailable, !DemoFeed.isEnabled else { return nil }
        cancelPrepared()
        let id = UUID()
        prepareID = id
        if !startWorkout {
            // Asks for Health access before the start, so the prompt never delays it.
            try? await WorkoutSource.requestAuthorization(store: healthStore)
            guard prepareID == id, state == .idle else { return nil }
        }
        prepareID = nil
        let workout = makeWorkout()
        do {
            try workout.prepare(sport: sport, startActivity: startWorkout)
            prepared = (id, sport, workout)
        } catch {
            // Not fatal: `start` creates the session itself.
            print("SessionRecorder: preparing the workout failed: \(error)")
        }
        // The Action button needs the workout running first: a permission prompt (say, for
        // a type a later version adds) must not hold it past Apple's 30 s.
        if startWorkout { try? await WorkoutSource.requestAuthorization(store: healthStore) }
        return id
    }

    /// Ends the prepared workout session (or the pending preparation) if it is the one
    /// `prepare` returned `id` for; a newer one is left alone.
    func cancelPrepared(_ id: UUID) {
        guard prepared?.id == id || prepareID == id else { return }
        cancelPrepared()
    }

    /// Ends any prepared workout session (the countdown was cancelled).
    func cancelPrepared() {
        prepareID = nil
        prepared?.workout.cancel()
        prepared = nil
    }

    /// The prepared workout if it is for `sport`; any other is ended.
    private func takePrepared(for sport: Sport) -> WorkoutSource? {
        prepareID = nil
        guard let prepared else { return nil }
        self.prepared = nil
        if prepared.sport == sport { return prepared.workout }
        prepared.workout.cancel()
        return nil
    }

    private func makeWorkout() -> WorkoutSource {
        WorkoutSource(store: healthStore) { [weak self] source, message, generation in
            Task { @MainActor in
                // Queued before a replacement session started: not about the current one.
                guard source.isCurrent(generation: generation) else { return }
                await self?.workoutInterrupted(message, source: source, generation: generation)
            }
        }
    }

    /// Reserve the recorder synchronously before authorization or any other async work.
    func start(sport: Sport) {
        guard state == .idle else { return }
        state = .starting
        Task { await startRecording(sport: sport) }
    }

    private func startRecording(sport: Sport) async {
        let preparedWorkout = takePrepared(for: sport)
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
            preparedWorkout?.cancel()
            state = .idle
            return
        }
        self.folder = folder

        // The session's monotonic clock (raw format 2): boot-time readings become absolute
        // times from here on, and only those are written (docs/formats.md, "Clocks").
        let clock = RawFormat.MonotonicClock(
            startUnix: startedAt.timeIntervalSince1970, startUptime: ProcessInfo.processInfo.systemUptime)
        monotonicClock = clock
        let meta = RawFormat.Meta(
            sessionId: sessionId, sport: sport, startedAt: clock.startUnix,
            device: DeviceInfo.current, app: DeviceInfo.app,
            requestedRates: ["gps": 1, "motion": Self.motionRate])
        self.meta = meta
        writeMeta()
        engine = SessionEngine(profile: UserSettings.profile(for: sport))
        liveSession = sessionId
        startUnix = clock.startUnix
        writtenGeneratedEvents = 0
        metrics = engine?.snapshot
        let liveStrokes = sport.isPaddling ? LiveStrokes(sport: sport, clock: clock) : nil
        self.liveStrokes = liveStrokes
        strokes = liveStrokes?.snapshot()
        trackPoints = []
        distanceAlert = nil
        let settings = UserSettings.settings(for: sport)
        distanceAlertTracker = DistanceAlert(interval: settings.distanceAlertMetres(for: sport))

        let writers = Dictionary(
            uniqueKeysWithValues: RawFormat.Stream.allCases.map { ($0, RawStreamWriter(stream: $0, folder: folder)) })
        self.writers = writers

        // A workout session keeps the app running with the screen off (watch and iPhone).
        if WorkoutSource.isAvailable, !demo, let hrWriter = writers[.hr] {
            let workout = preparedWorkout ?? makeWorkout()
            do {
                try await workout.start(sport: sport, at: startedAt, writer: hrWriter) { [weak self] line in
                    Task { @MainActor in self?.ingestHeartRate(line, session: sessionId) }
                }
                if let interruption = startupInterruption,
                    interruption.source.isCurrent(generation: interruption.generation)
                {
                    // It failed while starting; don't rely on it.
                    await workout.stop(at: Date())
                    lastError = interruption.message
                } else {
                    self.workout = workout
                }
            } catch {
                workout.cancel()
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
            startDemoFeed(session: sessionId, sport: sport, startMono: clock.startUnix)
        } else if let writer = writers[.gps] {
            let location = LocationSource(
                writer: writer,
                onFix: { [weak self] line in
                    Task { @MainActor in self?.ingestFix(line, session: sessionId) }
                },
                onIssue: { issue in
                    // MOB surfaces say why fixes stopped (PLAN §5).
                    Task { @MainActor in ManOverboard.shared.setRecorderLocationIssue(issue) }
                })
            location.start()
            self.location = location
        }
        if !demo, let writer = writers[.motion] {
            let motion = MotionSource(writer: writer, clock: clock) { [liveStrokes] line in liveStrokes?.ingest(line) }
            motion.start(rate: Self.motionRate)
            self.motion = motion
        }
        if !demo, let writer = writers[.heading] {
            let heading = HeadingSource(writer: writer)
            heading.start()
            self.heading = heading
        }

        writers[.events]?.append(RawFormat.EventLine(ts: clock.startUnix, type: .start))
        if sport == .sailing {
            // The start line in use, pinged during the countdown (docs/formats.md, events).
            for ping in StartLineController.shared.pingsToRecord {
                writers[.events]?.append(
                    RawFormat.EventLine(
                        ts: clock.startUnix, type: .linePing, data: ping.eventData(age: clock.startUnix - ping.time)))
            }
        }
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
        #elseif os(watchOS)
            if let primary = workout?.sessionForMirroring {
                startMirroring(primary, sessionID: sessionId, sport: sport)
            }
        #endif
    }

    #if os(watchOS)
        private func startMirroring(_ primary: HKWorkoutSession, sessionID: UUID, sport: Sport) {
            loops.append(Task { [weak self] in
                guard !Task.isCancelled else { return }
                do {
                    try await primary.startMirroringToCompanionDevice()
                } catch {
                    // Recording and the eventual file handoff do not depend on a mirror.
                    return
                }

                let encoder = JSONEncoder()
                var sequence: UInt64 = 0
                while !Task.isCancelled {
                    guard let readings = self?.mirrorReadings(for: sessionID) else { return }
                    sequence += 1
                    let snapshot = WorkoutMirrorSnapshot(
                        sessionID: sessionID, sequence: sequence, sport: sport, sentAt: Date(), readings: readings,
                        manOverboard: ManOverboard.shared.mark, manOverboardMarks: ManOverboard.shared.marks,
                        manOverboardCleared: ManOverboard.shared.clearedMarkIDs)
                    if let data = try? encoder.encode(snapshot) {
                        // HealthKit reconnects on its own. Send the latest snapshot on the
                        // next tick rather than replaying samples after a dropped link.
                        try? await primary.sendToRemoteWorkoutSession(data: data)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            })
        }

        private func mirrorReadings(for sessionID: UUID) -> LiveReadings? {
            guard liveSession == sessionID, isRecording, let metrics else { return nil }
            return LiveReadings(metrics, strokes: strokes)
        }
    #endif

    /// Undoes a start that cannot continue: nothing has been recorded yet.
    private func abandonStart(folder: URL) {
        engine = nil
        liveStrokes = nil
        strokes = nil
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
    private func workoutInterrupted(_ message: String, source: WorkoutSource, generation: Int) async {
        if state == .starting {
            startupInterruption = (message, source, generation)
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

    /// Records a man-overboard press (PLAN §5, `SessionController.markManOverboard`) as a
    /// `mob` event with the marked position and how old it was, or without a position
    /// when the press is still waiting for the first fix.
    func recordManOverboard(_ result: ManOverboard.MarkResult) {
        guard isRecording else { return }
        let now = Date()
        var data: [String: JSONValue]?
        if case .marked(let mark) = result {
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
        if type == .pause || type == .resume { liveStrokes?.userEvent(type) }
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
            if StartLineController.shared.warning != nil {
                StartLineController.shared.recorded(
                    GPSFix(
                        t: line.ts, latitude: line.lat, longitude: line.lon, horizontalAccuracy: line.hacc,
                        speed: line.spd, course: line.crs))
            }
        }
    }

    private func ingestHeartRate(_ line: RawFormat.HRLine, session: UUID) {
        guard session == liveSession else { return }
        ingest(.hr(HRSample(t: line.ts - startUnix, bpm: line.bpm)))
    }

    /// Feeds the engine, stores any events it generated, and publishes the new metrics.
    private func ingest(_ sample: Sample) {
        // In place: a copy of a still-stored engine would copy its growing buffers each fix.
        guard
            let (generated, snapshot) = engine.update({ engine in
                engine.ingest(sample)
                return (engine.generatedEvents, engine.snapshot)
            })
        else { return }
        for event in generated.dropFirst(writtenGeneratedEvents) {
            writers[.events]?.append(
                RawFormat.EventLine(ts: startUnix + event.t, type: event.type, data: event.data))
        }
        writtenGeneratedEvents = generated.count
        metrics = snapshot
        checkDistanceAlert()
        #if os(iOS)
            if let liveSport { liveActivity.update(metrics, sport: liveSport) }
        #endif
    }

    private func checkDistanceAlert() {
        guard isRecording, let distance = metrics?.distance,
            let reached = distanceAlertTracker?.update(distance: distance)
        else { return }
        distanceAlert = DistanceAlertEvent(id: distanceAlertTracker?.count ?? 0, distance: reached)
    }

    /// Moves the engine's clock to now, so elapsed time and a stale speed update even when
    /// no sensor is reporting.
    private func tick() {
        guard isRecording, engine != nil else { return }
        let now = Date().timeIntervalSince1970 - startUnix
        metrics = engine.update { engine in
            engine.advance(to: now)
            return engine.snapshot
        }
        if let liveStrokes { strokes = liveStrokes.snapshot() }
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

    /// Feeds the synthetic route through the same path as real sensors (see `DemoFeed`),
    /// with synthetic wrist motion for paddling sports.
    private func startDemoFeed(session: UUID, sport: Sport, startMono: Double) {
        loops.append(
            Task { [weak self] in
                var motionUntil = 0.0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.isRecording else { return }
                    let now = Date().timeIntervalSince1970
                    let fix = DemoFeed.fix(at: now, startUnix: self.startUnix, sport: sport)
                    let hr = DemoFeed.heartRate(at: now, startUnix: self.startUnix)
                    self.writers[.gps]?.append(fix)
                    self.writers[.hr]?.append(hr)
                    if sport.isPaddling {
                        let elapsed = now - self.startUnix
                        for line in DemoFeed.motion(sport: sport, from: motionUntil, to: elapsed, startMono: startMono) {
                            self.writers[.motion]?.append(line)
                            self.liveStrokes?.ingest(line)
                        }
                        motionUntil = elapsed
                    }
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
        guard let monotonicClock else { return }
        writers[.clock]?.append(
            monotonicClock.anchor(
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
        ManOverboard.shared.setRecorderLocationIssue(nil)
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
        if let liveStrokes { strokes = liveStrokes.snapshot() }
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
        liveStrokes = nil
        liveSession = nil
        distanceAlertTracker = nil
        distanceAlert = nil
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
