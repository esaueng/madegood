import Observation
import UIKit

@MainActor @Observable
final class PrivateVoyageSync {
    static let shared: PrivateVoyageSync? = {
        #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-localVoyageSharing") {
                return makeLoopbackDemo()
            }
        #endif
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-demoPrivateVoyageSync") {
                return makeDemo()
            }
        #endif
        return nil
    }()

    let account: VoyageAccount
    let outbox: VoyageOutbox
    let isDemo: Bool
    let liveSharing: LiveVoyageSharing?
    private(set) var outboxUnavailable = false
    private let transport: any VoyageTransport
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var wake: Task<Void, Never>?

    init(
        apiRoot: URL, root: URL, transport: any VoyageTransport,
        store: any VoyageCredentialStore, isDemo: Bool = false
    ) {
        let api = VoyageAPI(baseURL: apiRoot, transport: transport)
        account = VoyageAccount(store: store, api: api)
        outbox = VoyageOutbox(root: root, account: account, api: api)
        self.transport = transport
        self.isDemo = isDemo
        liveSharing = LiveVoyageSharing(
            apiRoot: apiRoot,
            root: root.appending(path: "LiveSharing", directoryHint: .isDirectory),
            account: account, transport: transport, isDemo: isDemo
        )
    }

    /// A recorder should call this from an explicit private sync action, using the
    /// binding captured at that action. Finishing a recording alone stays local.
    func enqueue(_ leg: CompletedVoyageLeg, trackFile: URL, for binding: VoyageAccountBinding) throws {
        try enqueue(leg, for: binding) { try Data(contentsOf: trackFile) }
    }

    func enqueue(
        _ leg: CompletedVoyageLeg, for binding: VoyageAccountBinding, gzipTrack: () throws -> Data
    ) throws {
        try outbox.enqueue(leg, for: binding, gzipTrack: gzipTrack)
        kick()
    }

    func accountDidChange() async {
        liveSharing?.accountDidChange()
        let binding = account.binding
        if binding == nil {
            worker?.cancel()
            wake?.cancel()
            outboxUnavailable = false
        }
        await transport.cancelStaleUploads { account.binding?.signInID }
        guard !Task.isCancelled, account.binding == binding, let binding else { return }
        do {
            try outbox.restore(for: binding)
            kick()
        } catch {
            outboxUnavailable = true
        }
    }

    func signOut() async throws {
        do {
            try account.signOut()
        } catch {
            await accountDidChange()
            throw error
        }
        await accountDidChange()
    }

    func retryNow() {
        guard let binding = account.binding else { return }
        do {
            try outbox.retryFailures(for: binding)
            kick()
        } catch {
            outboxUnavailable = true
        }
    }

    func kick() {
        guard worker == nil, let binding = account.binding else { return }
        wake?.cancel()
        worker = Task {
            defer {
                worker = nil
                if account.binding != binding { kick() }
            }
            do {
                let retryAt = try await outbox.drain(for: binding)
                guard !Task.isCancelled, account.binding == binding else { return }
                outboxUnavailable = false
                if let retryAt {
                    wake = Task {
                        do {
                            try await Task.sleep(for: .seconds(max(0, retryAt.timeIntervalSinceNow)))
                        } catch { return }
                        kick()
                    }
                }
            } catch {
                if account.binding == binding { outboxUnavailable = true }
            }
        }
    }

    func reconnectUploads(identifier: String, completion: @escaping () -> Void) {
        guard identifier == VoyageURLSession.identifier, let transport = transport as? VoyageURLSession else {
            completion()
            return
        }
        transport.reconnect(completion: completion)
        Task { await accountDidChange() }
    }
}

final class VoyageSyncAppDelegate: VoyageLaunchDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard DemoOffWater.storage == nil, let sync = PrivateVoyageSync.shared else {
            completionHandler()
            return
        }
        sync.reconnectUploads(identifier: identifier, completion: completionHandler)
    }
}
