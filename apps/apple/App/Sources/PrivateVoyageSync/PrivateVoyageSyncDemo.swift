#if DEBUG
    import Foundation
    import WaterKit

    extension PrivateVoyageSync {
        #if targetEnvironment(simulator)
            static func makeLoopbackDemo() -> PrivateVoyageSync? {
                let environment = ProcessInfo.processInfo.environment
                guard let port = environment["MADEGOOD_TEST_WORKER_PORT"].flatMap(UInt16.init), port > 0,
                    let accessToken = environment["MADEGOOD_TEST_VOYAGE_TOKEN"], !accessToken.isEmpty,
                    let accountID = environment["MADEGOOD_TEST_VOYAGE_ACCOUNT"], accountID.hasPrefix("synthetic-"),
                    let runID = environment["MADEGOOD_TEST_VOYAGES"].flatMap(UUID.init(uuidString:))
                else { return nil }
                let store = SyntheticVoyageCredentials()
                try? store.save(
                    VoyageCredentials(
                        binding: VoyageAccountBinding(accountID: accountID, signInID: runID),
                        tokens: VoyageTokenPair(accessToken: accessToken, refreshToken: "synthetic-unused")
                    ))
                return PrivateVoyageSync(
                    apiRoot: URL(string: "http://127.0.0.1:\(port)/api")!,
                    root: URL.temporaryDirectory.appending(path: "sync-\(runID)", directoryHint: .isDirectory),
                    transport: VoyageURLSession(),
                    store: store,
                    isDemo: true
                )
            }
        #endif

        static func makeDemo() -> PrivateVoyageSync {
            let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            return PrivateVoyageSync(
                apiRoot: URL(string: "https://voyage-sync.invalid/api")!,
                root: root,
                transport: SyntheticVoyageTransport(),
                store: SyntheticVoyageCredentials(),
                isDemo: true
            )
        }
    }

    @MainActor
    private final class SyntheticVoyageCredentials: VoyageCredentialStore {
        private var credentials: VoyageCredentials?
        func load() throws -> VoyageCredentials? { credentials }
        func save(_ credentials: VoyageCredentials?) throws { self.credentials = credentials }
    }

    @MainActor
    private final class SyntheticVoyageTransport: VoyageTransport {
        private var voyages: Set<String> = []
        private var legs: [String: String] = [:]

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if request.httpMethod == "POST", request.url?.path == "/api/auth/apple" {
                let body = Data(
                    """
                    {
                        "user": {
                            "id": "synthetic-account", "handle": "synthetic", "displayName": null,
                            "units": "metric", "defaultVisibility": "private", "createdAt": "2023-11-14T22:13:20.125Z"
                        },
                        "accessToken": "synthetic-access", "refreshToken": "synthetic-refresh"
                    }
                    """.utf8
                )
                return (body, response(request, 200))
            }
            guard request.httpMethod == "PUT", isAuthorized(request), let body = request.httpBody,
                var snapshot = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                let path = request.url?.pathComponents, path.starts(with: ["/", "api", "voyages"])
            else { throw VoyageAPIError.invalidResponse }

            switch path.count {
            case 4:
                voyages.insert(path[3])
            case 6 where path[4] == "legs" && voyages.contains(path[3]):
                legs[path[5]] = path[3]
                snapshot["voyageId"] = path[3]
            default:
                throw VoyageAPIError.invalidResponse
            }
            snapshot["id"] = path.last
            return (try JSONSerialization.data(withJSONObject: snapshot), response(request, 201))
        }

        func upload(_ request: URLRequest, file: URL, key: VoyageUploadKey) async throws -> HTTPURLResponse {
            let voyage = key.voyageID.uuidString.lowercased()
            let leg = key.legID.uuidString.lowercased()
            guard request.httpMethod == "PUT", isAuthorized(request), legs[leg] == voyage,
                request.url?.path == "/api/voyages/\(voyage)/legs/\(leg)/track",
                request.value(forHTTPHeaderField: "Content-Type") == "application/gzip",
                request.value(forHTTPHeaderField: "Content-Encoding") == nil,
                try TrackCodec.decode(Data(contentsOf: file)).sessionId == key.legID
            else { throw VoyageAPIError.invalidResponse }
            return response(request, 204)
        }

        func cancelStaleUploads(currentSignIn: () -> UUID?) async {}

        private func isAuthorized(_ request: URLRequest) -> Bool {
            request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access"
        }

        private func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        }
    }
#endif
