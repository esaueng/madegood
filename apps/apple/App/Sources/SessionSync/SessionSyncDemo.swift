#if DEBUG
    import Foundation
    import WaterKit

    extension SessionSync {
        /// `-demoSessionSync`: a synthetic account and an in-process server, for UI tests
        /// and design review. Nothing leaves the device. The first track upload of a
        /// windsurfing session is refused as too large, so Retry can be exercised.
        static func makeDemo() -> SessionSync {
            let root = URL.temporaryDirectory.appending(path: "SessionSyncDemo-" + UUID().uuidString)
            let preferences = UserDefaults(suiteName: "SessionSyncDemo-" + UUID().uuidString) ?? .standard
            return SessionSync(
                apiRoot: URL(string: "https://session-sync.invalid/api")!,
                root: root,
                transport: SyntheticSessionTransport(),
                store: SyntheticSessionCredentials(),
                preferences: preferences,
                isDemo: true
            )
        }
    }

    @MainActor
    private final class SyntheticSessionCredentials: VoyageCredentialStore {
        private var credentials: VoyageCredentials?
        func load() throws -> VoyageCredentials? { credentials }
        func save(_ credentials: VoyageCredentials?) throws { self.credentials = credentials }
    }

    @MainActor
    private final class SyntheticSessionTransport: SessionSyncTransport {
        private var sessions: [String: String] = [:]
        private var refusedTracks: Set<String> = []

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await Task.sleep(for: .milliseconds(300))
            if request.httpMethod == "POST", request.url?.path == "/api/auth/apple" {
                let body = """
                    {
                        "user": {
                            "id": "synthetic-account", "handle": "synthetic", "displayName": null,
                            "units": "metric", "defaultVisibility": "private", "createdAt": "2023-11-14T22:13:20.125Z"
                        },
                        "accessToken": "synthetic-access", "refreshToken": "synthetic-refresh"
                    }
                    """
                return (Data(body.utf8), response(request, 200))
            }
            guard request.httpMethod == "PUT", isAuthorized(request), let body = request.httpBody,
                let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                let sport = fields["sport"] as? String, let startedAt = fields["startedAt"] as? String,
                let path = request.url?.pathComponents, path.count == 4, path[2] == "sessions"
            else { throw VoyageAPIError.invalidResponse }
            let id = path[3]
            let created = sessions.updateValue(sport, forKey: id) == nil
            let session: [String: Any] = [
                "id": id, "sport": sport, "title": NSNull(), "notes": NSNull(), "visibility": "private",
                "startedAt": startedAt, "endedAt": NSNull(), "durationS": NSNull(), "movingS": NSNull(),
                "distanceM": NSNull(), "maxSpeedMps": NSNull(), "avgSpeedMps": NSNull(), "summary": NSNull(),
                "analyzerVersion": NSNull(), "hasTrack": false, "isOwner": true,
                "createdAt": "2023-11-14T22:13:20.125Z", "updatedAt": "2023-11-14T22:13:20.125Z",
            ]
            return (try JSONSerialization.data(withJSONObject: session), response(request, created ? 201 : 200))
        }

        func upload(_ request: URLRequest, file: URL, taskDescription: String) async throws -> HTTPURLResponse {
            try await Task.sleep(for: .milliseconds(300))
            guard let path = request.url?.pathComponents, path.count == 5, path[4] == "track",
                request.httpMethod == "PUT", isAuthorized(request),
                request.value(forHTTPHeaderField: "Content-Type") == "application/gzip",
                let sport = sessions[path[3]]
            else { return response(request, 404) }
            let track = try TrackCodec.decode(Data(contentsOf: file))
            guard track.sessionId.uuidString.lowercased() == path[3] else { return response(request, 400) }
            if sport == Sport.windsurfing.rawValue, refusedTracks.insert(path[3]).inserted {
                return response(request, 413)
            }
            return response(request, 204)
        }

        func upload(_ request: URLRequest, file: URL, key: VoyageUploadKey) async throws -> HTTPURLResponse {
            throw URLError(.unsupportedURL)
        }

        func cancelStaleUploads(currentSignIn: () -> UUID?) async {}
        func activate(onCompletion: @escaping @MainActor (String, Int?) -> Void) {}
        func reconcileUploads(keep: (String?, URLRequest?) -> Bool) async {}

        private func isAuthorized(_ request: URLRequest) -> Bool {
            request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access"
        }

        private func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
        }
    }
#endif
