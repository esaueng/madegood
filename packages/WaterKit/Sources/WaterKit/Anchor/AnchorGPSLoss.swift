/// Tracks the GPS watchdog deadline in seconds on the caller's sleep-inclusive
/// monotonic clock. The caller owns the system alarm and persists the checkpoint.
public struct AnchorGPSLoss: Sendable {
    public static let timeout = 120.0
    private static let renewalInterval = 30.0

    public struct Checkpoint: Codable, Sendable {
        fileprivate let measuredAt: Double
        fileprivate let deadline: Double
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

    /// The first usable fix near the circle resets the deadline. Coalesce later
    /// renewals so the existing alarm can fire earlier if fixes stop. Clearly
    /// outside fixes leave the fallback due while drift is being confirmed.
    public mutating func recordFix(at time: Double, assessment: AnchorAlarm.FixAssessment) {
        guard assessment == .withinOrUncertain, let armedAt, time >= armedAt,
            lastRenewal.map({ time - $0 >= Self.renewalInterval }) ?? true
        else { return }
        lastRenewal = time
        request = Request(generation: generation, deadline: time + Self.timeout, preservesExistingAlarm: false)
    }

    public func isCurrent(_ request: Request) -> Bool {
        self.request?.generation == request.generation
    }
}
