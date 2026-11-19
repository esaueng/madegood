import Foundation
import Testing
import WaterKit

@testable import PrivateVoyageSync

/// The session upload queue against an in-memory transport: no network.
@MainActor
struct SessionOutboxTests {
    @Test func uploadsMetadataThenTheFrozenTrackAndSurvivesARelaunch() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        #expect(outbox.status(for: snapshot.sessionID) == .pending)

        // A relaunch reads the journal from disk.
        let restored = rig.outbox(account: VoyageAccount(store: rig.store, api: rig.voyageAPI))
        try restored.restore(for: binding)
        #expect(restored.status(for: snapshot.sessionID) == .pending)
        #expect(try await restored.drain(for: binding, policy: .init()) == nil)
        #expect(restored.status(for: snapshot.sessionID) == .synced)

        let id = snapshot.sessionID.uuidString.lowercased()
        #expect(rig.transport.calls.map(\.step) == ["apple", "metadata", "track"])
        #expect(rig.transport.calls[1].path == "/api/sessions/\(id)")
        #expect(rig.transport.calls[1].method == "PUT")
        #expect(rig.transport.calls[1].bearer == "Bearer synthetic-access")
        #expect(rig.transport.calls[2].path == "/api/sessions/\(id)/track")
        #expect(rig.transport.calls[2].contentType == "application/gzip")
        #expect(rig.transport.calls[2].contentEncoding == nil)
        #expect(rig.transport.calls[2].taskDescription?.hasPrefix(binding.signInID.uuidString.lowercased() + "/") == true)
        #expect(rig.transport.uploaded == [bytes])

        let metadata = try #require(rig.transport.calls[1].json)
        #expect(metadata["sport"] as? String == "kayak")
        #expect(metadata["distanceM"] as? Double == 1234.5)
        #expect(metadata["movingS"] as? Double == 600)
        #expect(metadata["durationS"] as? Double == 900)
        #expect(metadata["maxSpeedMps"] as? Double == 3.25)
        #expect(metadata["analyzerVersion"] as? String == "1.1.0")
        #expect((metadata["summary"] as? [String: Any])?["distance"] as? Double == 1234.5)
        #expect(metadata["visibility"] == nil, "visibility stays the account default (private)")

