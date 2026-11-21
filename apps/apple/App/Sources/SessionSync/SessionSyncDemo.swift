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
        /// Settings → Sharing: the account's switch and two synthetic shared sessions.
        private var sharingEnabled = true
        private var shared: [[String: Any]] = [
            [
                "id": "00000000-0000-4000-8000-000000000001", "sport": "sailing", "title": "Harbour race",
                "visibility": "public", "startedAt": "2000-01-02T10:00:00.000Z",
            ],
            [
                "id": "00000000-0000-4000-8000-000000000002", "sport": "kayak", "title": NSNull(),
                "visibility": "unlisted", "startedAt": "2000-01-01T10:00:00.000Z",
            ],
        ]

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await Task.sleep(for: .milliseconds(300))
            if request.httpMethod == "POST", request.url?.path == "/api/auth/apple" {
                let body = """
                    {
                        "user": {
                            "id": "synthetic-account", "handle": "synthetic", "displayName": null,
                            "units": "metric", "defaultVisibility": "private", "sharingEnabled": true,
                            "createdAt": "2023-11-14T22:13:20.125Z"
                        },
                        "accessToken": "synthetic-access", "refreshToken": "synthetic-refresh"
                    }
                    """
                return (Data(body.utf8), response(request, 200))
            }
            if request.httpMethod == "DELETE", request.url?.path == "/api/me", isAuthorized(request),
                let body = request.httpBody,
                (try JSONSerialization.jsonObject(with: body) as? [String: String])?["userId"] == "synthetic-account"
            {
                sessions = [:]
                return (Data(), response(request, 202))
            }
            if let sharing = try sharingResponse(request) { return sharing }
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

        /// GET/PATCH /me and GET /sessions?shared=true, PATCH /sessions/{id} {visibility}.
        private func sharingResponse(_ request: URLRequest) throws -> (Data, HTTPURLResponse)? {
            guard isAuthorized(request), let url = request.url else { return nil }
            let path = url.pathComponents
            let body = try request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let me: () throws -> Data = { [self] in
                try JSONSerialization.data(withJSONObject: [
                    "id": "synthetic-account", "handle": "synthetic", "displayName": NSNull(), "units": "metric",
                    "defaultVisibility": "private", "sharingEnabled": sharingEnabled,
                    "createdAt": "2023-11-14T22:13:20.125Z",
                ])
            }
            switch (request.httpMethod, path) {
            case ("GET", ["/", "api", "me"]):
                return (try me(), response(request, 200))
            case ("PATCH", ["/", "api", "me"]):
                if let enabled = body?["sharingEnabled"] as? Bool {
                    sharingEnabled = enabled
                    if !enabled { shared = [] }
                }
                return (try me(), response(request, 200))
            case ("GET", ["/", "api", "sessions"]):
                let page: [String: Any] = ["sessions": shared, "nextCursor": NSNull()]
                return (try JSONSerialization.data(withJSONObject: page), response(request, 200))
            case ("PATCH", let parts) where parts.count == 4 && parts[2] == "sessions":
                guard body?["visibility"] as? String == "private" else { return (Data(), response(request, 400)) }
                shared.removeAll { $0["id"] as? String == parts[3] }
                return (Data("{}".utf8), response(request, 200))
            default:
                return nil
            }
        }

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
