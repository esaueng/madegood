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
        rig.networkUp = false
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
        rig.networkUp = false
        rig.transport.trackResults = [.failure(URLError(.notConnectedToInternet)), .failure(URLError(.badServerResponse))]
        let retryAt = try #require(try await outbox.drain(for: binding, policy: .init()))
        rig.networkUp = true

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

    // MARK: Review fixes

    @Test func unreachableServerOnAWorkingNetworkUsesUpAttempts() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        rig.transport.metadataErrors = Array(
            repeating: URLError(.cannotFindHost), count: SessionOutbox.maxAttempts / 2)
            + Array(repeating: URLError(.cannotConnectToHost), count: SessionOutbox.maxAttempts / 2)
        for _ in 1..<SessionOutbox.maxAttempts {
            let retryAt = try #require(try await outbox.drain(for: binding, policy: .init()))
            #expect(outbox.status(for: snapshot.sessionID) == .retrying(at: retryAt, offline: false))
            rig.now = retryAt
        }
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: snapshot.sessionID) == .failed(.retriesExhausted(status: nil)))

        // The same error with no usable network path is offline and waits.
        let (other, otherBytes) = try rig.session()
        try outbox.enqueue(other, for: binding) { otherBytes }
        rig.networkUp = false
        rig.transport.metadataErrors = [URLError(.cannotFindHost)]
        let retryAt = try #require(try await outbox.drain(for: binding, policy: .init()))
        #expect(outbox.status(for: other.sessionID) == .retrying(at: retryAt, offline: true))
    }

    @Test func aPendingSessionIsReFrozenWhenItsTrimChanges() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let id = UUID()
        let (original, originalBytes) = try rig.session(id: id, fixes: 5)
        let (trimmed, trimmedBytes) = try rig.session(id: id, fixes: 2)
        let outbox = rig.outbox()
        let first = SessionUploadRevision(trim: "original", analysis: "a")
        let second = SessionUploadRevision(trim: "1-2", analysis: "a")
        try outbox.enqueue(original, revision: first, for: binding) { originalBytes }
        #expect(!outbox.needsSnapshot(id, revision: first))
        #expect(outbox.needsSnapshot(id, revision: second))
        try outbox.enqueue(trimmed, revision: second, for: binding) { trimmedBytes }

        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(rig.transport.uploaded == [trimmedBytes], "the untrimmed track is never sent")
        #expect(rig.transport.calls.map(\.step) == ["apple", "metadata", "track"])
    }

    @Test func aTrimAfterTheMetadataWasSentResendsBoth() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let id = UUID()
        let (original, originalBytes) = try rig.session(id: id, fixes: 5)
        let (trimmed, trimmedBytes) = try rig.session(id: id, fixes: 2)
        let outbox = rig.outbox()
        try outbox.enqueue(original, revision: .init(trim: "original", analysis: "a"), for: binding) { originalBytes }
        rig.transport.trackResults = [.success(503)]
        let retryAt = try #require(try await outbox.drain(for: binding, policy: .init()))
        try outbox.enqueue(trimmed, revision: .init(trim: "1-2", analysis: "a"), for: binding) { trimmedBytes }
        #expect(outbox.status(for: id) == .pending, "a new snapshot starts without backoff")
        rig.now = retryAt
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(rig.transport.calls.map(\.step) == ["apple", "metadata", "track", "metadata", "track"])
        #expect(rig.transport.uploaded.last == trimmedBytes)
    }

    @Test func anyInputChangeAfterSyncReplacesBothUploadsAtAHigherRevision() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let id = UUID()
        let (original, originalBytes) = try rig.session(id: id, fixes: 5)
        let (trimmed, trimmedBytes) = try rig.session(id: id, fixes: 2)
        let (reanalyzed, reanalyzedBytes) = try rig.session(id: id, fixes: 3)
        let outbox = rig.outbox()
        try outbox.enqueue(original, revision: .init(trim: "original", analysis: "a"), for: binding) { originalBytes }
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: id) == .synced)

        let trim = SessionUploadRevision(trim: "1-2", analysis: "a")
        #expect(outbox.needsSnapshot(id, revision: trim))
        try outbox.enqueue(trimmed, revision: trim, for: binding) { trimmedBytes }
        #expect(outbox.status(for: id) == .pending)
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)

        // Not only trims: a new analysis (auto-pause, analyzer) is uploaded too.
        let analysis = SessionUploadRevision(trim: "1-2", analysis: "b")
        #expect(outbox.needsSnapshot(id, revision: analysis))
        try outbox.enqueue(reanalyzed, revision: analysis, for: binding) { reanalyzedBytes }
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: id) == .synced)
        #expect(rig.transport.uploaded == [originalBytes, trimmedBytes, reanalyzedBytes])

        // Every request carries its snapshot's revision, and each snapshot's is higher.
        let revisions = rig.transport.calls.filter { $0.step != "apple" }.map(\.revision)
        #expect(revisions.count == 6)
        #expect(revisions.allSatisfy { $0 != nil })
        for pair in stride(from: 0, to: 6, by: 2) { #expect(revisions[pair] == revisions[pair + 1]) }
        #expect(revisions[0]! < revisions[2]! && revisions[2]! < revisions[4]!)
    }

    @Test func aResultForAReplacedSnapshotNeverAcknowledgesTheNewOne() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let id = UUID()
        let (original, originalBytes) = try rig.session(id: id, fixes: 5)
        let (trimmed, trimmedBytes) = try rig.session(id: id, fixes: 2)
        let outbox = rig.outbox()
        try outbox.enqueue(original, revision: .init(trim: "original", analysis: "a"), for: binding) { originalBytes }
        var replacedWhileActive = false
        rig.transport.duringTrackUpload = {
            replacedWhileActive = try outbox.enqueue(
                trimmed, revision: .init(trim: "1-2", analysis: "a"), for: binding) { trimmedBytes }
        }
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(replacedWhileActive)
        // The old track's 204 was ignored; the new snapshot went out in full.
        #expect(rig.transport.calls.map(\.step) == ["apple", "metadata", "track", "metadata", "track"])
        #expect(rig.transport.uploaded == [originalBytes, trimmedBytes])
        #expect(outbox.status(for: id) == .synced)
    }

    @Test func aBackgroundCompletionWithNoWaiterIsJournalled() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        // The process ended mid-upload: the drain saw only a lost connection.
        rig.transport.trackResults = [.failure(URLError(.networkConnectionLost))]
        _ = try await outbox.drain(for: binding, policy: .init())
        let description = try #require(rig.transport.calls.last?.taskDescription)

        // On relaunch the system reports the task's success before any drain runs.
        let relaunched = rig.outbox(account: VoyageAccount(store: rig.store, api: rig.voyageAPI))
        try relaunched.restore(for: binding)
        relaunched.recordBackgroundCompletion(taskDescription: description.replacingOccurrences(
            of: binding.signInID.uuidString.lowercased(), with: UUID().uuidString.lowercased()), statusCode: 204)
        #expect(relaunched.status(for: snapshot.sessionID) != .synced, "another sign-in's task is ignored")
        relaunched.recordBackgroundCompletion(taskDescription: description, statusCode: 500)
        #expect(relaunched.status(for: snapshot.sessionID) != .synced)
        relaunched.recordBackgroundCompletion(taskDescription: description, statusCode: 204)
        #expect(relaunched.status(for: snapshot.sessionID) == .synced)
        rig.now = rig.now.addingTimeInterval(3600)
        #expect(try await relaunched.drain(for: binding, policy: .init()) == nil)
        #expect(rig.transport.calls.filter { $0.step == "track" }.count == 1, "the track is not sent again")
    }

    @Test func reconcilingKeepsOnlyTheCurrentGenerationUnderTheCurrentSettings() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let id = UUID()
        let (original, originalBytes) = try rig.session(id: id, fixes: 5)
        let (trimmed, trimmedBytes) = try rig.session(id: id, fixes: 2)
        let outbox = rig.outbox()
        try outbox.enqueue(original, revision: .init(trim: "original", analysis: "a"), for: binding) { originalBytes }
        rig.networkUp = false
        rig.transport.trackResults = [.failure(URLError(.networkConnectionLost))]
        _ = try await outbox.drain(for: binding, policy: .init())
        let old = try #require(rig.transport.calls.last?.taskDescription)
        try outbox.enqueue(trimmed, revision: .init(trim: "1-2", analysis: "a"), for: binding) { trimmedBytes }
        rig.transport.trackResults = [.failure(URLError(.networkConnectionLost))]
        rig.now = rig.now.addingTimeInterval(3600)
        _ = try await outbox.drain(for: binding, policy: .init())
        let current = try #require(rig.transport.calls.last?.taskDescription)
        #expect(old != current)

        // After a crash both tasks may still exist: only the journal's generation stays.
        let relaunched = rig.outbox(account: VoyageAccount(store: rig.store, api: rig.voyageAPI))
        try relaunched.restore(for: binding)
        func keep(_ description: String?, cellular: Bool = true, binding: VoyageAccountBinding? = nil,
                  enabled: Bool = true, wifiOnly: Bool = false) -> Bool
        {
            relaunched.shouldKeepUpload(
                taskDescription: description, allowsCellular: cellular, binding: binding ?? rig.account.binding,
                syncEnabled: enabled, policy: .init(allowsCellular: !wifiOnly))
        }
        #expect(keep(current))
        #expect(!keep(old), "a superseded generation is cancelled")
        #expect(keep(current, cellular: false, wifiOnly: true))
        #expect(!keep(current, enabled: false), "sync off")
        #expect(!keep(current, wifiOnly: true), "Wi-Fi only")
        #expect(!keep(current, cellular: false), "old Wi-Fi-only task")
        let other = VoyageAccountBinding(accountID: "synthetic-b", signInID: UUID())
        #expect(!keep(current, binding: other), "another sign-in")
        #expect(!keep(nil))
        #expect(!keep("voyage/legacy"))
        try rig.account.signOut()
        #expect(!keep(current, binding: nil), "signed out")
    }

    @Test func signOutDropsTheQueueAndFrozenTracks() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        let queue = rig.root.appending(path: "queue")
        #expect(try !FileManager.default.contentsOfDirectory(atPath: queue.path).isEmpty)
        try rig.account.signOut()
        outbox.removeOtherSignIns(keeping: nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: queue.path).isEmpty)
        #expect(outbox.status(for: snapshot.sessionID) == nil)
    }

    @Test func consentNeverBackfillsAnotherAccount() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let hour: TimeInterval = 3600
        let a = VoyageAccountBinding(accountID: "synthetic-a", signInID: UUID())
        let b = VoyageAccountBinding(accountID: "synthetic-b", signInID: UUID())
        let beforeAnyone = UUID()
        let duringA = UUID()
        let duringB = UUID()
        var consent = SessionSyncConsent()
        func check(_ id: UUID, _ from: TimeInterval, _ to: TimeInterval, _ binding: VoyageAccountBinding)
            -> SessionSyncConsent.Eligibility
        {
            consent.eligibility(
                sessionID: id, startedAt: start.addingTimeInterval(from), endedAt: start.addingTimeInterval(to),
                for: binding)
        }

        consent.signedIn(a, at: start.addingTimeInterval(1 * hour))
        #expect(!consent.isEnabled(for: a))
        consent.setEnabled(true, for: a)
        #expect(consent.isEnabled(for: a))
        #expect(check(beforeAnyone, 0, 0.5 * hour, a) == .earlier)
        #expect(check(duringA, 2 * hour, 3 * hour, a) == .automatic)

        // A signs out; B signs in on the same phone.
        consent.signedOut(at: start.addingTimeInterval(4 * hour))
        #expect(!consent.isEnabled(for: a), "sign-out turns sync off")
        consent.signedIn(b, at: start.addingTimeInterval(5 * hour))
        #expect(!consent.isEnabled(for: b), "B does not inherit A's switch")
        consent.setEnabled(true, for: b)
        #expect(check(duringA, 2 * hour, 3 * hour, b) == .otherAccount)
        #expect(check(duringB, 6 * hour, 7 * hour, b) == .automatic)
        #expect(check(beforeAnyone, 0, 0.5 * hour, b) == .earlier)

        // Choosing earlier sessions reaches only ones nobody was signed in for.
        consent.adopt([beforeAnyone, duringA], for: b)
        #expect(check(beforeAnyone, 0, 0.5 * hour, b) == .automatic)
        #expect(check(duringA, 2 * hour, 3 * hour, b) == .otherAccount)
        #expect(check(beforeAnyone, 0, 0.5 * hour, a) == .earlier)

        // Signing in again (even to A) needs the switch again.
        let again = VoyageAccountBinding(accountID: "synthetic-a", signInID: UUID())
        consent.signedIn(again, at: start.addingTimeInterval(8 * hour))
        #expect(!consent.isEnabled(for: again))
        #expect(check(duringA, 2 * hour, 3 * hour, again) == .automatic)
    }

    @Test func aRecordingNearAnAccountBoundaryNeedsAnExplicitChoice() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let a = VoyageAccountBinding(accountID: "synthetic-a", signInID: UUID())
        let b = VoyageAccountBinding(accountID: "synthetic-b", signInID: UUID())
        var consent = SessionSyncConsent()
        consent.signedIn(a, at: start)
        consent.signedOut(at: start.addingTimeInterval(3600))
        consent.signedIn(b, at: start.addingTimeInterval(3600))
        func check(_ from: TimeInterval, _ to: TimeInterval, _ binding: VoyageAccountBinding)
            -> SessionSyncConsent.Eligibility
        {
            consent.eligibility(
                sessionID: UUID(), startedAt: start.addingTimeInterval(from), endedAt: start.addingTimeInterval(to),
                for: binding)
        }
        // A watch clock a few minutes off puts these on the wrong side of the switch.
        #expect(check(3600 + 120, 3600 + 1800, b) == .earlier, "starts within the margin after the switch")
        #expect(check(3600 + 120, 3600 + 1800, a) == .otherAccount, "started under B: never A's")
        #expect(check(1800, 3600 - 60, b) == .otherAccount, "entirely in A's window")
        // Made under A, but a watch clock 2 min fast stamps its end after the switch.
        #expect(check(1800, 3600 + 60, b) == .otherAccount, "never offered to B")
        #expect(check(1800, 3600 + 60, a) == .earlier, "A may upload it, explicitly")
        #expect(check(1800, 3600 + 300, b) == .otherAccount, "spans the switch, started under A")
        #expect(check(3600 - 300, 3600 + 300, a) == .earlier)
        #expect(check(3600 + 900, 3600 + 1800, b) == .automatic, "well inside B's window")
        #expect(check(600 + 1, 1800, a) == .automatic)
        #expect(check(300, 1800, a) == .earlier, "within the margin of A's sign-in")
    }

    @Test func credentialsWithoutAPersistedWindowGetNothingAutomatically() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let a = VoyageAccountBinding(accountID: "synthetic-a", signInID: UUID())
        let unrecorded = VoyageAccountBinding(accountID: "synthetic-a", signInID: UUID())
        var consent = SessionSyncConsent()
        consent.signedIn(a, at: start)
        consent.setEnabled(true, for: unrecorded)
        #expect(!consent.isEnabled(for: unrecorded))
        #expect(
            consent.eligibility(
                sessionID: UUID(), startedAt: start.addingTimeInterval(3600), endedAt: start.addingTimeInterval(4000),
                for: unrecorded) == .earlier)
    }

    @Test func theSignInWindowIsDurableBeforeTheCredentialsAreSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "consent.json")
        let saved = MemoryCredentials()
        let store = ConsentRecordingStore(saved)
        let ledger = SessionConsentLedger(url: file)
        let transport = StubTransport()
        let account = VoyageAccount(
            store: store, api: VoyageAPI(baseURL: URL(string: "https://synthetic.invalid/api")!, transport: transport))
        ledger.guardCredentials(store, now: { Date(timeIntervalSince1970: 1_700_000_000) }, isSignedIn: {
            account.binding != nil
        })
        var windowsOnDiskAtSave: [Int] = []
        saved.onSave = { credentials in
            let onDisk = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SessionSyncConsent.self, from: $0) }
            windowsOnDiskAtSave.append(onDisk?.windows.count ?? 0)
            if credentials != nil {
                #expect(onDisk?.windows.last?.signInID == credentials?.binding.signInID)
                #expect(onDisk?.windows.last?.end == nil)
            } else {
                #expect(onDisk?.windows.last?.end == nil, "a refresh is not a sign-out")
            }
        }
        try await account.signIn(identityToken: "synthetic-identity", displayName: nil)
        let binding = try #require(account.binding)

        // A refresh clears the rotating token while still signed in: not a sign-out.
        transport.metadataStatuses = [401]
        transport.refresh = { Data(#"{"accessToken":"synthetic-access-2","refreshToken":"synthetic-refresh-2"}"#.utf8) }
        try await account.authorized(for: binding) { bearer in
            if bearer == "synthetic-access" {
                throw VoyageAPIError.http(status: 401, code: "unauthorized", retryAfter: nil)
            }
        }
        #expect(ledger.consent.windows.count == 1 && ledger.consent.windows[0].end == nil)
        saved.onSave = { credentials in
            let onDisk = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SessionSyncConsent.self, from: $0) }
            if credentials == nil { #expect(onDisk?.windows.last?.end != nil) }
        }
        try account.signOut()
        #expect(ledger.consent.windows.count == 1 && ledger.consent.windows[0].end != nil)
        #expect(windowsOnDiskAtSave.first == 1)

        // A failed consent write fails the sign-in: no credentials without a window.
        try FileManager.default.removeItem(at: root)
        try Data().write(to: root)
        await #expect(throws: (any Error).self) {
            try await account.signIn(identityToken: "synthetic-identity", displayName: nil)
        }
        #expect(account.binding == nil)
        #expect(saved.credentials == nil)
        try FileManager.default.removeItem(at: root)
    }

    @Test func aSessionDeletedFromTheAccountIsNeverSentAgain() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, revision: .init(trim: "original", analysis: "a"), for: binding) { bytes }
        rig.transport.metadataStatuses = [410]
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: snapshot.sessionID) == .failed(.deletedFromCloud))
        #expect(outbox.deletedFromCloudIDs == [snapshot.sessionID])
        try outbox.retry(for: binding)
        #expect(!outbox.needsSnapshot(snapshot.sessionID, revision: .init(trim: "1-2", analysis: "b")))
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(rig.transport.calls.filter { $0.step == "metadata" }.count == 1)

        // Across sign-ins, the consent record keeps it out of the queue.
        var consent = SessionSyncConsent()
        consent.signedIn(binding, at: rig.now.addingTimeInterval(-7200))
        consent.markDeleted(outbox.deletedFromCloudIDs, for: binding)
        #expect(
            consent.eligibility(
                sessionID: snapshot.sessionID, startedAt: snapshot.startedAt, endedAt: snapshot.startedAt, for: binding)
                == .deletedFromCloud)
    }

    @Test func aStaleTrackRevisionResendsTheMetadata() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        rig.transport.trackResults = [.success(412)]
        let retryAt = try #require(try await outbox.drain(for: binding, policy: .init()))
        rig.now = retryAt
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(rig.transport.calls.map(\.step) == ["apple", "metadata", "track", "metadata", "track"])

    }

    @Test func aRevisionBehindTheServersMovesAboveItAndResends() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let (snapshot, bytes) = try rig.session()
        let outbox = rig.outbox()
        try outbox.enqueue(snapshot, for: binding) { bytes }
        // After a reinstall the device clock gives a revision below the stored one.
        let stored: Int64 = 9_000_000_000_000
        rig.transport.storedRevision = stored
        rig.transport.metadataStatuses = [412]
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: snapshot.sessionID) == .synced)
        let sent = rig.transport.calls.filter { $0.step != "apple" }
        #expect(sent.map(\.step) == ["metadata", "metadata", "track"])
        #expect(sent[0].revision! < stored)
        #expect(sent[1].revision == stored + 1 && sent[2].revision == stored + 1)

        // The same on a track whose metadata revision the server no longer has.
        let (other, otherBytes) = try rig.session()
        try outbox.enqueue(other, for: binding) { otherBytes }
        rig.transport.storedRevision = stored + 5
        rig.transport.trackResults = [.success(412)]
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: other.sessionID) == .synced)
        #expect(rig.transport.calls.last?.revision == stored + 6)

        // Bounded: a server that keeps answering 412 ends in a failure, not a loop.
        let (third, thirdBytes) = try rig.session()
        try outbox.enqueue(third, for: binding) { thirdBytes }
        rig.transport.metadataStatuses = Array(repeating: 412, count: SessionOutbox.maxAttempts)
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: third.sessionID) == .failed(.retriesExhausted(status: 412)))
    }

    @Test func eachGenerationHasItsOwnFrozenTrackAndOrphansAreRemoved() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let id = UUID()
        let (original, originalBytes) = try rig.session(id: id, fixes: 5)
        let (trimmed, trimmedBytes) = try rig.session(id: id, fixes: 2)
        let outbox = rig.outbox()
        let folder = rig.root.appending(path: "queue").appending(path: binding.signInID.uuidString.lowercased())
        func tracks() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".track.json.gz") }
                .sorted()
        }
        try outbox.enqueue(original, revision: .init(trim: "original", analysis: "a"), for: binding) { originalBytes }
        let first = try tracks()
        #expect(first.count == 1)
        try outbox.enqueue(trimmed, revision: .init(trim: "1-2", analysis: "a"), for: binding) { trimmedBytes }
        let second = try tracks()
        #expect(second.count == 1 && second != first, "a new file per generation; the old one removed")
        #expect(try Data(contentsOf: folder.appending(path: second[0])) == trimmedBytes)

        // A crash between writing a new generation and committing the journal leaves an
        // orphan; the journal still points at its own file, and restore removes the orphan.
        let orphan = folder.appending(path: id.uuidString.lowercased() + "." + UUID().uuidString.lowercased() + ".track.json.gz")
        try originalBytes.write(to: orphan)
        let relaunched = rig.outbox(account: VoyageAccount(store: rig.store, api: rig.voyageAPI))
        try relaunched.restore(for: binding)
        #expect(try tracks() == second)
        #expect(try await relaunched.drain(for: binding, policy: .init()) == nil)
        #expect(rig.transport.uploaded == [trimmedBytes])
        #expect(try tracks().isEmpty, "a synced session's frozen track is removed")
    }

    @Test func anOldGenerationsCompletionDuringARebuildNeverMarksTheNewOneSynced() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let binding = try await rig.signIn()
        let id = UUID()
        let (original, originalBytes) = try rig.session(id: id, fixes: 5)
        let (rebuilt, rebuiltBytes) = try rig.session(id: id, fixes: 4)
        let outbox = rig.outbox()
        try outbox.enqueue(original, revision: .init(trim: "original", analysis: "a"), for: binding) { originalBytes }
        rig.networkUp = false
        rig.transport.trackResults = [.failure(URLError(.networkConnectionLost))]
        _ = try await outbox.drain(for: binding, policy: .init())
        let old = try #require(rig.transport.calls.last?.taskDescription)

        // The analysis changed (same trim) and the rebuild is queued; then the old
        // generation's background task reports success.
        let rebuiltRevision = SessionUploadRevision(trim: "original", analysis: "b")
        #expect(outbox.needsSnapshot(id, revision: rebuiltRevision))
        try outbox.enqueue(rebuilt, revision: rebuiltRevision, for: binding) { rebuiltBytes }
        outbox.recordBackgroundCompletion(taskDescription: old, statusCode: 204)
        #expect(outbox.status(for: id) == .pending, "the old generation's success is not the new one's")

        // A completion that arrives before the rebuild is queued doesn't block it either.
        let (third, thirdBytes) = try rig.session(id: id, fixes: 3)
        let thirdRevision = SessionUploadRevision(trim: "original", analysis: "c")
        rig.networkUp = true
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(outbox.status(for: id) == .synced)
        #expect(outbox.needsSnapshot(id, revision: thirdRevision), "synced, but the analysis changed")
        try outbox.enqueue(third, revision: thirdRevision, for: binding) { thirdBytes }
        #expect(try await outbox.drain(for: binding, policy: .init()) == nil)
        #expect(rig.transport.uploaded.suffix(2) == [rebuiltBytes, thirdBytes])
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
    var networkUp = true

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
        SessionOutbox(
            root: root.appending(path: "queue"), account: account ?? self.account, api: api, now: { self.now },
            networkAvailable: { _ in self.networkUp })
    }

    /// A synthetic finished kayak session at a fake origin; `fixes` stands in for a trim.
    func session(id: UUID = UUID(), fixes: Int = 2) throws -> (SessionUploadSnapshot, Data) {
        var track = Track(
            sessionId: id, sport: .kayak, startedAt: now.addingTimeInterval(-3600),
            gps: (0..<fixes).map { GPSFix(t: Double($0), latitude: 0, longitude: Double($0) * 0.00001) }
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
    var onSave: ((VoyageCredentials?) -> Void)?
    func load() throws -> VoyageCredentials? { credentials }
    func save(_ credentials: VoyageCredentials?) throws {
        onSave?(credentials)
        self.credentials = credentials
    }
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
        let revision: Int64?

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
            revision = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "revision" }?.value.flatMap { Int64($0) }
        }
    }

    var calls: [Call] = []
    var uploaded: [Data] = []
    var metadataStatuses: [Int] = []
    /// Sent as `Upload-Revision` with every 412.
    var storedRevision: Int64?
    var metadataErrors: [URLError] = []
    var retryAfter: String?
    var trackResults: [Result<Int, URLError>] = []
    var refresh: (() async throws -> Data)?
    /// Runs while a track upload is in flight, before its response.
    var duringTrackUpload: (() throws -> Void)?
    var completion: (@MainActor (String, Int?) -> Void)?
    /// Background tasks for `reconcileUploads`: description and cellular access.
    var tasks: [(description: String?, allowsCellular: Bool)] = []
    var cancelled: [String?] = []

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
        if !metadataErrors.isEmpty { throw metadataErrors.removeFirst() }
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
        try duringTrackUpload?()
        duringTrackUpload = nil
        return response(request, try trackResults.isEmpty ? 204 : trackResults.removeFirst().get())
    }

    func activate(onCompletion: @escaping @MainActor (String, Int?) -> Void) { completion = onCompletion }

    func reconcileUploads(keep: (String?, URLRequest?) -> Bool) async {
        for task in tasks {
            var request = URLRequest(url: URL(string: "https://synthetic.invalid/api/sessions")!)
            request.allowsCellularAccess = task.allowsCellular
            if !keep(task.description, request) { cancelled.append(task.description) }
        }
    }

    func upload(_ request: URLRequest, file: URL, key: VoyageUploadKey) async throws -> HTTPURLResponse {
        Issue.record("session sync never uploads voyage legs")
        throw URLError(.unsupportedURL)
    }

    func cancelStaleUploads(currentSignIn: () -> UUID?) async {}

    private func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        var headers = ["Content-Type": "application/json"]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        if status == 412, let storedRevision { headers["Upload-Revision"] = String(storedRevision) }
        return HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
}
