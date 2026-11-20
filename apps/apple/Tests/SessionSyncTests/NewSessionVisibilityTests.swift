import Foundation
import Testing

@testable import PrivateVoyageSync

/// Settings → Account shows the account's "Visibility of new sessions" beside Sync sessions
/// (review of #133, finding 2): the server gives new uploads that visibility, so an Unlisted
/// or Public default shares them with no further step on the phone.
@MainActor
struct NewSessionVisibilityTests {
    @Test(arguments: NewSessionVisibility.allCases)
    func readsTheAccountDefaultFromGetMe(_ visibility: NewSessionVisibility) async throws {
        let rig = VisibilityRig()
        rig.transport.visibility = visibility.rawValue
        try await rig.signIn()

        #expect(try await AccountVisibility.fetch(account: rig.account, api: rig.api) == visibility)
        let request = try #require(rig.transport.requests.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }

    @Test func refreshesAnExpiredTokenOnce() async throws {
        let rig = VisibilityRig()
        rig.transport.visibility = "public"
        rig.transport.meStatuses = [401]
        try await rig.signIn()

        #expect(try await AccountVisibility.fetch(account: rig.account, api: rig.api) == .public)
        let gets = rig.transport.requests.filter { $0.httpMethod == "GET" }
        #expect(gets.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer access-1", "Bearer access-2"])
    }

    @Test func failsOnAnUnknownValueOrServerError() async throws {
        let rig = VisibilityRig()
        try await rig.signIn()
        rig.transport.visibility = "friends"
        await #expect(throws: VoyageAPIError.invalidResponse) {
            try await AccountVisibility.fetch(account: rig.account, api: rig.api)
        }
        rig.transport.meStatuses = [503]
        await #expect(throws: VoyageAPIError.self) {
            try await AccountVisibility.fetch(account: rig.account, api: rig.api)
        }
    }

    @Test func refusesWithoutASignIn() async throws {
        let rig = VisibilityRig()
        await #expect(throws: VoyageAccountError.signInRequired) {
            try await AccountVisibility.fetch(account: rig.account, api: rig.api)
        }
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func noticeNamesAutomaticSharingAndWhereToChangeIt() {
        let privateNotice = NewSessionVisibility.notice(for: .private)
        #expect(privateNotice.contains("private"))
        #expect(!privateNotice.contains("automatically"))
        for shared in [NewSessionVisibility.unlisted, .public] {
            let notice = NewSessionVisibility.notice(for: shared)
            #expect(notice.hasPrefix("New uploads will be \(shared.rawValue) automatically"))
            #expect(notice.contains("Settings on madegood.app"))
        }
        // Unknown: true whatever the setting is, never a promise that uploads are private.
        let unknown = NewSessionVisibility.notice(for: nil)
        #expect(unknown.contains("Unlisted or Public"))
        #expect(unknown.contains("automatically"))
        #expect(unknown.contains("Settings on madegood.app"))
        #expect(!unknown.localizedCaseInsensitiveContains("are private"))
    }
}

@MainActor
private final class VisibilityRig {
    let transport = VisibilityTransport()
    let account: VoyageAccount
    let api: SessionAPI

    init() {
        let base = URL(string: "https://synthetic.invalid/api")!
        account = VoyageAccount(store: MemoryStore(), api: VoyageAPI(baseURL: base, transport: transport))
        api = SessionAPI(baseURL: base, transport: transport)
    }

    func signIn() async throws {
        try await account.signIn(identityToken: "synthetic-identity", displayName: nil)
    }
}

@MainActor
private final class MemoryStore: VoyageCredentialStore {
    var credentials: VoyageCredentials?
    func load() throws -> VoyageCredentials? { credentials }
    func save(_ credentials: VoyageCredentials?) throws { self.credentials = credentials }
}

@MainActor
private final class VisibilityTransport: SessionSyncTransport {
    var requests: [URLRequest] = []
    var visibility = "private"
    var meStatuses: [Int] = []
    private var issued = 1

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        switch request.url!.path {
        case "/api/auth/apple":
            let body = """
                {
                    "user": {
                        "id": "synthetic-account", "handle": "synthetic", "displayName": null,
                        "units": "metric", "defaultVisibility": "private", "createdAt": "2023-11-14T22:13:20.125Z"
                    },
                    "accessToken": "access-1", "refreshToken": "refresh-1"
                }
                """
            return (Data(body.utf8), response(request, 200))
        case "/api/auth/refresh":
            issued += 1
            return (Data(#"{"accessToken": "access-\#(issued)", "refreshToken": "refresh-\#(issued)"}"#.utf8), response(request, 200))
        case "/api/me" where request.httpMethod == "GET":
            let status = meStatuses.isEmpty ? 200 : meStatuses.removeFirst()
            guard status == 200 else {
                return (Data(#"{"error":"\#(status == 401 ? "unauthorized" : "unavailable")"}"#.utf8), response(request, status))
            }
            let body = """
                {
                    "id": "synthetic-account", "handle": "synthetic", "displayName": null, "units": "metric",
                    "defaultVisibility": "\(visibility)", "createdAt": "2023-11-14T22:13:20.125Z"
                }
                """
            return (Data(body.utf8), response(request, 200))
        default:
            return (Data(), response(request, 404))
        }
    }

    func upload(_ request: URLRequest, file: URL, key: VoyageUploadKey) async throws -> HTTPURLResponse {
        throw URLError(.unsupportedURL)
    }
    func upload(_ request: URLRequest, file: URL, taskDescription: String) async throws -> HTTPURLResponse {
        throw URLError(.unsupportedURL)
    }
    func cancelStaleUploads(currentSignIn: () -> UUID?) async {}
    func activate(onCompletion: @escaping @MainActor (String, Int?) -> Void) {}
    func reconcileUploads(keep: (String?, URLRequest?) -> Bool) async {}

    private func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }
}
