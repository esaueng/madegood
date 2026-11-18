import Foundation
import HealthKit
import Observation

/// Receives read-only live snapshots. The watch owns the recording and its lifecycle.
@MainActor
@Observable
final class WatchWorkoutMirror: NSObject, HKWorkoutSessionDelegate {
    static let shared = WatchWorkoutMirror()
    static let staleAfter: TimeInterval = 15

    private enum Event: Sendable {
        case attached(HKWorkoutSession)
        case data(HKWorkoutSession, [Data])
        case disconnected(HKWorkoutSession)
        case stopped(HKWorkoutSession)
    }

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var state = WorkoutMirrorState()
    nonisolated private let events: AsyncStream<Event>.Continuation

    var connectedSnapshot: WorkoutMirrorSnapshot? { state.connectedSnapshot }
    var lastConfirmed: WorkoutMirrorSnapshot? { state.lastConfirmed }

    private override init() {
        let (stream, events) = AsyncStream.makeStream(of: Event.self)
        self.events = events
        super.init()
        guard HKHealthStore.isHealthDataAvailable(), !DemoFeed.isEnabled else { return }
        // Keep one ordered handoff from the HealthKit callbacks to the main actor.
        Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            guard let self, session.type == .mirrored,
                session.state != .ended, session.state != .stopped
            else { return }
            events.yield(.attached(session))
            session.delegate = self
        }
    }

    private func handle(_ event: Event) {
        switch event {
        case .attached(let source):
            session = source
            state.connect(ObjectIdentifier(source))
        case .data(let source, let packets):
            guard session === source else { return }
            let decoder = JSONDecoder()
            for packet in packets {
                if let snapshot = try? decoder.decode(WorkoutMirrorSnapshot.self, from: packet) {
                    state.receive(snapshot, from: ObjectIdentifier(source))
                }
            }
        case .disconnected(let source):
            close(source, stopped: false)
        case .stopped(let source):
            close(source, stopped: true)
        }
    }

    private func close(_ source: HKWorkoutSession, stopped: Bool) {
        guard session === source else { return }
        let connection = ObjectIdentifier(source)
        if stopped {
            state.stop(connection)
        } else {
            state.disconnect(connection)
        }
        session = nil
    }

    #if DEBUG
        func seedDemoIfRequested() {
            guard DemoFeed.isEnabled, ProcessInfo.processInfo.arguments.contains("-demoWatchMirror"),
                lastConfirmed == nil
            else { return }
            let source = NSObject()
            let connection = ObjectIdentifier(source)
            var readings = LiveReadings(nil)
            readings.speed = 5
            readings.pauseState = .manuallyPaused
            state.connect(connection)
            state.receive(
                WorkoutMirrorSnapshot(sessionID: UUID(), sequence: 1, sport: .canoe, sentAt: .now, readings: readings),
                from: connection)
        }
    #endif

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        events.yield(.data(workoutSession, data))
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        if toState == .stopped || toState == .ended {
            events.yield(.stopped(workoutSession))
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: (any Error)?
    ) {
        events.yield(.disconnected(workoutSession))
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        events.yield(.disconnected(workoutSession))
    }
}
