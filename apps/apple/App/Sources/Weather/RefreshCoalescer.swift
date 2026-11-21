/// Runs one refresh at a time. A caller that arrives while one is running waits for that
/// one to finish instead of returning at once, so pull-to-refresh keeps its spinner up
/// for the whole fetch rather than snapping back.
@MainActor
final class RefreshCoalescer {
    private var running: Task<Void, Never>?
    /// Calls that joined a running refresh instead of starting one (read by tests).
    private(set) var joined = 0

    var isRunning: Bool { running != nil }

    func run(_ work: @escaping @MainActor () async -> Void) async {
        if let running {
            joined += 1
            await running.value
            return
        }
        let task = Task { await work() }
        running = task
        await task.value
        running = nil
    }
}
