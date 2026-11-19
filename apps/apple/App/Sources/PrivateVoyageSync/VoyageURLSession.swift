import Foundation

/// Keep the upload task attached when iOS suspends the app. Acknowledgements are
/// journalled by the outbox, so a completion lost at process exit can be replayed.
/// Session sync (SessionSync) uses its own instance under `sessionTrackIdentifier`.
@MainActor
final class VoyageURLSession: NSObject, SessionSyncTransport, URLSessionTaskDelegate {
    static let identifier = (Bundle.main.bundleIdentifier ?? "app.madegood") + ".private-voyage-track"
    static let sessionTrackIdentifier = (Bundle.main.bundleIdentifier ?? "app.madegood") + ".session-track"

    /// The background session's identifier.
    let backgroundIdentifier: String

    init(backgroundIdentifier: String = VoyageURLSession.identifier) {
        self.backgroundIdentifier = backgroundIdentifier
    }

    private lazy var foreground = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    private lazy var background: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        config.httpShouldSetCookies = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    private var waiters: [Int: CheckedContinuation<HTTPURLResponse, Error>] = [:]
    private var inspectingTasks = false
    private var completedDuringInspection: [Int: Result<HTTPURLResponse, Error>] = [:]
    private var backgroundCompletion: (() -> Void)?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await foreground.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoyageAPIError.invalidResponse }
        return (data, http)
    }

    func upload(_ request: URLRequest, file: URL, key: VoyageUploadKey) async throws -> HTTPURLResponse {
        try await upload(request, file: file, taskDescription: key.taskDescription)
    }

    func upload(_ request: URLRequest, file: URL, taskDescription: String) async throws -> HTTPURLResponse {
        inspectingTasks = true
        let existing = await background.allTasks
        inspectingTasks = false
        let finished = completedDuringInspection
        completedDuringInspection.removeAll()
        try Task.checkCancellation()

        let match = existing.first {
            $0.taskDescription == taskDescription && $0.originalRequest?.url == request.url
        }
        if let match, let result = finished[match.taskIdentifier] { return try result.get() }
        let task = match ?? background.uploadTask(with: request, fromFile: file)
        task.taskDescription = taskDescription
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[task.taskIdentifier] = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func cancelStaleUploads(currentSignIn: () -> UUID?) async {
        let tasks = await background.allTasks
        guard !Task.isCancelled else { return }
        let prefix = currentSignIn().map { $0.uuidString.lowercased() + "/" }
        for task in tasks where prefix.map({ task.taskDescription?.hasPrefix($0) != true }) ?? true {
            task.cancel()
        }
    }

    func reconnect(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        _ = background
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        MainActor.assumeIsolated {
            guard session === background else { return }
            let result = Result<HTTPURLResponse, Error> {
                if let error { throw error }
                guard let http = task.response as? HTTPURLResponse else { throw VoyageAPIError.invalidResponse }
                return http
            }
            if let waiter = waiters.removeValue(forKey: task.taskIdentifier) {
                waiter.resume(with: result)
            } else if inspectingTasks {
                completedDuringInspection[task.taskIdentifier] = result
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            let completion = backgroundCompletion
            backgroundCompletion = nil
            completion?()
        }
    }
}
