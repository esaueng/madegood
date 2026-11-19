import Foundation
import Testing

@testable import PrivateVoyageSync

/// Settings → Delete Account against an in-memory server: no network.
@MainActor
struct AccountDeletionTests {
    @Test func deletesOnTheServerThenSignsOutAndForgetsConsent() async throws {
        let rig = try DeletionRig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        try rig.ledger.update { $0.setEnabled(true, for: binding) }
        let other = VoyageAccountBinding(accountID: "other-account", signInID: UUID())
        try rig.ledger.update {
            $0.adopt([UUID()], for: binding)
            $0.markDeleted([UUID()], for: binding)
        }
        #expect(rig.ledger.consent.isEnabled(for: binding))

        let deleted = try await AccountDeletion.delete(account: rig.account, api: rig.api, ledger: rig.ledger)

        #expect(deleted == binding)
        let request = try #require(rig.transport.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        // The account the user confirmed, so the server can refuse any other (review of #78).
        let body = try #require(request.httpBody)
        #expect(try JSONDecoder().decode([String: String].self, from: body) == ["userId": "synthetic-account"])
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // Signed out: no binding, no saved tokens.
        #expect(rig.account.binding == nil)
        #expect(rig.store.credentials == nil)
        // Consent for the deleted account is gone; nothing else is.
        #expect(!rig.ledger.consent.hasWindow(for: binding))
        #expect(!rig.ledger.consent.isEnabled(for: binding))
        #expect(rig.ledger.consent.windows.allSatisfy { $0.accountID != binding.accountID })
        #expect(rig.ledger.consent.deletedFromCloud[binding.accountID] == nil)
        #expect(!rig.ledger.consent.hasWindow(for: other))
    }

    @Test func keepsTheSignInWhenTheServerFails() async throws {
        let rig = try DeletionRig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        try rig.ledger.update { $0.setEnabled(true, for: binding) }
        rig.transport.deleteStatuses = [503]

        await #expect(throws: VoyageAPIError.http(status: 503, code: "unavailable", retryAfter: nil)) {
            try await AccountDeletion.delete(account: rig.account, api: rig.api, ledger: rig.ledger)
        }
        #expect(rig.account.binding == binding)
        #expect(rig.store.credentials != nil)
        #expect(rig.ledger.consent.isEnabled(for: binding))
    }

    @Test func keepsTheSignInWhenOffline() async throws {
        let rig = try DeletionRig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        rig.transport.deleteError = URLError(.notConnectedToInternet)

        await #expect(throws: URLError.self) {
            try await AccountDeletion.delete(account: rig.account, api: rig.api, ledger: rig.ledger)
        }
        #expect(rig.account.binding == binding)
        #expect(rig.ledger.consent.hasWindow(for: binding))
    }

    @Test func refreshesAnExpiredAccessTokenOnce() async throws {
        let rig = try DeletionRig()
        defer { rig.cleanUp() }
        _ = try await rig.signIn()
        rig.transport.deleteStatuses = [401, 202]

        try await AccountDeletion.delete(account: rig.account, api: rig.api, ledger: rig.ledger)

        let deletes = rig.transport.requests.filter { $0.httpMethod == "DELETE" }
        #expect(deletes.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer access-1", "Bearer access-2"])
        #expect(rig.transport.requests.contains { $0.url?.path == "/api/auth/refresh" })
        #expect(rig.account.binding == nil)
        #expect(rig.store.credentials == nil)
    }

    @Test func asksToSignInAgainWhenTheRefreshFails() async throws {
        let rig = try DeletionRig()
        defer { rig.cleanUp() }
        _ = try await rig.signIn()
        rig.transport.deleteStatuses = [401]
        rig.transport.refreshStatus = 401

        await #expect(throws: VoyageAccountError.signInRequired) {
            try await AccountDeletion.delete(account: rig.account, api: rig.api, ledger: rig.ledger)
        }
        #expect(rig.transport.requests.filter { $0.httpMethod == "DELETE" }.count == 1)
    }

    @Test func treatsAMismatchAsAFailureAndKeepsTheSignIn() async throws {
        let rig = try DeletionRig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        rig.transport.deleteStatuses = [409]

        await #expect(throws: VoyageAPIError.http(status: 409, code: "unavailable", retryAfter: nil)) {
            try await AccountDeletion.delete(account: rig.account, api: rig.api, ledger: rig.ledger)
        }
        #expect(rig.account.binding == binding)
    }

    @Test func refusesWithoutASignIn() async throws {
        let rig = try DeletionRig()
        defer { rig.cleanUp() }
        await #expect(throws: VoyageAccountError.signInRequired) {
            try await AccountDeletion.delete(account: rig.account, api: rig.api, ledger: rig.ledger)
        }
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func reportsADeletedAccountWhoseSignInCouldNotBeCleared() async throws {
        let rig = try DeletionRig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        rig.store.failSaves = true

        await #expect(throws: AccountDeletedSignOutFailed.self) {
            try await AccountDeletion.delete(account: rig.account, api: rig.api, ledger: rig.ledger)
        }
        #expect(rig.transport.requests.last?.httpMethod == "DELETE")
        // The in-memory sign-in is gone and the stale keychain item is offered for clearing.
        #expect(rig.account.binding == nil)
        #expect(rig.account.storageUnavailable)
        #expect(!rig.ledger.consent.hasWindow(for: binding))
    }

    @Test func forgettingAnAccountLeavesOtherAccountsAlone() {
        let mine = VoyageAccountBinding(accountID: "mine", signInID: UUID())
        let theirs = VoyageAccountBinding(accountID: "theirs", signInID: UUID())
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var consent = SessionSyncConsent()
        consent.signedIn(theirs, at: start)
        consent.markDeleted([UUID()], for: theirs)
        consent.signedIn(mine, at: start.addingTimeInterval(3600))
        consent.setEnabled(true, for: mine)
        let theirsSession = UUID()
        consent.adopt([theirsSession], for: theirs)

        consent.forget(accountID: "mine")

        #expect(!consent.hasWindow(for: mine))
        #expect(!consent.isEnabled(for: mine))
        #expect(consent.hasWindow(for: theirs))
        #expect(consent.deletedFromCloud["theirs"]?.count == 1)
        #expect(consent.eligibility(
            sessionID: theirsSession, startedAt: start.addingTimeInterval(-7200),
            endedAt: start.addingTimeInterval(-3600), for: theirs) == .automatic)
    }
}

