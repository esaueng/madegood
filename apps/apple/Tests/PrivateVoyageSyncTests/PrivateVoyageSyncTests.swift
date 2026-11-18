import Foundation
import Testing
import WaterKit

@testable import PrivateVoyageSync

@MainActor
struct PrivateVoyageSyncTests {
    @Test func shortensAnExistingLongTitleBeforeFreezingTheUpload() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        var recorder = try VoyageStore(root: rig.root.appending(path: "recordings"))
        let localTitle = String(repeating: "🧭", count: 51)
        let voyage = try recorder.createVoyage(named: localTitle)
        let now = rig.now.timeIntervalSince1970
        try recorder.startLeg(in: voyage.id, at: now)
        let leg = try recorder.endLeg(at: now + 1)
        let saved = try #require(recorder.voyages.first)
        let completed = try VoyageRecorderSync.prepare(voyage: saved, leg: leg)
        #expect(saved.name == localTitle)
        #expect(completed.voyage.title == String(repeating: "🧭", count: 49) + "…")
        #expect(completed.voyage.title.utf16.count <= 100)
    }

    @Test func restoredRecordingUploadsOriginalTimesAndGapsWithoutEditingTheLibrary() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let library = rig.root.appending(path: "recordings", directoryHint: .isDirectory)
        let start = rig.now.timeIntervalSince1970
        var recorder = try VoyageStore(root: library)
        let voyage = try recorder.createVoyage(named: "Synthetic passage")
        let active = try recorder.startLeg(in: voyage.id, at: start)
        func fix(_ time: TimeInterval) -> VoyagePosition {
            VoyagePosition(
                timestamp: start + time, latitude: 0, longitude: -30 + time / 1000,
                horizontalAccuracy: 5, speed: 3, course: 90
            )
        }
        try recorder.record(fix(1.125))
        try recorder.record(fix(9.25))

        recorder = try VoyageStore(root: library)
        #expect(recorder.activeLeg?.id == active.id)
        try recorder.resumeLeg(at: start + 20)
        #expect(try !recorder.record(fix(19)))
        try recorder.record(fix(21.5))
        recorder = try VoyageStore(root: library)
        let finished = try recorder.endLeg(at: start + 30.75)
        let savedVoyage = try #require(recorder.voyages.first)
        #expect(finished.id == active.id)
        #expect(finished.startedAt == active.startedAt)

        let binding = try await rig.signIn()
        let outbox = rig.outbox()
        #expect(outbox.status(for: finished.id) == .onIPhone)
        #expect(try await outbox.drain(for: binding) == nil)
        #expect(rig.transport.calls.map(\.step) == ["apple"])

        let completed = try VoyageRecorderSync.prepare(voyage: savedVoyage, leg: finished)
        let points = try recorder.track(for: finished)
        let trackFile = library.appending(path: finished.id.uuidString.lowercased() + ".ndjson")
        let indexFile = library.appending(path: "index.json")
        let localTrack = try Data(contentsOf: trackFile)
        let localIndex = try Data(contentsOf: indexFile)
        let originalGzip = try VoyageRecorderSync.encodeTrack(leg: finished, points: points)
        try outbox.enqueue(completed, for: binding) { originalGzip }
        rig.transport.trackResults = [.failure(URLError(.networkConnectionLost)), .success(204)]
        let retryAt = try #require(try await outbox.drain(for: binding))
        #expect(outbox.status(for: finished.id) == .waitingForConnection)

        rig.now = retryAt
        let restored = rig.outbox(account: VoyageAccount(store: rig.store, api: rig.api))
        try restored.restore(for: binding)
        #expect(try await restored.drain(for: binding) == nil)
        #expect(restored.status(for: finished.id) == .synced)
        #expect(rig.transport.calls.map(\.step) == ["apple", "voyage", "leg", "track", "track"])
        let parentPath = "/api/voyages/" + voyage.id.uuidString.lowercased()
        #expect(rig.transport.calls[1].path == parentPath)
        #expect(rig.transport.calls[2].path == parentPath + "/legs/" + active.id.uuidString.lowercased())
        #expect(rig.transport.uploaded == [originalGzip, originalGzip])
        let legBody = try #require(rig.transport.calls[2].body)
        let payload = try #require(JSONSerialization.jsonObject(with: legBody) as? [String: String])
        #expect(payload == ["startedAt": "2023-11-14T22:13:20.125Z", "endedAt": "2023-11-14T22:13:50.875Z"])

        let track = try TrackCodec.decode(try #require(rig.transport.uploaded.last))
        #expect(track.sessionId == active.id)
        #expect(track.startedAt == Date(timeIntervalSince1970: start))
        #expect(track.gps.map(\.t) == [1.125, 9.25, 21.5])
        #expect(track.events == [
            SessionEvent(t: 9.25, type: "recording_gap", data: ["endT": .number(21.5)]),
            SessionEvent(t: 21.5, type: "recording_gap", data: ["endT": .number(30.75)]),
            SessionEvent(t: 30.75, type: .stop),
        ])
        #expect(try Data(contentsOf: trackFile) == localTrack)
        #expect(try Data(contentsOf: indexFile) == localIndex)
        let reopened = try VoyageStore(root: library)
        #expect(reopened.activeLeg == nil)
        #expect(try reopened.track(for: finished) == points)
    }

    @Test func retriesTheFrozenTrackAfterRestartAndKeepsAcknowledgements() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (leg, source, originalBytes) = try rig.leg()
        try rig.outbox().enqueue(leg, for: binding) { try Data(contentsOf: source) }
        // The source file may be reanalyzed or removed after enqueue.
        try Data("new analysis".utf8).write(to: source)
        let first = rig.outbox()
        rig.transport.trackResults = [.failure(URLError(.notConnectedToInternet)), .success(204)]
        let retryAt = try await first.drain(for: binding)
        #expect(retryAt == rig.now.addingTimeInterval(5))
        #expect(first.status(for: leg.legID) == .waitingForConnection)
        #expect(rig.transport.calls.map(\.step) == ["apple", "voyage", "leg", "track"])
        let voyageBody = try #require(rig.transport.calls[1].body)
        let voyage = try #require(JSONSerialization.jsonObject(with: voyageBody) as? [String: String])
        #expect(voyage == ["title": "Synthetic passage", "startedAt": "2023-11-14T22:13:20.125Z"])
        #expect(rig.transport.calls[1].method == "PUT")
        #expect(rig.transport.calls[1].path == "/api/voyages/" + leg.voyageID.uuidString.lowercased())
        let legBody = try #require(rig.transport.calls[2].body)
        let legPayload = try #require(JSONSerialization.jsonObject(with: legBody) as? [String: Any])
        #expect(legPayload["distanceM"] as? Double == 42)
        #expect(legPayload["endedAt"] as? String == "2023-11-14T22:13:40.125Z")
        #expect(rig.transport.calls[3].contentType == "application/gzip")
        #expect(rig.transport.calls[3].contentEncoding == nil)
        #expect(rig.transport.calls[3].bearer == "Bearer synthetic-access")

        let restoredAccount = VoyageAccount(store: rig.store, api: rig.api)
        let restored = rig.outbox(account: restoredAccount)
        try restored.restore(for: binding)
        #expect(restored.status(for: leg.legID) == .waitingForConnection)
        #expect(try await restored.drain(for: binding) == retryAt)
        rig.now = rig.now.addingTimeInterval(5)
        #expect(try await restored.drain(for: binding) == nil)
        #expect(restored.status(for: leg.legID) == .synced)
        #expect(rig.transport.calls.map(\.step) == ["apple", "voyage", "leg", "track", "track"])
        #expect(rig.transport.uploaded == [originalBytes, originalBytes])
        #expect(try Data(contentsOf: source) == Data("new analysis".utf8))
    }

    @Test(arguments: [VoyageSyncStep.voyage, .leg, .track])
    func conflictStopsTheLegAtTheRejectedStep(_ step: VoyageSyncStep) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (leg, source, bytes) = try rig.leg()
        if step == .track {
            rig.transport.trackResults = [.success(409)]
        } else {
            rig.transport.metadataStatuses[step.rawValue] = [409]
        }
        let outbox = rig.outbox()
        try outbox.enqueue(leg, for: binding) { try Data(contentsOf: source) }
        #expect(try await outbox.drain(for: binding) == nil)
        #expect(outbox.status(for: leg.legID) == .needsAttention(step, status: 409))
        #expect(rig.transport.calls.last?.step == step.rawValue)
        let count = rig.transport.calls.count
        try outbox.retryFailures(for: binding)
        #expect(try await rig.outbox().drain(for: binding) == nil)
        #expect(rig.transport.calls.count == count)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func serverBackoffIsPersistedAndOnlyRepeatsTheFailedStep() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (leg, source, _) = try rig.leg()
        rig.transport.metadataStatuses = ["voyage": [200], "leg": [503, 503, 200]]
        let first = rig.outbox()
        try first.enqueue(leg, for: binding) { try Data(contentsOf: source) }
        let retry = try await first.drain(for: binding)
        #expect(retry == rig.now.addingTimeInterval(5))
        #expect(first.status(for: leg.legID) == .retryableFailure(.leg))
        rig.now = rig.now.addingTimeInterval(5)
        let second = rig.outbox()
        #expect(try await second.drain(for: binding) == rig.now.addingTimeInterval(10))
        rig.now = rig.now.addingTimeInterval(10)
        #expect(try await second.drain(for: binding) == nil)
        #expect(second.status(for: leg.legID) == .synced)
        #expect(rig.transport.calls.map(\.step) == ["apple", "voyage", "leg", "leg", "leg", "track"])
    }

    @Test func concurrent401sRefreshOnceAndSaveBeforeReleasingWaiters() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let refreshStarted = Gate()
        let allowResult = Gate()
        let rejectedTwice = Gate()
        let probing = AuthProbe()
        rig.transport.refresh = {
            #expect(rig.store.credentials == nil)
            refreshStarted.open()
            await allowResult.wait()
            return try JSONEncoder().encode(VoyageTokenPair(accessToken: "replacement", refreshToken: "successor"))
        }

        func rejectOld(_ token: String) async throws {
            if token == "synthetic-access" {
                probing.rejections += 1
                if probing.rejections == 2 { rejectedTwice.open() }
                await rejectedTwice.wait()
                throw VoyageAPIError.http(status: 401, code: "unauthorized", retryAfter: nil)
            }
            #expect(rig.store.credentials?.tokens.accessToken == token)
            #expect(rig.store.credentials?.tokens.refreshToken == "successor")
            probing.retries += 1
        }

        async let first: Void = rig.account.authorized(for: binding, operation: rejectOld)
        async let second: Void = rig.account.authorized(for: binding, operation: rejectOld)
        await refreshStarted.wait()
        allowResult.open()
        try await first
        try await second
        #expect(probing.retries == 2)
        #expect(rig.transport.calls.map(\.step) == ["apple", "refresh"])
        let body = try #require(rig.transport.calls.last?.body)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["refreshToken": "synthetic-refresh"])
    }

    @Test func losingARefreshResponseRequiresSignInWithoutReusingTheToken() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        rig.transport.refresh = { throw URLError(.networkConnectionLost) }
        await #expect(throws: VoyageAccountError.signInRequired) {
            try await rig.account.authorized(for: binding) { _ in
                throw VoyageAPIError.http(status: 401, code: nil, retryAfter: nil)
            }
        }
        #expect(rig.account.binding == nil)
        #expect(VoyageAccount(store: rig.store, api: rig.api).binding == nil)
        #expect(rig.transport.calls.map(\.step) == ["apple", "refresh"])
    }

    @Test func signOutDuringRefreshCannotOverwriteAnotherAccountOrResumeOldEntries() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let original = try await rig.signIn()
        let (leg, source, bytes) = try rig.leg()
        let outbox = rig.outbox()
        try outbox.enqueue(leg, for: original) { try Data(contentsOf: source) }
        let inRefresh = Gate()
        let giveResult = Gate()
        rig.transport.metadataStatuses["voyage"] = [401]
        rig.transport.refresh = {
            inRefresh.open()
            await giveResult.wait()
            return try JSONEncoder().encode(
                VoyageTokenPair(accessToken: "old-replacement", refreshToken: "old-successor"))
        }

        async let running = outbox.drain(for: original)
        await inRefresh.wait()
        try rig.account.signOut()
        rig.transport.accountID = "synthetic-second-account"
        let second = try await rig.signIn()
        giveResult.open()
        _ = try await running

        #expect(rig.store.credentials?.binding == second)
        #expect(rig.store.credentials?.tokens.accessToken == "synthetic-access")
        #expect(outbox.status(for: leg.legID) == .onIPhone)
        #expect(throws: VoyageAccountError.accountChanged) {
            try outbox.enqueue(leg, for: original) { try Data(contentsOf: source) }
        }
        #expect(try await outbox.drain(for: second) == nil)
        try rig.account.signOut()
        rig.transport.accountID = original.accountID
        let sameUser = try await rig.signIn()
        #expect(sameUser.signInID != original.signInID)
        #expect(try await rig.outbox().drain(for: sameUser) == nil)
        #expect(rig.transport.calls.map(\.step) == ["apple", "voyage", "refresh", "apple", "apple"])
        #expect(try Data(contentsOf: source) == bytes)
    }
}

