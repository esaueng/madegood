import AlarmKit
import AppIntents
import Observation
import SwiftUI
import WaterKit

/// AlarmKit owns delivery even when the app cannot receive a location callback.
@MainActor
@Observable
final class AnchorGPSWatchdog {
    private let system: AnchorSystemAlarms
    private var loss = AnchorGPSLoss()
    private var knownAlarms = AnchorGPSLoss.Alarms()
    private var update: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var periodicCheck: Task<Void, Never>?
    private var retryMultiplier = 1
    private var reconcileRequested = false
    private var isActive = false
    private var needsLegacyDeadline = false
    private let clock: () -> ClockReading
    private let defaults: UserDefaults?
    private let retryDelay: Duration
    private let checkInterval: Duration
    private(set) var hasSystemAlarm = false
    private(set) var hasSoundingAlarm = false

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
        let alarms: AnchorGPSLoss.Alarms?
    }

    private static let storageKey = "anchorWatch.watchdog"
    private enum ScheduleError: Error { case noFreeSlot }

    // Stable IDs survive relaunch. The third slot allows renewal while an old
    // alarm is still sounding and another is pending.
    private static let slots = [
        UUID(uuidString: "6D1D54FC-BB7A-41D6-80E7-E777EC3F9DAC")!,
        UUID(uuidString: "898CF3F4-3EE4-4CF2-83B9-EFC5A017EB58")!,
        UUID(uuidString: "E59F97B2-3254-46DF-ADDF-A09065F9087B")!,
    ]

    init(
        system: AnchorSystemAlarms? = nil,
        clock: @escaping () -> ClockReading = { .live },
        defaults: UserDefaults? = .standard,
        retryDelay: Duration = .seconds(1),
        checkInterval: Duration = .seconds(60)
    ) {
        self.system = system ?? .live(slots: Self.slots, title: "Check anchor and GPS")
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
        knownAlarms = saved?.alarms ?? .init()
        hasSystemAlarm = false
        needsLegacyDeadline = restoring && saved == nil
        if !needsLegacyDeadline { persistDeadline() }
        updatePeriodicCheck()
        reconcile()
    }

    func renew(fixAge: TimeInterval, assessment: AnchorAlarm.FixAssessment) {
        let previous = loss.request
        loss.recordFix(at: clock().uptime - fixAge, assessment: assessment)
        guard loss.request != previous else { return }
        needsLegacyDeadline = false
        persistDeadline()
        enqueueReconciliation()
    }

    func observeAlarmChanges(onChange: @MainActor (AnchorSystemAlarms.Snapshot) -> Void = { _ in }) async {
        await system.observeChanges { snapshot in
            let sounding = snapshot.sounding.intersection(Self.slots)
            // Keep alerting transitions even when an async schedule delays a
            // fresh read until after the user has already tapped Stop.
            if !sounding.isSubset(of: knownAlarms.sounding) {
                knownAlarms.sounding.formUnion(sounding)
                persistDeadline()
            }
            hasSoundingAlarm = !sounding.isEmpty
            enqueueReconciliation()
            onChange(snapshot)
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
                enqueueReconciliation()
            }
        }
    }

    func stopSoundingAlarms() {
        guard let snapshot = try? system.snapshot() else { return }
        for id in snapshot.sounding {
            if (try? system.stopSounding(id)) == true {
                knownAlarms.sounding.remove(id)
                knownAlarms.pending.removeValue(forKey: id)
                loss.snooze(at: clock().uptime)
                persistDeadline()
            }
        }
        reconcile()
    }

    /// Foreground and authorization changes can clear an error during backoff.
    func reconcile() {
        retry?.cancel()
        retry = nil
        retryMultiplier = 1
        enqueueReconciliation()
    }

    func reconcileAfterSystemStop(id: UUID) async {
        guard Self.slots.contains(id) else { return }
        // A Stop action confirms that a known pending alarm fired, even if a
        // clock change or delayed observation hid the alerting transition.
        if knownAlarms.pending[id] != nil {
            knownAlarms.sounding.insert(id)
            persistDeadline()
        }
        reconcile()
        await update?.value
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
                    retryMultiplier = 1
                } catch {
                    scheduleRetry()
                    return
                }
            }
        }
    }

    func stop() {
        loss.disarm()
        knownAlarms = .init()
        hasSystemAlarm = false
        needsLegacyDeadline = false
        persistDeadline()
        updatePeriodicCheck()
        // Cancel promptly, then sweep again if a schedule was still in flight.
        if let snapshot = try? system.snapshot() {
            hasSoundingAlarm = !snapshot.sounding.isEmpty
            try? cancelPending(in: snapshot, keeping: nil)
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
        let snapshot: AnchorSystemAlarms.Snapshot
        do {
            snapshot = try system.snapshot()
        } catch {
            hasSystemAlarm = false
            throw error
        }
        hasSoundingAlarm = !snapshot.sounding.isEmpty
        guard loss.request != nil else {
            try cancelPending(in: snapshot, keeping: nil)
            return
        }

        let now = clock()
        var changed = needsLegacyDeadline || knownAlarms != snapshot
        if needsLegacyDeadline {
            needsLegacyDeadline = false
            if let fallback = snapshot.earliestPending {
                loss.adoptLegacyAlarm(remaining: fallback.value.timeIntervalSince(now.wallTime), at: now.uptime)
            }
        }
        if !snapshot.stoppedAlarms(since: knownAlarms).isEmpty {
            loss.snooze(at: now.uptime)
            changed = true
        }
        knownAlarms = snapshot
        if changed { persistDeadline() }
        guard let request = loss.request else { return }

        let desired = now.wallTime.addingTimeInterval(request.delay(at: now.uptime))
        hasSystemAlarm = hasSoundingAlarm || snapshot.pending.values.contains {
            $0 >= now.wallTime && $0.timeIntervalSince(desired) <= 1
        }
        switch request.plan(for: snapshot, slots: Self.slots, at: now.uptime, wallTime: now.wallTime) {
        case .keep(let current):
            hasSystemAlarm = true
            try cancelPending(in: snapshot, keeping: current)
            return
        case .waitForStop:
            return
        case .makeSpace(let fallback):
            try cancelPending(in: snapshot, keeping: fallback)
            throw ScheduleError.noFreeSlot
        case .install(let next):
            try await system.schedule(next, desired)
            if loss.isCurrent(request) {
                knownAlarms.pending[next] = desired
                hasSystemAlarm = true
                persistDeadline()
            }
        }
        // Read actual AlarmKit state again before touching the previous alarm.
        // The old one may now be ringing, or the user may have disarmed.
        reconcileRequested = true
    }

    private func cancelPending(in snapshot: AnchorSystemAlarms.Snapshot, keeping id: UUID?) throws {
        for other in snapshot.pendingToCancel(keeping: id) {
            guard let deadline = snapshot.pending[other],
                canCancelPendingAnchorAlarm(deadline: deadline, now: clock().wallTime)
            else { continue }
            if try system.cancelPending(other), knownAlarms.pending.removeValue(forKey: other) != nil {
                persistDeadline()
            }
        }
    }

    private func persistDeadline() {
        let data = loss.checkpoint(at: clock().uptime).flatMap {
            try? JSONEncoder().encode(SavedDeadline(deadline: $0, alarms: knownAlarms))
        }
        defaults?.set(data, forKey: Self.storageKey)
    }
}

