import CoreLocation
import Foundation
import HealthKit
import Synchronization
import WaterKit

/// Runs an `HKWorkoutSession` so the app keeps recording in the background (and the watch
/// keeps its sensors on), and logs heart rate from the live workout builder.
///
/// At the end the workout is saved to Apple Health with its route and heart rate, or
/// discarded, per the sport's setting (`UserSettings.savesWorkout`). The raw recording is
/// kept either way.
///
/// A countdown can `prepare` the session first: it stays in its prepared state (sensors
/// on, the app kept running with the wrist down, nothing collected) until `start` begins
/// the same session, or `cancel` ends it.
final class WorkoutSource: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, Sendable {
    private let store: HKHealthStore
    private let lastHeartRateDate = Mutex<Date?>(nil)
    private let state = Mutex<(session: HKWorkoutSession?, builder: HKLiveWorkoutBuilder?)>((nil, nil))
    /// Counts the sessions this source has run, so an interruption handled later (after an
    /// actor hop) can tell whether it is about the session that is current now.
    private let generation = Mutex(0)
    private let route = Mutex<HKWorkoutRouteBuilder?>(nil)
    /// Route inserts run one after another; `stop` waits for the last before finishing.
    private let routeInserts = Mutex<Task<Void, Never>?>(nil)
    private let routePoints = Mutex(0)
    private let isStopping = Mutex(false)
    /// Called (on an arbitrary queue) if the workout fails or ends without `stop`, which
    /// means the app no longer has guaranteed background time. Carries the session's
    /// generation; check it with `isCurrent(generation:)` before acting.
    private let onInterruption: @Sendable (WorkoutSource, String, Int) -> Void
    /// Where heart rate goes once `start` has run: the raw writer, and a callback (on an
    /// arbitrary queue) for live analysis.
    private let heartRateSink = Mutex<(writer: RawStreamWriter, onHeartRate: @Sendable (RawFormat.HRLine) -> Void)?>(nil)