@MainActor
private final class Rig {
    let root: URL
    let store = MemoryCredentials()
    let transport = StubTransport()
    let api: VoyageAPI
    let account: VoyageAccount
    var now = Date(timeIntervalSince1970: 1_700_000_000.125)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        api = VoyageAPI(baseURL: URL(string: "https://synthetic.invalid/api")!, transport: transport)
        account = VoyageAccount(store: store, api: api)
    }

    func signIn() async throws -> VoyageAccountBinding {
        try await account.signIn(identityToken: "synthetic-identity", displayName: nil)
        return try #require(account.binding)
    }

    func outbox(account: VoyageAccount? = nil) -> VoyageOutbox {
        VoyageOutbox(root: root.appending(path: "queue"), account: account ?? self.account, api: api, now: { self.now })
    }

    func leg() throws -> (CompletedVoyageLeg, URL, Data) {
        let legID = UUID()
        let bytes = try TrackCodec.encode(
            Track(
                sessionId: legID, sport: .sailing, startedAt: now,
                gps: [GPSFix(t: 0.125, latitude: 0, longitude: 0)]
            ))
        let url = root.appending(path: legID.uuidString + ".gz")
        try bytes.write(to: url)
        return (
            CompletedVoyageLeg(
                voyageID: UUID(), voyage: VoyageSnapshot(title: "Synthetic passage", startedAt: now),
                legID: legID, leg: VoyageLegSnapshot(startedAt: now, endedAt: now.addingTimeInterval(20), distanceM: 42)
            ), url, bytes
        )
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
private final class StubTransport: VoyageTransport {
    struct Call {
        let step: String
        let path: String
        let method: String?
        let bearer: String?
        let contentType: String?
        let contentEncoding: String?
        let body: Data?

        init(_ step: String, _ request: URLRequest) {
            self.step = step
            path = request.url!.path
            method = request.httpMethod
            bearer = request.value(forHTTPHeaderField: "Authorization")
            contentType = request.value(forHTTPHeaderField: "Content-Type")
            contentEncoding = request.value(forHTTPHeaderField: "Content-Encoding")
            body = request.httpBody
        }
    }

    var calls: [Call] = []
    var uploaded: [Data] = []
    var accountID = "synthetic-first-account"
    var metadataStatuses: [String: [Int]] = [:]
    var trackResults: [Result<Int, URLError>] = []
    var refresh: (() async throws -> Data)?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        if path.hasSuffix("/auth/apple") {
            calls.append(Call("apple", request))
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let payload = try #require(request.httpBody)
            #expect(try JSONSerialization.jsonObject(with: payload) as? [String: String] == [
                "identityToken": "synthetic-identity"
            ])
            let body = Data(
                """
                {
                    "user": {
                        "id": "\(accountID)", "handle": "synthetic", "displayName": null,
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
            let body = try await performRefresh()
            return (body, response(request, 200))
        }
        let step = path.contains("/legs/") ? "leg" : "voyage"
        calls.append(Call(step, request))
        let status = metadataStatuses[step]?.isEmpty == false ? metadataStatuses[step]!.removeFirst() : 201
        guard status == 200 || status == 201 else { return (Data(), response(request, status)) }
        let body = try #require(request.httpBody)
        var snapshot = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let segments = request.url!.pathComponents
        snapshot["id"] = segments.last
        if step == "leg" {
            snapshot["voyageId"] = segments[3]
        }
        return (try JSONSerialization.data(withJSONObject: snapshot), response(request, status))
    }

    func upload(_ request: URLRequest, file: URL, key: VoyageUploadKey) async throws -> HTTPURLResponse {
        calls.append(Call("track", request))
        #expect(request.url?.path.hasSuffix(key.legID.uuidString.lowercased() + "/track") == true)
        uploaded.append(try Data(contentsOf: file))
        return response(request, try trackResults.isEmpty ? 204 : trackResults.removeFirst().get())
    }

    func cancelStaleUploads(currentSignIn: () -> UUID?) async {}

    private func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }
}

@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@MainActor
private final class AuthProbe {
    var rejections = 0
    var retries = 0
}
