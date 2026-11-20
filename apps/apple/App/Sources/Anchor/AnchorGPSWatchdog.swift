import AlarmKit
import Observation
import SwiftUI
import WaterKit

/// A system alarm remains pending even when the app cannot receive a location callback.
/// Renew with a second slot before removing the old one, so an interruption during the
/// async schedule call leaves a fallback alarm in the system.
@MainActor
@Observable
final class AnchorGPSWatchdog {
    private let system: SystemAlarms
    private var loss = AnchorGPSLoss()
    private var update: Task<Void, Never>?
    private var applied: AnchorGPSLoss.Request?
    private var lastAttempt: (request: AnchorGPSLoss.Request, time: ContinuousClock.Instant)?
    private(set) var schedulingFailed = false

    struct SystemAlarms {
        enum Removal { case pending, any }

        struct Snapshot {
            var pending: [UUID: Date] = [:]
            var sounding: Set<UUID> = []
        }

        var snapshot: @MainActor () throws -> Snapshot
        var schedule: @MainActor (UUID, Date) async throws -> Void
        var remove: @MainActor (UUID, Removal) throws -> Void

        static let live = Self(
            snapshot: {
                var snapshot = Snapshot()
                for alarm in try AlarmManager.shared.alarms where slots.contains(alarm.id) {
                    if alarm.state == .alerting {
                        snapshot.sounding.insert(alarm.id)
                    } else if case .fixed(let deadline) = alarm.schedule {
                        snapshot.pending[alarm.id] = deadline
                    }
                }
                return snapshot
            },
            schedule: { id, deadline in
                let configuration = anchorAlarmConfiguration(title: "Anchor GPS unavailable", deadline: deadline)
                _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
            },
            remove: { id, mode in
                let manager = AlarmManager.shared
                guard let alarm = try manager.alarms.first(where: { $0.id == id }) else { return }
                if alarm.state == .alerting {
                    if mode == .any { try manager.stop(id: id) }
                } else {
                    try manager.cancel(id: id)
                }
            }
        )
    }

    // Stable IDs let a later launch preserve or clean up the system alarms.
    private static let slots = [
        UUID(uuidString: "6D1D54FC-BB7A-41D6-80E7-E777EC3F9DAC")!,
        UUID(uuidString: "898CF3F4-3EE4-4CF2-83B9-EFC5A017EB58")!,
    ]

    init(system: SystemAlarms = .live) {
        self.system = system
    }

    func start(restoring: Bool = false) {
        loss.arm(at: .now, restoring: restoring)
        reconcile()
    }

    func renew(fixAt time: ContinuousClock.Instant) {
        loss.recordUsableFix(at: time)
        reconcile()
    }

    func reconcile() {
        guard let request = loss.request, request != applied, update == nil else { return }
        if let lastAttempt, lastAttempt.request == request, lastAttempt.time.duration(to: .now) < .seconds(5) {
            return
        }
        lastAttempt = (request, .now)
        update = Task {
            defer {
                update = nil
                // Work remains queued across an in-flight schedule, including a new
                // arming with no fix to kick off its own update.
                if loss.request != request { reconcile() }
            }
            guard loss.isCurrent(request) else { return }

            var scheduledID: UUID?
            do {
                let snapshot = try system.snapshot()
                let current = snapshot.pending.max { $0.value < $1.value }?.key
                if request.preservesExistingAlarm, current != nil || !snapshot.sounding.isEmpty {
                    for id in snapshot.pending.keys where id != current { try system.remove(id, .pending) }
                } else if let next = Self.slots.first(where: {
                    snapshot.pending[$0] == nil && !snapshot.sounding.contains($0)
                }) ?? Self.slots.first(where: { $0 != current && !snapshot.sounding.contains($0) }) ?? current {
                    if snapshot.pending[next] != nil { try system.remove(next, .pending) }
                    scheduledID = next
                    let remaining = ContinuousClock.now.duration(to: request.deadline).components
                    let delay = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                    try await system.schedule(next, Date.now.addingTimeInterval(max(1, delay)))
                    guard loss.isCurrent(request) else {
                        try? system.remove(next, .any)
                        return
                    }
                    for id in snapshot.pending.keys where id != next { try system.remove(id, .pending) }
                }
                applied = request
                schedulingFailed = false
            } catch {
                if loss.isCurrent(request) {
                    schedulingFailed = true
                } else if let scheduledID {
                    try? system.remove(scheduledID, .any)
                }
            }
        }
    }

    func stop() {
        loss.disarm()
        applied = nil
        lastAttempt = nil
        schedulingFailed = false
        for id in Self.slots { try? system.remove(id, .any) }
    }
}

struct AnchorAlarmMetadata: AlarmMetadata {}

func anchorAlarmConfiguration(
    title: LocalizedStringResource, deadline: Date
) -> AlarmManager.AlarmConfiguration<AnchorAlarmMetadata> {
    let alert: AlarmPresentation.Alert
    if #available(iOS 26.1, *) {
        alert = .init(title: title)
    } else {
        let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill")
        alert = .init(title: title, stopButton: stop)
    }
    let attributes = AlarmAttributes<AnchorAlarmMetadata>(
        presentation: AlarmPresentation(alert: alert), tintColor: .red)
    return .alarm(schedule: .fixed(deadline), attributes: attributes)
}