    init(store: HKHealthStore, onInterruption: @escaping @Sendable (WorkoutSource, String, Int) -> Void) {
        self.store = store
        self.onInterruption = onInterruption
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static func requestAuthorization(store: HKHealthStore) async throws {
        let heartRate = HKQuantityType(.heartRate)
        try await store.requestAuthorization(
            toShare: [HKObjectType.workoutType(), HKSeriesType.workoutRoute()], read: [heartRate])
    }

    /// Creates the session for `sport` and moves it to the prepared state, for a countdown.
    func prepare(sport: Sport) throws {
        let (session, builder) = try makeSession(sport: sport)
        install(session, builder)
        session.prepare()
    }

    /// Begins the workout: the prepared session if there is a usable one for `sport`,
    /// otherwise a new one. Heart rate goes to `writer` and `onHeartRate` from here on.
    func start(
        sport: Sport, at date: Date, writer: RawStreamWriter,
        onHeartRate: @escaping @Sendable (RawFormat.HRLine) -> Void = { _ in }
    ) async throws {
        heartRateSink.withLock { $0 = (writer, onHeartRate) }
        let activityType = Self.activityType(for: sport)
        let prepared = state.withLock { state -> (HKWorkoutSession, HKLiveWorkoutBuilder)? in
            guard let session = state.session, let builder = state.builder,
                Self.canStart(session.state), session.workoutConfiguration.activityType == activityType
            else { return nil }
            return (session, builder)
        }
        let (session, builder): (HKWorkoutSession, HKLiveWorkoutBuilder)
        if let prepared {
            (session, builder) = prepared
        } else {
            // A prepared session that ended (or is for another sport) can't be started.
            let stale = state.withLock { state in
                let current = state.session
                state = (nil, nil)
                return current
            }
            stale?.end()
            (session, builder) = try makeSession(sport: sport)
            install(session, builder)
        }
        route.withLock { $0 = HKWorkoutRouteBuilder(healthStore: store, device: nil) }

        session.startActivity(with: date)
        try await builder.beginCollection(at: date)
    }

    /// Ends a session that was prepared but never started. Nothing is saved.
    func cancel() {
        let session = state.withLock { state in
            let current = state.session
            state = (nil, nil)
            return current
        }
        session?.end()
    }

    #if os(watchOS)
        /// The primary session is captured once for this recording's mirror task.
        var sessionForMirroring: HKWorkoutSession? { state.withLock { $0.session } }
    #endif

    private func install(_ session: HKWorkoutSession, _ builder: HKLiveWorkoutBuilder) {
        state.withLock { state in
            generation.withLock { $0 += 1 }
            state = (session, builder)
        }
    }

    /// Whether `generation` (from `onInterruption`) is the session running now.
    func isCurrent(generation value: Int) -> Bool {
        state.withLock { state in state.session != nil && generation.withLock { $0 } == value }
    }

    /// Only a session that has not run yet can start (`startActivity`).
    static func canStart(_ state: HKWorkoutSessionState) -> Bool {
        state == .notStarted || state == .prepared
    }

    private func makeSession(sport: Sport) throws -> (HKWorkoutSession, HKLiveWorkoutBuilder) {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = Self.activityType(for: sport)
        configuration.locationType = .outdoor

        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        session.delegate = self
        builder.delegate = self
        return (session, builder)
    }

    /// Adds accepted positions to the workout route (inserted in the background).
    func addRoute(_ locations: [CLLocation]) {
        guard !locations.isEmpty else { return }
        // Admission happens while holding the route lock: once `stop` has taken the
        // builder, no insert can join the chain it drains.
        route.withLock { builder in
            guard let builder else { return }
            routeInserts.withLock { chain in
                let previous = chain
                chain = Task.detached { [self] in
                    await previous?.value
                    do {
                        try await builder.insertRouteData(locations)
                        self.routePoints.withLock { $0 += locations.count }
                    } catch {
                        print("WorkoutSource: route insert failed: \(error)")
                    }
                }
            }
        }
    }

    /// Ends the workout and saves it (with route and heart rate) or discards it.
    /// Returns whether a workout was saved to Health.
    @discardableResult
    func stop(at date: Date, save: Bool = false) async -> Bool {
        isStopping.withLock { $0 = true }
        let (session, builder) = state.withLock { state in
            let current = state
            state = (nil, nil)
            return current
        }
        let routeBuilder = route.withLock { builder in
            let current = builder
            builder = nil
            return current
        }
        session?.end()
        // No new inserts can start now (the route builder is taken); finish the queued ones.
        let pendingInserts: Task<Void, Never>? = routeInserts.withLock { chain in
            let last = chain
            chain = nil
            return last
        }
        await pendingInserts?.value
        guard let builder else { return false }
        do {
            try await builder.endCollection(at: date)
        } catch {
            print("WorkoutSource: endCollection failed: \(error)")
        }
        guard save else {
            builder.discardWorkout()
            routeBuilder?.discard()
            return false
        }
        let workout: HKWorkout
        do {
            guard let saved = try await builder.finishWorkout() else { return false }
            workout = saved
        } catch {
            print("WorkoutSource: saving the workout failed: \(error)")
            routeBuilder?.discard()
            return false
        }
        // The route is optional: the workout is already saved even if it fails (say,
        // route sharing was denied). An empty route cannot be finished, so it is discarded.
        if let routeBuilder {
            if routePoints.withLock({ $0 }) > 0 {
                do {
                    try await routeBuilder.finishRoute(with: workout, metadata: nil)
                } catch {
                    print("WorkoutSource: saving the route failed: \(error)")
                }
            } else {
                routeBuilder.discard()
            }
        }
        return true
    }

    static func activityType(for sport: Sport) -> HKWorkoutActivityType {
        switch sport {
        case .sailing: .sailing
        case .windsurfing: .waterSports
        case .motorboating: .other
        case .kayak, .canoe, .sup: .paddleSports
        }
    }

    // MARK: HKLiveWorkoutBuilderDelegate

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let heartRate = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRate),
            let statistics = workoutBuilder.statistics(for: heartRate),
            let quantity = statistics.mostRecentQuantity(),
            let interval = statistics.mostRecentQuantityDateInterval()
        else { return }
        let isNew = lastHeartRateDate.withLock { last in
            guard last != interval.start else { return false }
            last = interval.start
            return true
        }
        guard isNew, let sink = heartRateSink.withLock({ $0 }) else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let line = RawFormat.HRLine(ts: interval.start.timeIntervalSince1970, bpm: bpm)
        sink.writer.append(line)
        sink.onHeartRate(line)
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    // MARK: HKWorkoutSessionDelegate

    /// The generation of `session` if it is the current one. Callbacks from a session that
    /// was replaced, cancelled or stopped are not interruptions.
    private nonisolated func currentGeneration(of session: HKWorkoutSession) -> Int? {
        state.withLock { state in state.session === session ? generation.withLock { $0 } : nil }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        guard toState == .ended || toState == .stopped, !isStopping.withLock({ $0 }),
            let generation = currentGeneration(of: workoutSession)
        else { return }
        onInterruption(self, "The workout session ended unexpectedly.", generation)
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        guard !isStopping.withLock({ $0 }), let generation = currentGeneration(of: workoutSession) else { return }
        onInterruption(self, "The workout session failed: \(error.localizedDescription)", generation)
    }
}
