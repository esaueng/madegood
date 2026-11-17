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
final class WorkoutSource: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, Sendable {
    private let store: HKHealthStore
    private let writer: RawStreamWriter
    private let lastHeartRateDate = Mutex<Date?>(nil)
    private let state = Mutex<(session: HKWorkoutSession?, builder: HKLiveWorkoutBuilder?)>((nil, nil))
    private let route = Mutex<HKWorkoutRouteBuilder?>(nil)
    /// Route inserts run one after another; `stop` waits for the last before finishing.
    private let routeInserts = Mutex<Task<Void, Never>?>(nil)
    private let routePoints = Mutex(0)
    private let isStopping = Mutex(false)
    /// Called (on an arbitrary queue) if the workout fails or ends without `stop`, which
    /// means the app no longer has guaranteed background time.
    private let onInterruption: @Sendable (String) -> Void
    /// Receives every heart-rate line written, on an arbitrary queue, for live analysis.
    private let onHeartRate: @Sendable (RawFormat.HRLine) -> Void

    init(
        store: HKHealthStore, writer: RawStreamWriter, onInterruption: @escaping @Sendable (String) -> Void,
        onHeartRate: @escaping @Sendable (RawFormat.HRLine) -> Void = { _ in }
    ) {
        self.store = store
        self.writer = writer
        self.onInterruption = onInterruption
        self.onHeartRate = onHeartRate
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static func requestAuthorization(store: HKHealthStore) async throws {
        let heartRate = HKQuantityType(.heartRate)
        try await store.requestAuthorization(
            toShare: [HKObjectType.workoutType(), HKSeriesType.workoutRoute()], read: [heartRate])
    }

    func start(sport: Sport, at date: Date) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = Self.activityType(for: sport)
        configuration.locationType = .outdoor

        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        session.delegate = self
        builder.delegate = self
        state.withLock { $0 = (session, builder) }
        route.withLock { $0 = HKWorkoutRouteBuilder(healthStore: store, device: nil) }

        session.startActivity(with: date)
        try await builder.beginCollection(at: date)
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
        guard isNew else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let line = RawFormat.HRLine(ts: interval.start.timeIntervalSince1970, bpm: bpm)
        writer.append(line)
        onHeartRate(line)
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    // MARK: HKWorkoutSessionDelegate

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        guard toState == .ended || toState == .stopped, !isStopping.withLock({ $0 }) else { return }
        onInterruption("The workout session ended unexpectedly.")
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        guard !isStopping.withLock({ $0 }) else { return }
        onInterruption("The workout session failed: \(error.localizedDescription)")
    }
}