struct AnchorSystemAlarms {
    typealias Snapshot = AnchorGPSLoss.Alarms

    var snapshot: @MainActor () throws -> Snapshot
    var schedule: @MainActor (UUID, Date) async throws -> Void
    var cancelPending: @MainActor (UUID) throws -> Bool
    var stopSounding: @MainActor (UUID) throws -> Bool
    var observeChanges: @MainActor (@MainActor (Snapshot) -> Void) async -> Void

    @MainActor
    private static func snapshot(of alarms: [Alarm], slots: [UUID]? = nil) -> Snapshot {
        var snapshot = Snapshot()
        for alarm in alarms where slots?.contains(alarm.id) ?? true {
            if alarm.state == .alerting {
                snapshot.sounding.insert(alarm.id)
            } else if alarm.state == .scheduled, case .fixed(let deadline) = alarm.schedule {
                snapshot.pending[alarm.id] = deadline
            }
        }
        return snapshot
    }

    static func live(slots: [UUID], title: LocalizedStringResource) -> Self {
        Self(
            snapshot: { try snapshot(of: AlarmManager.shared.alarms, slots: slots) },
            schedule: { id, deadline in
                let configuration = anchorAlarmConfiguration(id: id, title: title, deadline: deadline)
                _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
            },
            cancelPending: { try cancelPendingAnchorAlarm(id: $0) },
            stopSounding: { try stopSoundingAnchorAlarm(id: $0) },
            observeChanges: { changed in
                for await alarms in AlarmManager.shared.alarmUpdates { changed(snapshot(of: alarms)) }
            }
        )
    }
}

func canCancelPendingAnchorAlarm(deadline: Date, now: Date) -> Bool {
    // AlarmKit offers no atomic check-and-cancel. Leave a 10 s margin for
    // app preemption and daemon latency between the snapshot and cancellation.
    deadline.timeIntervalSince(now) > 10
}

@MainActor
@discardableResult
func cancelPendingAnchorAlarm(id: UUID) throws -> Bool {
    let manager = AlarmManager.shared
    guard let alarm = try manager.alarms.first(where: { $0.id == id }),
        alarm.state == .scheduled, case .fixed(let deadline) = alarm.schedule,
        canCancelPendingAnchorAlarm(deadline: deadline, now: .now)
    else { return false }
    try manager.cancel(id: id)
    return true
}

@MainActor
@discardableResult
func stopSoundingAnchorAlarm(id: UUID) throws -> Bool {
    let manager = AlarmManager.shared
    guard try manager.alarms.contains(where: { $0.id == id && $0.state == .alerting }) else { return false }
    try manager.stop(id: id)
    return true
}

// AlarmKit handles Stop. The intent lets reconciliation run in the app process
// even when the user stops an alarm from the Lock Screen.
struct AnchorAlarmStopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop anchor alarm"
    static let isDiscoverable = false

    @Parameter(title: "Alarm identifier") var alarmID: String

    init() {}

    init(id: UUID) {
        alarmID = id.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) {
            await AnchorWatch.shared.reconcileAfterSystemStop(id: id)
        }
        return .result()
    }
}

struct AnchorAlarmMetadata: AlarmMetadata {}

func anchorAlarmConfiguration(
    id: UUID, title: LocalizedStringResource, deadline: Date
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
    return .alarm(schedule: .fixed(deadline), attributes: attributes, stopIntent: AnchorAlarmStopIntent(id: id))
}
