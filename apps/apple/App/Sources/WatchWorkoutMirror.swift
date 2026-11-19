import Foundation
import HealthKit
import Observation
import WaterKit

/// Receives read-only live snapshots. The watch owns the recording and its lifecycle.
@MainActor
@Observable
final class WatchWorkoutMirror: NSObject, HKWorkoutSessionDelegate {
    static let shared = WatchWorkoutMirror()

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
    var isAttached: Bool { state.isAttached }

    func isStale(at now: Date) -> Bool { state.isStale(at: now) }
    func dismissStale() { state.dismissIfStale(at: .now) }

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
                    receive(snapshot, from: ObjectIdentifier(source))
                }
            }
        case .disconnected(let source):
            close(source, stopped: false)
        case .stopped(let source):
            close(source, stopped: true)
        }
    }

    private func receive(_ snapshot: WorkoutMirrorSnapshot, from connection: ObjectIdentifier) {
        let before = state.lastConfirmed
        state.receive(snapshot, from: connection)
        guard let accepted = state.lastConfirmed, accepted != before else { return }
        // A mark on the watch shows on the phone too, and stays until cleared (PLAN §5).
        // ManOverboard keeps, across relaunches, which watch marks it took (with the
        // sequence that delivered each) and which were cleared, by mark ID.
        if ManOverboard.shared.applyMirrored(
            accepted.watchMarks, clearedByWatch: accepted.manOverboardCleared, sessionID: accepted.sessionID,
            sequence: accepted.sequence)
        {
            Haptics.play(.manOverboard)
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
            // `-demoWatchMOB`: the watch has marked man-overboard 150 m north of the demo
            // origin (a fake position, like the rest of the demo).
            var mark: ManOverboard.Mark?
            if ProcessInfo.processInfo.arguments.contains("-demoWatchMOB") {
                let point = Geo.destination(
                    lat: DemoFeed.origin.lat, lon: DemoFeed.origin.lon, bearing: 0, distance: 150)
                mark = ManOverboard.Mark(
                    latitude: point.lat, longitude: point.lon, markedAt: .now, positionAt: .now, positionAge: 0)
            }
            state.connect(connection)
            receive(
                WorkoutMirrorSnapshot(
                    sessionID: UUID(), sequence: 1, sport: .canoe, sentAt: .now, readings: readings,
                    manOverboard: mark, manOverboardMarks: mark.map { [$0] } ?? [], manOverboardCleared: []),
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
        events.yield(.stopped(workoutSession))
    }
}
