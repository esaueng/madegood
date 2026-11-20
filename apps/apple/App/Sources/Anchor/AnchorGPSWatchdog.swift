import AlarmKit
import Observation
import SwiftUI

/// A system alarm remains pending even when the app cannot receive a location callback.
/// Renew with a second slot before removing the old one, so an interruption during the
/// async schedule call leaves a fallback alarm in the system.
@MainActor
@Observable
final class AnchorGPSWatchdog {
    private let manager = AlarmManager.shared
    private var update: Task<Void, Never>?
    private var generation = 0
    private var lastAttempt: ContinuousClock.Instant?
    private(set) var schedulingFailed = false

    struct Schedule {
        static let ids = [
            UUID(uuidString: "6D1D54FC-BB7A-41D6-80E7-E777EC3F9DAC")!,
            UUID(uuidString: "898CF3F4-3EE4-4CF2-83B9-EFC5A017EB58")!,
        ]
        static let timeout: TimeInterval = 120
        static let renewalInterval: TimeInterval = 15

        let id: UUID
        let deadline: Date

        static func renewal(fixTime: Date, pending: [UUID: Date], sounding: Set<UUID>) -> Schedule? {
            let deadline = fixTime.addingTimeInterval(timeout)
            let current = pending.max { $0.value < $1.value }
            if let current, abs(current.value.timeIntervalSince(deadline)) < renewalInterval { return nil }
            guard
                let replacement = ids.first(where: { pending[$0] == nil && !sounding.contains($0) })
                    ?? ids.first(where: { $0 != current?.key && !sounding.contains($0) })
                    // With the other slot already ringing, replace the pending one in place.
                    ?? current?.key
            else { return nil }
            return Schedule(id: replacement, deadline: deadline)
        }
    }

    func renew(fixAge: Duration) {
        guard update == nil, lastAttempt.map({ $0.duration(to: .now) >= .seconds(5) }) ?? true else { return }
        lastAttempt = .now
        let age = fixAge.components
        let fixTime = Date.now.addingTimeInterval(-Double(age.seconds) - Double(age.attoseconds) / 1e18)
        let generation = self.generation
        update = Task {
            defer { update = nil }
            guard generation == self.generation else { return }
            do {
                let existing = try manager.alarms.filter { Schedule.ids.contains($0.id) }
                var pending: [UUID: Date] = [:]
                var sounding: Set<UUID> = []
                for alarm in existing {
                    if alarm.state == .alerting {
                        sounding.insert(alarm.id)
                    } else if case .fixed(let deadline) = alarm.schedule {
                        pending[alarm.id] = deadline
                    }
                }
                if let next = Schedule.renewal(fixTime: fixTime, pending: pending, sounding: sounding) {
                    if pending[next.id] != nil { try manager.cancel(id: next.id) }
                    let configuration = anchorAlarmConfiguration(
                        title: "Anchor GPS unavailable", deadline: next.deadline)
                    _ = try await AlarmManager.shared.schedule(id: next.id, configuration: configuration)
                    guard generation == self.generation else {
                        removeSystemAlarms()
                        return
                    }
                    for id in pending.keys where id != next.id { try manager.cancel(id: id) }
                } else if pending.count > 1, let newest = pending.max(by: { $0.value < $1.value }) {
                    for id in pending.keys where id != newest.key { try manager.cancel(id: id) }
                }
                schedulingFailed = false
            } catch {
                if generation == self.generation { schedulingFailed = true }
            }
        }
    }

    func stop() {
        generation += 1
        lastAttempt = nil
        schedulingFailed = false
        removeSystemAlarms()
    }

    private func removeSystemAlarms() {
        for alarm in (try? manager.alarms) ?? [] where Schedule.ids.contains(alarm.id) {
            if alarm.state == .alerting {
                try? manager.stop(id: alarm.id)
            } else {
                try? manager.cancel(id: alarm.id)
            }
        }
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
