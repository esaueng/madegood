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
    private var retry: Task<Void, Never>?
    private var periodicCheck: Task<Void, Never>?
    private var retryMultiplier = 1
    private var reconcileRequested = false
    private var clearing = false
    private var cleanupFailed = false
    private var isActive = false
    private var needsLegacyDeadline = false
    private var supersededSlots: Set<UUID> = []
    private let clock: () -> ClockReading
    private let defaults: UserDefaults?
    private let retryDelay: Duration
    private let checkInterval: Duration
    private(set) var hasSystemAlarm = false
    private var straySounding: Set<UUID> = []
    var hasStraySoundingAlarm: Bool { !straySounding.isEmpty }

    struct ClockReading {
        let uptime: TimeInterval
        let wallTime: Date

        static var live: Self {
            // CLOCK_MONOTONIC_RAW includes time asleep and survives process relaunch.
            Self(uptime: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9, wallTime: .now)
        }
    }

    private struct SavedDeadline: Codable {
        let deadline: AnchorGPSLoss.Checkpoint
        let clearing: Bool
        let supersededSlots: Set<UUID>?
    }

    private static let storageKey = "anchorWatch.watchdog"

    struct SystemAlarms {
        enum Removal { case pending, any }

        struct Snapshot {
            var pending: [UUID: Date] = [:]
            var sounding: Set<UUID> = []
        }

        var snapshot: @MainActor () throws -> Snapshot
        var schedule: @MainActor (UUID, Date) async throws -> Void
        var remove: @MainActor (UUID, Removal) throws -> Void
        var observeChanges: @MainActor (@MainActor () -> Void) async -> Void

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
                let configuration = anchorAlarmConfiguration(title: "Check anchor and GPS", deadline: deadline)
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
            },
            observeChanges: { changed in
                for await _ in AlarmManager.shared.alarmUpdates { changed() }
            }
        )
    }

    // Stable IDs let a later launch preserve or clean up the system alarms.
    private static let slots = [
        UUID(uuidString: "6D1D54FC-BB7A-41D6-80E7-E777EC3F9DAC")!,
        UUID(uuidString: "898CF3F4-3EE4-4CF2-83B9-EFC5A017EB58")!,
    ]

    init(
        system: SystemAlarms = .live,
        clock: @escaping () -> ClockReading = { .live },
        defaults: UserDefaults? = .standard,
        retryDelay: Duration = .seconds(1),
        checkInterval: Duration = .seconds(15)
    ) {
        self.system = system
        self.clock = clock
        self.defaults = defaults
        self.retryDelay = retryDelay
        self.checkInterval = checkInterval
    }

    func start(restoring: Bool = false) {
        let saved = restoring
            ? defaults?.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(SavedDeadline.self, from: $0) }
            : nil
        loss.arm(at: clock().uptime, restoring: restoring, checkpoint: saved?.deadline)
        hasSystemAlarm = false
        clearing = !restoring || saved?.clearing == true
        if restoring { supersededSlots = saved?.supersededSlots ?? [] }
        needsLegacyDeadline = restoring && saved == nil
        if !needsLegacyDeadline { persistDeadline() }
        updatePeriodicCheck()
        reconcile()
    }

    func renew(fixAge: TimeInterval, assessment: AnchorAlarm.FixAssessment) {
        let previous = loss.request
        loss.recordFix(at: clock().uptime - fixAge, assessment: assessment)
        guard loss.request != previous else {
            if clearing || cleanupFailed { reconcile() }
            return
        }
        // Preserve alarms already sounding at the time of the fix. Pending
        // alarms can still fire during the async replacement or failed cleanup.
        if let snapshot = try? system.snapshot() {
            supersededSlots.formUnion(snapshot.pending.keys)
        }
        needsLegacyDeadline = false
        persistDeadline()
        if cleanupFailed { reconcile() } else { enqueueReconciliation() }
    }

    func observeAlarmChanges(onChange: @MainActor () -> Void = {}) async {
        await system.observeChanges {
            alarmSetChanged()
            onChange()
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        updatePeriodicCheck()
    }

    private func updatePeriodicCheck() {
        guard isActive, loss.request != nil else {
            periodicCheck?.cancel()
            periodicCheck = nil
            return
        }
        guard periodicCheck == nil else { return }
        periodicCheck = Task { [weak self, checkInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: checkInterval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                alarmSetChanged()
            }
        }
    }

    private func alarmSetChanged() {
        let hadCoverage = hasSystemAlarm
        let snapshot = try? readSnapshot()
        let foundStray = snapshot != nil && hasStraySoundingAlarm
        if foundStray { try? clearSlots(straySounding) }
        if (hadCoverage && !hasSystemAlarm) || foundStray {
            reconcile()
        } else if loss.request != nil || clearing || snapshot?.pending.isEmpty == false {
            enqueueReconciliation()
        }
    }

    func stopStrayAlarms() {
        guard (try? readSnapshot()) != nil else { return }
        try? clearSlots(straySounding)
        reconcile()
    }

    /// External events can clear an error condition while a retry is waiting.
    func reconcile() {
        retry?.cancel()
        retry = nil
        retryMultiplier = 1
        enqueueReconciliation()
    }

    private func enqueueReconciliation() {
        reconcileRequested = true
        guard update == nil, retry == nil else { return }
        update = Task {
            defer { update = nil }
            while reconcileRequested {
                reconcileRequested = false
                do {
                    try await reconcileOnce()
                    cleanupFailed = false
                    retryMultiplier = 1
                } catch {
                    // Keep retrying even when GPS delivers no further fixes.
                    scheduleRetry()
                    return
                }
            }
        }
    }

    func stop() {
        loss.disarm()
        hasSystemAlarm = false
        clearing = true
        needsLegacyDeadline = false
        persistDeadline()
        updatePeriodicCheck()
        // Try immediately. A failed removal or an in-flight schedule leaves
        // cleanup queued so both slots are swept again.
        do {
            try clearSlots(Self.slots)
            if update == nil { clearing = false }
        } catch {
            // The reconciler will retry failed removals.
        }
        reconcile()
    }

    private func scheduleRetry() {
        let delay = retryDelay * retryMultiplier
        retryMultiplier = min(retryMultiplier * 2, 60)
        retry = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.retry = nil
            self?.enqueueReconciliation()
        }
    }

    private func reconcileOnce() async throws {
        if clearing || loss.request == nil {
            // Read the ringing IDs before removing them so the app can offer
            // Stop if AlarmKit rejects the cancellation.
            _ = try? readSnapshot()
            try clearSlots(Self.slots)
            clearing = false
            persistDeadline()
        }
        guard var request = loss.request else { return }

        let snapshot = try readSnapshot()
        let sounding = snapshot.sounding.subtracting(straySounding)
        try clearSlots(straySounding)
        let now = clock()
        let fallback = snapshot.pending.min { $0.value < $1.value }
        if needsLegacyDeadline {
            needsLegacyDeadline = false
            if let fallback {
                loss.adoptLegacyAlarm(remaining: fallback.value.timeIntervalSince(now.wallTime), at: now.uptime)
                request = loss.request ?? request
            }
            persistDeadline()
        }

        let desired = now.wallTime.addingTimeInterval(request.delay(at: now.uptime))
        if let current = snapshot.pending.first(where: {
            request.matches(remaining: $0.value.timeIntervalSince(now.wallTime), at: now.uptime)
        }) {
            if supersededSlots.remove(current.key) != nil { persistDeadline() }
            try removeOtherPending(in: snapshot, keeping: current.key)
            return
        }
        if !sounding.isEmpty, request.preservesExistingAlarm || request.deadline <= now.uptime {
            try removeOtherPending(in: snapshot, keeping: nil)
            return
        }

        // Keep the earliest fallback installed during renewal. If an earlier
        // cleanup failed, remove the extra slot before attempting a replacement.
        try removeOtherPending(in: snapshot, keeping: fallback?.key)
        guard let next = Self.slots.first(where: { $0 != fallback?.key && !sounding.contains($0) })
        else { return }

        // Both IDs are stable and owned by this watchdog, including the slot
        // passed to an in-flight call. A new arming sweeps both before reuse.
        if supersededSlots.remove(next) != nil { persistDeadline() }
        do {
            try await system.schedule(next, desired)
        } catch {
            guard loss.isCurrent(request) else { return }
            throw error
        }
        guard loss.isCurrent(request) else { return }
        if loss.request != request, supersededSlots.insert(next).inserted {
            persistDeadline()
        }
        hasSystemAlarm = true
        if let fallback { try removeSlot(fallback.key, supersededSlots.contains(fallback.key) ? .any : .pending) }
    }

    private func readSnapshot() throws -> SystemAlarms.Snapshot {
        let snapshot: SystemAlarms.Snapshot
        do {
            snapshot = try system.snapshot()
        } catch {
            hasSystemAlarm = false
            throw error
        }
        guard let request = loss.request, !clearing else {
            hasSystemAlarm = false
            straySounding = snapshot.sounding
            return snapshot
        }
        let now = clock()
        let desired = now.wallTime.addingTimeInterval(request.delay(at: now.uptime))
        straySounding = snapshot.sounding.intersection(supersededSlots)
        hasSystemAlarm = !snapshot.sounding.subtracting(straySounding).isEmpty || snapshot.pending.values.contains {
            $0.timeIntervalSince(now.wallTime) >= -1 && $0.timeIntervalSince(desired) <= 1
        }
        return snapshot
    }

    private func clearSlots(_ ids: some Sequence<UUID>) throws {
        var failure: (any Error)?
        for id in ids {
            do { try removeSlot(id, .any) } catch { failure = error }
        }
        if let failure { throw failure }
    }

    private func removeOtherPending(in snapshot: SystemAlarms.Snapshot, keeping id: UUID?) throws {
        for other in snapshot.pending.keys where other != id {
            try removeSlot(other, supersededSlots.contains(other) ? .any : .pending)
        }
    }

    private func removeSlot(_ id: UUID, _ mode: SystemAlarms.Removal) throws {
        do {
            try system.remove(id, mode)
        } catch {
            cleanupFailed = true
            throw error
        }
        if mode == .any {
            straySounding.remove(id)
            if supersededSlots.remove(id) != nil { persistDeadline() }
        }
    }

    private func persistDeadline() {
        let data = loss.checkpoint(at: clock().uptime).flatMap {
            try? JSONEncoder().encode(
                SavedDeadline(deadline: $0, clearing: clearing, supersededSlots: supersededSlots))
        }
        defaults?.set(data, forKey: Self.storageKey)
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