        // Queuing the same session again does not upload it twice.
        try restored.enqueue(snapshot, for: binding) { bytes }
        #expect(try await restored.drain(for: binding, policy: .init()) == nil)
        #expect(rig.transport.calls.count == 3)
    }

    @Test func backsOffExponentiallyAndGivesUpAfterTheRetryLimit() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        rig.transport.metadataStatuses = Array(repeating: 503, count: SessionOutbox.maxAttempts)

        var delays: [TimeInterval] = []
        for _ in 1..<SessionOutbox.maxAttempts {
            let retryAt = try #require(try await outbox.drain(for: binding, policy: .init()))
            delays.append(retryAt.timeIntervalSince(rig.now))
            #expect(outbox.status(for: snapshot.sessionID) == .retrying(at: retryAt, offline: false))
            // Not due yet: nothing is sent.
            let sent = rig.transport.calls.count
            #expect(try await outbox.drain(for: binding, policy: .init()) == retryAt)
            #expect(rig.transport.calls.count == sent)
            rig.now = retryAt
        }
        #expect(delays == [10, 20, 40, 80, 160, 320, 640])

        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: snapshot.sessionID) == .failed(.retriesExhausted(status: 503)))
        #expect(rig.transport.calls.filter { $0.step == "metadata" }.count == SessionOutbox.maxAttempts)

        // Retry starts over and the session syncs.
        try outbox.retry(snapshot.sessionID, for: binding)
        #expect(outbox.status(for: snapshot.sessionID) == .pending)
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: snapshot.sessionID) == .synced)
    }

    @Test func honoursRetryAfter() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        rig.transport.metadataStatuses = [429]
        rig.transport.retryAfter = "120"
        let retryAt = try #require(try await outbox.drain(for: binding, policy: .init()))
        #expect(retryAt.timeIntervalSince(rig.now) == 120)
    }

    @Test func waitsForAConnectionWithoutUsingUpRetries() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        rig.transport.trackResults = Array(
            repeating: .failure(URLError(.notConnectedToInternet)), count: SessionOutbox.maxAttempts + 2)

        for _ in 0..<(SessionOutbox.maxAttempts + 2) {
            let retryAt = try #require(try await outbox.drain(for: binding, policy: .init()))
            #expect(retryAt.timeIntervalSince(rig.now) == SessionOutbox.offlineRetryDelay)
            #expect(outbox.status(for: snapshot.sessionID) == .retrying(at: retryAt, offline: true))
            rig.now = retryAt
        }
        // Metadata was acknowledged once; only the track is repeated.
        #expect(rig.transport.calls.filter { $0.step == "metadata" }.count == 1)
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: snapshot.sessionID) == .synced)
        #expect(Set(rig.transport.uploaded) == [bytes])
    }

    @Test func aRestoredConnectionMakesOfflineSessionsDueAtOnce() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (offline, offlineBytes) = try rig.session()
        let (failing, failingBytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(offline, for: binding) { offlineBytes }
        try outbox.enqueue(failing, for: binding) { failingBytes }
        rig.transport.trackResults = [.failure(URLError(.notConnectedToInternet)), .success(503)]
        let retryAt = try #require(try await outbox.drain(for: binding, policy: .init()))

        try outbox.connectionRestored(for: binding)
        #expect(outbox.status(for: offline.sessionID) == .pending)
        #expect(outbox.status(for: failing.sessionID) == .retrying(at: retryAt, offline: false))
        #expect(try await outbox.drain(for: binding, policy: .init()) == retryAt)
        #expect(outbox.status(for: offline.sessionID) == .synced)
    }

    @Test func sendsTheWiFiOnlyPolicyOnEveryRequest() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        #expect(try await outbox.drain(for: binding, policy: .init(allowsCellular: false)) == nil)
        let uploads = rig.transport.calls.filter { $0.step != "apple" }
        #expect(uploads.count == 2)
        #expect(uploads.allSatisfy { !$0.allowsCellular && !$0.allowsExpensive })
    }

    @Test func conflictAndTooLargeStopWithoutRetrying() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (taken, takenBytes) = try rig.session()
        let (large, largeBytes) = try rig.session()
        let (rejected, rejectedBytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(taken, for: binding) { takenBytes }
        try outbox.enqueue(large, for: binding) { largeBytes }
        try outbox.enqueue(rejected, for: binding) { rejectedBytes }
        rig.transport.metadataStatuses = [409, 201, 400]
        rig.transport.trackResults = [.success(413)]

        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: taken.sessionID) == .failed(.conflict))
        #expect(outbox.status(for: large.sessionID) == .failed(.tooLarge))
        #expect(outbox.status(for: rejected.sessionID) == .failed(.rejected(status: 400)))
        #expect(rig.transport.calls.map(\.step) == ["apple", "metadata", "metadata", "track", "metadata"])
    }

    @Test func aTrackOverTheLimitIsQueuedAsTooLargeAndNeverSent() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, _) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { Data(count: SessionOutbox.maxTrackBytes + 1) }
        #expect(outbox.status(for: snapshot.sessionID) == .failed(.tooLarge))
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(rig.transport.calls.map(\.step) == ["apple"])
    }

    @Test func rejectsATrackForAnotherSession() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, _) = try rig.session()
        let (_, otherBytes) = try rig.session()
        let outbox = rig.outbox()
        #expect(throws: SessionOutboxError.invalidTrack) {
            try outbox.enqueue(snapshot, for: binding) { otherBytes }
        }
        #expect(outbox.status(for: snapshot.sessionID) == nil)
    }

    @Test func aMissingSessionOnTrackUploadResendsTheMetadata() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        rig.transport.trackResults = [.success(404)]
        let retryAt = try #require(try await outbox.drain(for: binding, policy: .init()))
        rig.now = retryAt
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: snapshot.sessionID) == .synced)
        #expect(rig.transport.calls.map(\.step) == ["apple", "metadata", "track", "metadata", "track"])
    }

    @Test func refreshesAnExpiredTokenAndRetriesTheSameStep() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        rig.transport.metadataStatuses = [401]
        rig.transport.refresh = { Data(#"{"accessToken":"synthetic-access-2","refreshToken":"synthetic-refresh-2"}"#.utf8) }

        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: snapshot.sessionID) == .synced)
        #expect(rig.transport.calls.map(\.step) == ["apple", "metadata", "refresh", "metadata", "track"])
        #expect(rig.transport.calls.last?.bearer == "Bearer synthetic-access-2")
        #expect(rig.store.credentials?.tokens.refreshToken == "synthetic-refresh-2")
    }

    @Test func aFailedRefreshSignsOutAndLeavesTheQueueUntouched() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        rig.transport.metadataStatuses = [401]
        rig.transport.refresh = { throw VoyageAPIError.http(status: 401, code: "unauthorized", retryAfter: nil) }

        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(rig.account.binding == nil)
        #expect(rig.store.credentials == nil)
        #expect(rig.transport.calls.map(\.step) == ["apple", "metadata", "refresh"])
        #expect(outbox.status(for: snapshot.sessionID) == nil, "the queue belongs to the old sign-in")
    }

    @Test func forgettingADeletedRecordingDropsOnlyUnsyncedSessions() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (synced, syncedBytes) = try rig.session()
        let (pending, pendingBytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(synced, for: binding) { syncedBytes }
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        try outbox.enqueue(pending, for: binding) { pendingBytes }

        try outbox.forget([synced.sessionID, pending.sessionID], for: binding)
        #expect(outbox.status(for: synced.sessionID) == .synced)
        #expect(outbox.status(for: pending.sessionID) == nil)
        #expect(outbox.queuedIDs == [synced.sessionID])
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(rig.transport.calls.map(\.step) == ["apple", "metadata", "track"])
    }

    @Test func snapshotKeepsValuesWithinTheAPILimits() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var track = Track(sessionId: UUID(), sport: .windsurfing, startedAt: start)
        track.summary = .object([
            "distance": .number(5000), "movingTime": .number(4000), "elapsed": .number(3600),
            "maxSpeed2s": .number(80), "averageSpeed": .number(.nan),
        ])
        track.analyzerVersion = "not a version"
        let snapshot = SessionUploadSnapshot(track: track, endedAt: start.addingTimeInterval(3600))
        #expect(snapshot.durationS == 3600)
        #expect(snapshot.endedAt == start.addingTimeInterval(3600))
        #expect(snapshot.movingS == 3600, "moving time never exceeds elapsed time")
        #expect(snapshot.maxSpeedMps == nil, "above the API's 50 m/s limit")
        #expect(snapshot.avgSpeedMps == nil)
        #expect(snapshot.distanceM == 5000)
        #expect(snapshot.analyzerVersion == nil)
    }
}

