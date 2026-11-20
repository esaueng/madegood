import Foundation

/// Tracks the GPS watchdog deadline in seconds on the caller's sleep-inclusive
/// monotonic clock. The caller owns the system alarm and persists the checkpoint.
public struct AnchorGPSLoss: Sendable {
    public static let timeout = 120.0
    private static let renewalInterval = 30.0

    public struct Checkpoint: Codable, Sendable {
        fileprivate let measuredAt: Double
        fileprivate let deadline: Double
    }

    public enum AlarmPlan: Equatable, Sendable {
        case keep(UUID)
        case waitForStop
        case install(UUID)
        case makeSpace(keeping: UUID?)
    }

    public struct Request: Equatable, Sendable {
        public let generation: Int
        public let deadline: Double
        public let preservesExistingAlarm: Bool

        public func delay(at now: Double) -> Double {
            max(1, deadline - now)
        }

        /// Compare the system's fixed alarm with the current wall-clock projection
        /// of the monotonic deadline. An already-due alarm can also be imminent.
        public func matches(remaining: Double, at now: Double) -> Bool {
            if deadline <= now { return (-1...1.5).contains(remaining) }
            return abs(remaining - (deadline - now)) <= 1
        }

        public func plan(for alarms: Alarms, slots: [UUID], at now: Double, wallTime: Date) -> AlarmPlan {
            if let current = alarms.pending.first(where: {
                matches(remaining: $0.value.timeIntervalSince(wallTime), at: now)
            }) {
                return .keep(current.key)
            }
            if alarms.pending.isEmpty, !alarms.sounding.isEmpty, preservesExistingAlarm || deadline <= now {
                return .waitForStop
            }
            if let next = slots.first(where: { alarms.pending[$0] == nil && !alarms.sounding.contains($0) }) {
                return .install(next)
            }
            return .makeSpace(keeping: alarms.earliestPending?.key)
        }
    }

    /// The last known alarms let a later snapshot distinguish a disappeared
    /// pending backup from a one-shot alarm that fired and was stopped.
    public struct Alarms: Codable, Equatable, Sendable {
        public var pending: [UUID: Date]
        public var sounding: Set<UUID>

        public init(pending: [UUID: Date] = [:], sounding: Set<UUID> = []) {
            self.pending = pending
            self.sounding = sounding
        }

        public func stoppedAlarms(since previous: Self, wallTime: Date) -> Set<UUID> {
            let due = previous.pending.filter { $0.value <= wallTime }.keys
            return previous.sounding.union(due).subtracting(pending.keys).subtracting(sounding)
        }

        /// Keep at least one fallback until a replacement is installed.
        public func pendingToCancel(keeping id: UUID?) -> [UUID] {
            pending.keys.filter { $0 != id }
        }

        public var earliestPending: (key: UUID, value: Date)? {
            pending.min { $0.value < $1.value }
        }
    }

    public private(set) var request: Request?
    private var generation = 0
    private var armedAt: Double?
    private var lastRenewal: Double?

    public init() {}

    public mutating func arm(at now: Double, restoring: Bool = false, checkpoint: Checkpoint? = nil) {
        generation += 1
        armedAt = now
        lastRenewal = nil
        let deadline = checkpoint.map { now >= $0.measuredAt ? $0.deadline : now } ?? now + Self.timeout
        request = Request(generation: generation, deadline: deadline, preservesExistingAlarm: restoring)
    }

    public func checkpoint(at now: Double) -> Checkpoint? {
        request.map { Checkpoint(measuredAt: now, deadline: $0.deadline) }
    }

    /// Upgrade a fixed alarm written before monotonic checkpoints were stored.
    /// An implausibly distant wall date could have been shifted by a rollback.
    public mutating func adoptLegacyAlarm(remaining: Double, at now: Double) {
        guard request?.preservesExistingAlarm == true else { return }
        let deadline = now + ((0...Self.timeout).contains(remaining) ? remaining : 0)
        request = Request(generation: generation, deadline: deadline, preservesExistingAlarm: true)
    }

    public mutating func disarm() {
        armedAt = nil
        lastRenewal = nil
        request = nil
    }

    public mutating func snooze(at now: Double) {
        guard request != nil else { return }
        armedAt = now
        lastRenewal = nil
        request = Request(
            generation: generation, deadline: now + Self.timeout, preservesExistingAlarm: false)
    }

    /// The first usable fix near the circle resets the deadline. Allow one
    /// renewal interval of slack so coalesced fixes get the full timeout. Clearly
    /// outside fixes leave the fallback due while drift is being confirmed.
    public mutating func recordFix(at time: Double, assessment: AnchorAlarm.FixAssessment) {
        guard assessment == .withinOrUncertain, let armedAt, time >= armedAt,
            lastRenewal.map({ time - $0 >= Self.renewalInterval }) ?? true
        else { return }
        lastRenewal = time
        request = Request(
            generation: generation, deadline: time + Self.timeout + Self.renewalInterval,
            preservesExistingAlarm: false)
    }

    public func isCurrent(_ request: Request) -> Bool {
        self.request?.generation == request.generation
    }
}
