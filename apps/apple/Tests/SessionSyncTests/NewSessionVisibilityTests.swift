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

    @Test func explanationNamesAutomaticSharingAndWhereToChangeIt() {
        // One wording for every state, Private and unknown included: the value on screen may
        // be out of date, so it never promises that uploads are private.
        let text = NewSessionVisibility.explanation
        #expect(text.contains("Visibility of new sessions"))
        #expect(text.contains("If it’s Unlisted or Public, they’re shared that way automatically"))
        #expect(text.contains("Settings on madegood.app"))
        #expect(!text.localizedCaseInsensitiveContains("are private"))
    }

    @Test func signInReturnsTheAccountDefault() async throws {
        let rig = VisibilityRig()
        rig.transport.signInVisibility = "unlisted"
        let user = try await rig.account.signIn(identityToken: "synthetic-identity", displayName: nil)
        #expect(user.defaultVisibility.rawValue == "unlisted")
        #expect(rig.transport.requests.allSatisfy { $0.url?.path != "/api/me" })
    }
}

/// `NewSessionVisibilityTracker`: the value shown beside Sync sessions, its check time, and
/// the gate that keeps sync off until a fresh value is known (review of #133, finding 1).
@MainActor
struct NewSessionVisibilityTrackerTests {
    private let a = VoyageAccountBinding(accountID: "synthetic-a", signInID: UUID())
    private let b = VoyageAccountBinding(accountID: "synthetic-b", signInID: UUID())

    @Test func aStaleValueKeepsItsCheckTimeAfterAFailedRefresh() async {
        let clock = TestClock()
        let tracker = NewSessionVisibilityTracker(now: clock.now)
        tracker.seed(.private, for: a)
        let seeded = tracker.checkedAt
        clock.advance(3_600)
        await tracker.refresh(for: a) { throw URLError(.notConnectedToInternet) }
        // The old value stays, labelled with its original check time, never as current.
        #expect(tracker.value == .private)
        #expect(tracker.checkedAt == seeded)
        #expect(tracker.lastCheckFailed)
        // And it doesn't count as fresh for turning sync on.
        let fresh = await tracker.refreshedValue(for: a) { throw URLError(.timedOut) }
        #expect(fresh == nil)
    }

    @Test func offlineThenOnline() async {
        let clock = TestClock()
        let tracker = NewSessionVisibilityTracker(now: clock.now)
        let offline = await tracker.refreshedValue(for: a) { throw URLError(.notConnectedToInternet) }
        #expect(offline == nil)
        #expect(tracker.value == nil)
        #expect(tracker.checkedAt == nil)
        #expect(tracker.lastCheckFailed)
        #expect(!tracker.isChecking)

        clock.advance(60)
        let online = await tracker.refreshedValue(for: a) { .public }
        #expect(online == .public)
        #expect(tracker.value == .public)
        #expect(tracker.checkedAt == clock.current)
        #expect(!tracker.lastCheckFailed)
    }

    @Test func theValueChangesBetweenRefreshes() async {
        let clock = TestClock()
        let tracker = NewSessionVisibilityTracker(now: clock.now)
        await tracker.refresh(for: a) { .private }
        #expect(tracker.value == .private)
        let first = tracker.checkedAt
        clock.advance(120)
        // Changed to Public on the website.
        await tracker.refresh(for: a) { .public }
        #expect(tracker.value == .public)
        #expect(tracker.checkedAt == clock.current)
        #expect(tracker.checkedAt != first)
    }

    @Test func anOlderRefreshThatFinishesLastDoesNotWin() async {
        let tracker = NewSessionVisibilityTracker()
        let older = Gate()
        let newer = Gate()
        async let first: Void = tracker.refresh(for: a) { await older.wait() }
        await older.started()
        async let second: Void = tracker.refresh(for: a) { await newer.wait() }
        await newer.started()
        // The newer request answers first with the current value...
        newer.open(.public)
        await second
        #expect(tracker.value == .public)
        #expect(!tracker.isChecking)
        // ...then the older one answers with what the setting used to be.
        older.open(.private)
        await first
        #expect(tracker.value == .public)
        #expect(!tracker.lastCheckFailed)
    }

    @Test func aNewerFailureStillSupersedesAnOlderSuccess() async {
        let tracker = NewSessionVisibilityTracker()
        let older = Gate()
        async let first: Void = tracker.refresh(for: a) { await older.wait() }
        await older.started()
        await tracker.refresh(for: a) { throw URLError(.notConnectedToInternet) }
        older.open(.public)
        await first
        #expect(tracker.value == nil)
        #expect(tracker.lastCheckFailed)
    }

    @Test func turningOnWaitsForARefreshStartedMeanwhile() async {
        let tracker = NewSessionVisibilityTracker()
        let enabling = Gate()
        let foreground = Gate()
        async let fresh = tracker.refreshedValue(for: a) { await enabling.wait() }
        await enabling.started()
        // The app returns to the foreground while the switch's check is in flight.
        async let other: Void = tracker.refresh(for: a) { await foreground.wait() }
        await foreground.started()
        enabling.open(.private)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(tracker.isChecking, "the newer check is still pending")
        foreground.open(.unlisted)
        await other
        #expect(await fresh == .unlisted)
    }

    @Test func aSignInChangeDiscardsAnInFlightResult() async {
        let tracker = NewSessionVisibilityTracker()
        let gate = Gate()
        async let first: Void = tracker.refresh(for: a) { await gate.wait() }
        await gate.started()
        tracker.reset(for: b)
        gate.open(.public)
        await first
        #expect(tracker.binding == b)
        #expect(tracker.value == nil)
        // A seed from sign-in supersedes a refresh still in flight, too.
        let late = Gate()
        async let second: Void = tracker.refresh(for: b) { await late.wait() }
        await late.started()
        tracker.seed(.unlisted, for: b)
        late.open(.private)
        await second
        #expect(tracker.value == .unlisted)
    }
}

@MainActor
private final class TestClock {
    var current = Date(timeIntervalSince1970: 1_000_000)
    var now: () -> Date { { [unowned self] in self.current } }
    func advance(_ seconds: TimeInterval) { current += seconds }
}

/// A fetch that waits until the test answers it.
@MainActor
private final class Gate {
    private var answer: CheckedContinuation<NewSessionVisibility, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    func wait() async -> NewSessionVisibility {
        await withCheckedContinuation { continuation in
            answer = continuation
            hasStarted = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    func started() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open(_ value: NewSessionVisibility) {
        answer?.resume(returning: value)
        answer = nil
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
    var signInVisibility = "private"
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
                        "units": "metric", "defaultVisibility": "\(signInVisibility)", "createdAt": "2023-11-14T22:13:20.125Z"
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