// MARK: - Rig

@MainActor
private final class Rig {
    let root: URL
    let store = MemoryCredentials()
    let transport = StubTransport()
    let voyageAPI: VoyageAPI
    let api: SessionAPI
    let account: VoyageAccount
    var now = Date(timeIntervalSince1970: 1_700_000_000.125)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = URL(string: "https://synthetic.invalid/api")!
        voyageAPI = VoyageAPI(baseURL: base, transport: transport)
        api = SessionAPI(baseURL: base, transport: transport)
        account = VoyageAccount(store: store, api: voyageAPI)
    }

    func signIn() async throws -> VoyageAccountBinding {
        try await account.signIn(identityToken: "synthetic-identity", displayName: nil)
        return try #require(account.binding)
    }

    func outbox(account: VoyageAccount? = nil) -> SessionOutbox {
        SessionOutbox(root: root.appending(path: "queue"), account: account ?? self.account, api: api, now: { self.now })
    }

    /// A synthetic finished kayak session at a fake origin.
    func session() throws -> (SessionUploadSnapshot, Data) {
        var track = Track(
            sessionId: UUID(), sport: .kayak, startedAt: now.addingTimeInterval(-3600),
            gps: [GPSFix(t: 0, latitude: 0, longitude: 0), GPSFix(t: 1, latitude: 0, longitude: 0.00001)]
        )
        track.summary = .object([
            "distance": .number(1234.5), "movingTime": .number(600), "elapsed": .number(900),
            "maxSpeed2s": .number(3.25), "averageSpeed": .number(2.05),
        ])
        track.analyzerVersion = "1.1.0"
        let snapshot = SessionUploadSnapshot(track: track, endedAt: track.startedAt.addingTimeInterval(900))
        return (snapshot, try TrackCodec.encode(track))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class MemoryCredentials: VoyageCredentialStore {
    var credentials: VoyageCredentials?
    func load() throws -> VoyageCredentials? { credentials }
    func save(_ credentials: VoyageCredentials?) throws { self.credentials = credentials }
}

@MainActor
private final class StubTransport: SessionSyncTransport {
    struct Call {
        let step: String
        let path: String
        let method: String?
        let bearer: String?
        let contentType: String?
        let contentEncoding: String?
        let allowsCellular: Bool
        let allowsExpensive: Bool
        let json: [String: Any]?
        var taskDescription: String?

        init(_ step: String, _ request: URLRequest, taskDescription: String? = nil) {
            self.step = step
            path = request.url!.path
            method = request.httpMethod
            bearer = request.value(forHTTPHeaderField: "Authorization")
            contentType = request.value(forHTTPHeaderField: "Content-Type")
            contentEncoding = request.value(forHTTPHeaderField: "Content-Encoding")
            allowsCellular = request.allowsCellularAccess
            allowsExpensive = request.allowsExpensiveNetworkAccess
            json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            self.taskDescription = taskDescription
        }
    }

    var calls: [Call] = []
    var uploaded: [Data] = []
    var metadataStatuses: [Int] = []
    var retryAfter: String?
    var trackResults: [Result<Int, URLError>] = []
    var refresh: (() async throws -> Data)?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        if path.hasSuffix("/auth/apple") {
            calls.append(Call("apple", request))
            let body = Data(
                """
                {
                    "user": {
                        "id": "synthetic-account", "handle": "synthetic", "displayName": null,
                        "units": "metric", "defaultVisibility": "private", "createdAt": "2023-11-14T22:13:20.125Z"
                    },
                    "accessToken": "synthetic-access", "refreshToken": "synthetic-refresh"
                }
                """.utf8)
            return (body, response(request, 200))
        }
        if path.hasSuffix("/auth/refresh") {
            calls.append(Call("refresh", request))
            let performRefresh = try #require(refresh)
            return (try await performRefresh(), response(request, 200))
        }
        calls.append(Call("metadata", request))
        #expect(request.httpMethod == "PUT")
        let status = metadataStatuses.isEmpty ? 201 : metadataStatuses.removeFirst()
        guard status == 200 || status == 201 else {
            return (Data(#"{"error":"synthetic","message":"synthetic"}"#.utf8), response(request, status))
        }
        let id = request.url!.lastPathComponent
        let body = """
            {
                "id": "\(id)", "sport": "kayak", "title": null, "notes": null, "visibility": "private",
                "startedAt": "2023-11-14T21:13:20.125Z", "endedAt": null, "durationS": null, "movingS": null,
                "distanceM": null, "maxSpeedMps": null, "avgSpeedMps": null, "summary": null,
                "analyzerVersion": null, "hasTrack": false, "isOwner": true,
                "createdAt": "2023-11-14T22:13:20.125Z", "updatedAt": "2023-11-14T22:13:20.125Z"
            }
            """
        return (Data(body.utf8), response(request, status))
    }

    func upload(_ request: URLRequest, file: URL, taskDescription: String) async throws -> HTTPURLResponse {
        calls.append(Call("track", request, taskDescription: taskDescription))
        #expect(request.httpMethod == "PUT")
        uploaded.append(try Data(contentsOf: file))
        return response(request, try trackResults.isEmpty ? 204 : trackResults.removeFirst().get())
    }

    func upload(_ request: URLRequest, file: URL, key: VoyageUploadKey) async throws -> HTTPURLResponse {
        Issue.record("session sync never uploads voyage legs")
        throw URLError(.unsupportedURL)
    }

    func cancelStaleUploads(currentSignIn: () -> UUID?) async {}

    private func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        var headers = ["Content-Type": "application/json"]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        return HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
}
