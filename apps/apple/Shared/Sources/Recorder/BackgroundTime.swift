import Foundation
import Synchronization

/// Background time for a stretch of work (`ProcessInfo.performExpiringActivity`), and
/// whether it is held right now.
///
/// The activity is granted asynchronously and can be denied or expire at any time, so the
/// work cannot simply start and hope: `run` asks first and waits (briefly) for the answer,
/// and the work checks `hasTime` before and during anything long. Work that must happen
/// whatever the answer (taking ownership of a WatchConnectivity file, which is deleted when
/// the callback returns) runs anyway; work that can be redone later (joining parts) is left
/// for later without it.
final class BackgroundTime: Sendable {
    enum State: Equatable, Sendable {
        /// Asked for; no answer yet.
        case pending
        /// Held.
        case granted
        /// Denied, or ran out: the process may be suspended at any moment.
        case expired
    }

    /// Asks the system for the activity. The block is called with `false` when it is held
    /// (and the activity lasts until the block returns), and with `true` when it is denied or
    /// about to end.
    typealias Request = @Sendable (_ reason: String, _ block: @escaping @Sendable (_ expired: Bool) -> Void) -> Void

    static let system: Request = { reason, block in
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason, using: block)
    }

    /// How long `run` waits for the system's answer before working without it.
    static let answerTimeout: TimeInterval = 2
    /// The longest the activity is held for one piece of work.
    static let longestHold: TimeInterval = 180

    private let state = Mutex(State.pending)

    var current: State { state.withLock { $0 } }
    /// Whether the activity is held now.
    var hasTime: Bool { current == .granted }

    /// Runs `work` on this thread, synchronously, after asking for background time and
    /// waiting up to `answerTimeout` for the answer. The activity is held until `work`
    /// returns (or `longestHold`); `work` reads `hasTime` to decide what it may start.
    static func run(
        _ reason: String, request: @escaping Request = system, answerTimeout: TimeInterval = answerTimeout,
        _ work: (BackgroundTime) -> Void
    ) {
        let time = BackgroundTime()
        let answered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        // Asked from another queue: if the system called the block on this thread, its wait
        // would block the work it is holding time for.
        DispatchQueue.global(qos: .userInitiated).async {
            request(reason) { expired in
                if expired {
                    time.state.withLock { $0 = .expired }
                    answered.signal()
                    return
                }
                time.state.withLock { if $0 == .pending { $0 = .granted } }
                answered.signal()
                // The activity lasts while this block runs.
                _ = finished.wait(timeout: .now() + longestHold)
            }
        }
        _ = answered.wait(timeout: .now() + answerTimeout)
        defer { finished.signal() }
        work(time)
    }
}
