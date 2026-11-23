import WaterKit
import XCTest

@testable import MadeGood

/// Delete Account turns sync off for the whole DELETE request (review of #78, finding 4): the
/// cancelled drain's own restart, Retry, a library change or a network change must not
/// upload anything to the account that is going away, and a failed deletion turns sync back on.
@MainActor
final class SessionSyncDeletionTests: XCTestCase {
    private var root: URL!
    private var transport: GatedTransport!
    private var sync: SessionSync!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionSyncDeletion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        transport = GatedTransport()
        let suite = "SessionSyncDeletionTests-" + UUID().uuidString
        sync = SessionSync(
            apiRoot: URL(string: "https://synthetic.invalid/api")!, root: root, transport: transport,
            store: MemoryCredentials(), preferences: UserDefaults(suiteName: suite)!,
            // Its sessions are queued directly, with no recordings on disk.
            isOnPhone: { _ in true })
        sync.launch()
        try await sync.account.signIn(identityToken: "synthetic-identity", displayName: nil)
        await sync.accountDidChange()
        sync.isEnabled = true
        try await waitUntil { !self.sync.preparing }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for the condition")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Queues one synthetic session directly (the test host's library is not used).
    private func queueSession() throws {
        let binding = try XCTUnwrap(sync.account.binding)
        let start = Date(timeIntervalSince1970: 946_720_800)
        let track = Track(
            sessionId: UUID(), sport: .kayak, startedAt: start,
            gps: [GPSFix(t: 0, latitude: 0, longitude: 0), GPSFix(t: 1, latitude: 0, longitude: 0.00001)])
        let bytes = try TrackCodec.encode(track)
        _ = try sync.outbox.enqueue(SessionUploadSnapshot(track: track, endedAt: start.addingTimeInterval(60)), for: binding) {
            bytes
        }
    }

    func testNothingUploadsWhileTheAccountIsBeingDeleted() async throws {
        try queueSession()
        transport.holdUploads = true
        sync.kick()
        try await waitUntil { self.transport.calls.contains("PUT") }

        transport.holdDelete = true
        transport.cancelledAllUploads = false
        let deletion = Task { try await sync.deleteAccount() }
        try await waitUntil { self.transport.calls.contains("DELETE") }
        XCTAssertTrue(sync.deletingAccount)
        let atDelete = transport.calls.count

        // Everything that would normally start a drain, while DELETE is in flight.
        transport.holdUploads = false
        sync.kick()
        sync.retry()
        sync.recordingsChanged()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(Array(transport.calls.dropFirst(atDelete)), [], "no request may follow DELETE")
        XCTAssertTrue(transport.cancelledAllUploads, "background uploads are cancelled before DELETE")

        transport.releaseDelete(status: 202)
        try await deletion.value
        XCTAssertNil(sync.account.binding)
        XCTAssertFalse(sync.deletingAccount)
        XCTAssertEqual(transport.calls.filter { $0 == "PUT" }.count, 1, "only the drain that was already running")
    }

    /// Review finding: a queued session whose recording left History is dropped by the
    /// scan, and background uploads are reconciled again, so a track upload a previous
    /// process left running for it is cancelled rather than left to finish.
    func testDroppingADeletedSessionReconcilesBackgroundUploads() async throws {
        try queueSession()
        XCTAssertFalse(sync.outbox.queuedIDs.isEmpty)
        let before = transport.reconciles

        // The test host's History has no recording of it.
        sync.recordingsChanged()
        try await waitUntil { self.sync.outbox.queuedIDs.isEmpty && !self.sync.preparing }
        XCTAssertGreaterThan(transport.reconciles, before)
        XCTAssertFalse(transport.calls.contains("PUT"))
    }

    func testAFailedDeletionTurnsSyncBackOn() async throws {
        transport.holdDelete = true
        let deletion = Task { try await sync.deleteAccount() }
        try await waitUntil { self.transport.calls.contains("DELETE") }
        transport.releaseDelete(status: 503)
        do {
            try await deletion.value
            XCTFail("the deletion should fail")
        } catch {}
        XCTAssertNotNil(sync.account.binding)
        XCTAssertFalse(sync.deletingAccount)

        try await waitUntil { !self.sync.preparing }
        try queueSession()
        sync.kick()
        try await waitUntil { self.transport.calls.filter { $0 == "PUT" }.count == 1 }
    }
}

@MainActor
private final class MemoryCredentials: VoyageCredentialStore {
    var credentials: VoyageCredentials?
    func load() throws -> VoyageCredentials? { credentials }
    func save(_ credentials: VoyageCredentials?) throws { self.credentials = credentials }
}

/// Records request kinds; can hold metadata PUTs (cancellable, like URLSession) and DELETE.
@MainActor
private final class GatedTransport: SessionSyncTransport {
    var calls: [String] = []
    var holdUploads = false
    var holdDelete = false
    var cancelledAllUploads = false
    var reconciles = 0
    private var deleteGate: CheckedContinuation<Int, Never>?

    func releaseDelete(status: Int) {
        deleteGate?.resume(returning: status)
        deleteGate = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        if path == "/api/auth/apple" {
            calls.append("apple")
            let body = """
                {"user": {"id": "synthetic-account", "handle": "synthetic", "displayName": null,
                "units": "metric", "defaultVisibility": "private", "createdAt": "2023-11-14T22:13:20.125Z"},
                "accessToken": "synthetic-access", "refreshToken": "synthetic-refresh"}
                """
            return (Data(body.utf8), response(request, 200))
        }
        if path == "/api/me", request.httpMethod == "DELETE" {
            calls.append("DELETE")
            let status = holdDelete ? await withCheckedContinuation { deleteGate = $0 } : 202
            return (Data(#"{"error":"unavailable"}"#.utf8), response(request, status))
        }
        if request.httpMethod == "PUT" {
            calls.append("PUT")
            if holdUploads {
                // Waits until cancelled, as a request in flight does when its task is cancelled.
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                throw URLError(.cancelled)
            }
            return (Data("{}".utf8), response(request, 500))
        }
        return (Data(), response(request, 404))
    }

    func upload(_ request: URLRequest, file: URL, taskDescription: String) async throws -> HTTPURLResponse {
        calls.append("track")
        return response(request, 204)
    }

    func upload(_ request: URLRequest, file: URL, key: VoyageUploadKey) async throws -> HTTPURLResponse {
        throw URLError(.unsupportedURL)
    }

    func cancelStaleUploads(currentSignIn: () -> UUID?) async {}
    func activate(onCompletion: @escaping @MainActor (String, Int?) -> Void) {}
    func reconcileUploads(keep: (String?, URLRequest?) -> Bool) async {
        reconciles += 1
        // A background upload the deletion must cancel.
        if !keep("synthetic/upload", nil) { cancelledAllUploads = true }
    }

    private func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }
}