@MainActor
private final class DeletionRig {
    let root: URL
    let store = FailingCredentials()
    let transport = DeletionTransport()
    let api: SessionAPI
    let account: VoyageAccount
    let ledger: SessionConsentLedger

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = URL(string: "https://synthetic.invalid/api")!
        let guarded = ConsentRecordingStore(store)
        let ledger = SessionConsentLedger(url: root.appending(path: "consent.json"))
        let account = VoyageAccount(store: guarded, api: VoyageAPI(baseURL: base, transport: transport))
        ledger.guardCredentials(guarded, now: { .now }, isSignedIn: { [weak account] in account?.binding != nil })
        self.ledger = ledger
        self.account = account
        api = SessionAPI(baseURL: base, transport: transport)
    }

    func signIn() async throws -> VoyageAccountBinding {
        try await account.signIn(identityToken: "synthetic-identity", displayName: nil)
        return try #require(account.binding)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class FailingCredentials: VoyageCredentialStore {
    var credentials: VoyageCredentials?
    var failSaves = false
    func load() throws -> VoyageCredentials? { credentials }
    func save(_ credentials: VoyageCredentials?) throws {
        if failSaves { throw CocoaError(.fileWriteUnknown) }
        self.credentials = credentials
    }
}

@MainActor
private final class DeletionTransport: SessionSyncTransport {
    var requests: [URLRequest] = []
    var deleteStatuses: [Int] = []
    var deleteError: URLError?
    var refreshStatus = 200
    private var issued = 1

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        if path == "/api/auth/apple" {
            return (Data(tokens(user: true).utf8), response(request, 200))
        }
        if path == "/api/auth/refresh" {
            guard refreshStatus == 200 else {
                return (Data(#"{"error":"invalid_refresh_token"}"#.utf8), response(request, refreshStatus))
            }
            issued += 1
            return (Data(tokens(user: false).utf8), response(request, 200))
        }
        if path == "/api/me", request.httpMethod == "DELETE" {
            if let deleteError { throw deleteError }
            let status = deleteStatuses.isEmpty ? 202 : deleteStatuses.removeFirst()
            let body = (200..<300).contains(status) ? Data() : Data(#"{"error":"\#(status == 401 ? "unauthorized" : "unavailable")"}"#.utf8)
            return (body, response(request, status))
        }
        return (Data(), response(request, 404))
    }

    private func tokens(user: Bool) -> String {
        let pair = #""accessToken": "access-\#(issued)", "refreshToken": "refresh-\#(issued)""#
        guard user else { return "{\(pair)}" }
        return """
            {
                "user": {
                    "id": "synthetic-account", "handle": "synthetic", "displayName": null,
                    "units": "metric", "defaultVisibility": "private", "createdAt": "2023-11-14T22:13:20.125Z"
                },
                \(pair)
            }
            """
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
