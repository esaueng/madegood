/// Tracks the GPS-loss deadline for the current arming. A caller schedules the
/// alarm outside the process and uses the generation to reject stale completions.
public struct AnchorGPSLoss: Sendable {
    public static let timeout: Duration = .seconds(120)
    private static let renewalInterval: Duration = .seconds(15)

    public struct Request: Equatable, Sendable {
        public let generation: Int
        public let deadline: ContinuousClock.Instant
        public let preservesExistingAlarm: Bool
    }

    public private(set) var request: Request?
    private var generation = 0
    private var armedAt: ContinuousClock.Instant?
    private var lastRenewal: ContinuousClock.Instant?

    public init() {}

    public mutating func arm(at now: ContinuousClock.Instant, restoring: Bool = false) {
        generation += 1
        armedAt = now
        lastRenewal = nil
        request = Request(generation: generation, deadline: now + Self.timeout, preservesExistingAlarm: restoring)
    }

    public mutating func disarm() {
        armedAt = nil
        lastRenewal = nil
        request = nil
    }

    /// The first usable fix replaces the arming deadline. Subsequent fixes are
    /// coalesced to limit how often the system alarm is replaced.
    public mutating func recordUsableFix(at time: ContinuousClock.Instant) {
        guard let armedAt, time >= armedAt,
            lastRenewal.map({ $0.duration(to: time) >= Self.renewalInterval }) ?? true
        else { return }
        lastRenewal = time
        request = Request(generation: generation, deadline: time + Self.timeout, preservesExistingAlarm: false)
    }

    public func isCurrent(_ request: Request) -> Bool {
        self.request?.generation == request.generation
    }
}
