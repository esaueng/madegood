import Foundation
import HealthKit
import Synchronization
import WaterKit

/// Runs an `HKWorkoutSession` so the app keeps recording in the background (and the watch
/// keeps its sensors on), and logs heart rate from the live workout builder.
///
/// The raw recorder discards the workout at the end: Phase 0 recordings are for algorithm
/// work and should not appear in the Health app. Saving workouts arrives in Phase 1.
final class WorkoutSource: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, Sendable {
    private let store: HKHealthStore
    private let writer: RawStreamWriter
    private let lastHeartRateDate = Mutex<Date?>(nil)
    private let state = Mutex<(session: HKWorkoutSession?, builder: HKLiveWorkoutBuilder?)>((nil, nil))
    private let isStopping = Mutex(false)
    /// Called (on an arbitrary queue) if the workout fails or ends without `stop`, which
    /// means the app no longer has guaranteed background time.
    private let onInterruption: @Sendable (String) -> Void

    init(store: HKHealthStore, writer: RawStreamWriter, onInterruption: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.writer = writer
        self.onInterruption = onInterruption
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static func requestAuthorization(store: HKHealthStore) async throws {
        let heartRate = HKQuantityType(.heartRate)
        try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [heartRate])
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

        session.startActivity(with: date)
        try await builder.beginCollection(at: date)
    }

    func stop(at date: Date) async {
        isStopping.withLock { $0 = true }
        let (session, builder) = state.withLock { state in
            let current = state
            state = (nil, nil)
            return current
        }
        session?.end()
        guard let builder else { return }
        do {
            try await builder.endCollection(at: date)
        } catch {
            print("WorkoutSource: endCollection failed: \(error)")
        }
        builder.discardWorkout()
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

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
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
        writer.append(RawFormat.HRLine(ts: interval.start.timeIntervalSince1970, bpm: bpm))
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
