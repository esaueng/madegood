import Foundation

@MainActor
private final class TestCredentials: VoyageCredentialStore {
    var value: VoyageCredentials?
    func load() throws -> VoyageCredentials? { value }
    func save(_ credentials: VoyageCredentials?) throws { value = credentials }
}

/// Synthetic loopback contract stub. Clock and acknowledgement loss are controlled by the test.
@MainActor
private final class WorkerStub: VoyageTransport {
    struct Stored {
        let sample: LiveVoyageSample
        let receipt: Int
    }

    var now: Int = 1_800_000_000_000
    var online = true
    var loseAcknowledgement = false
    var replaceBeforeNextUpload = false
    var accessExpired = false
    var privacyAvailable = true
    var hiddenLongitudes: Set<Double> = []
    private var voyagePath: String?
    private var metadata: Data?
    private(set) var refreshes = 0
    private var grant: (slug: String, issued: Int, expires: Int, delay: Int)?
    private var serial = 0
    private var stored: [String: Stored] = [:]
    private(set) var attempts: [[LiveVoyageSample]] = []
    private(set) var receipts: [[Int]] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard online else { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        if path == "/api/auth/refresh" {
            let input = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
            guard input?["refreshToken"] == "synthetic-refresh" else { return response(request, 401) }
            refreshes += 1
            return response(
                request, 200, Data(#"{"accessToken":"synthetic-renewed","refreshToken":"synthetic-rotated"}"#.utf8))
        }
        let token = request.value(forHTTPHeaderField: "Authorization")
        guard token == "Bearer synthetic-owner" || token == "Bearer synthetic-renewed" else {
            return response(request, 404)
        }
        if accessExpired && token == "Bearer synthetic-owner" { return response(request, 401) }
        if request.httpMethod == "PUT" {
            if path == voyagePath { return response(request, 409) }
            var metadata = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            metadata["id"] = path.split(separator: "/").last.map(String.init)
            voyagePath = path
            let contents = try JSONSerialization.data(withJSONObject: metadata)
            self.metadata = contents
            return response(request, 201, contents)
        }
        if request.httpMethod == "GET", path == voyagePath, let metadata {
            return response(request, 200, metadata)
        }
        guard let voyagePath, path.hasPrefix(voyagePath + "/") else { return response(request, 404) }
        let isActive = grant.map { now < $0.expires } ?? false
        if path == voyagePath + "/sharing" {
            var issuedSlug: String?
            if request.httpMethod == "POST" {
                let command = try JSONDecoder().decode(LiveVoyageCommand.self, from: request.httpBody!)
                switch command {
                case .case1(let issue):
                    guard !isActive else { return response(request, 409) }
                    issuedSlug = issueGrant(delay: issue.delayS, expiresIn: issue.expiresInS)
                case .case2(let rotate):
                    guard isActive else { return response(request, 409) }
                    issuedSlug = issueGrant(delay: rotate.delayS, expiresIn: rotate.expiresInS)
                case .case5:
                    grant = nil
                case .case6(let change):
                    guard isActive else { return response(request, 409) }
                    grant?.delay = change.delayS
                default:
                    return response(request, 400)
                }
            }
            let activeGrant = grant.flatMap { now < $0.expires ? $0 : nil }
            let state = LiveVoyageOwner(
                sharing: activeGrant == nil ? .off : .on, delayS: grant?.delay ?? 0,
                grantGeneration: activeGrant == nil ? nil : serial,
                preview: viewer(slug: activeGrant?.slug), slug: issuedSlug
            )
            return try response(request, 200, JSONEncoder().encode(state))
        }
        guard path == voyagePath + "/positions", request.httpMethod == "POST" else { return response(request, 404) }
        let upload = try JSONDecoder().decode(LiveVoyageBatch.self, from: request.httpBody!)
        if replaceBeforeNextUpload {
            replaceBeforeNextUpload = false
            grant = nil
            _ = issueGrant(delay: 0, expiresIn: 120)
        }
        guard let grant, now < grant.expires, upload.grantGeneration == serial else {
            return response(request, 409, Data(#"{"error":"stale_grant"}"#.utf8))
        }
        let batch = upload.positions
        require((1...250).contains(batch.count), "OpenAPI batch bounds")
        require(
            batch.allSatisfy { UUID(uuidString: $0.sampleId) != nil && UUID(uuidString: $0.segmentId) != nil },
            "OpenAPI sample and segment UUIDs")
        var accepted = stored
        attempts.append(batch)
        let result = try batch.map { sample in
            if let prior = accepted[sample.sampleId], prior.sample != sample {
                throw VoyageAPIError.http(status: 409, code: "sync_conflict", retryAfter: nil)
            }
            let row = accepted[sample.sampleId] ?? Stored(sample: sample, receipt: now)
            accepted[sample.sampleId] = row
            return Components.Schemas.VoyagePositionReceipts.receiptsPayloadPayload(
                sampleId: sample.sampleId, receivedAtMs: row.receipt)
        }
        stored = accepted
        receipts.append(result.map(\.receivedAtMs))
        if loseAcknowledgement {
            loseAcknowledgement = false
            throw URLError(.networkConnectionLost)
        }
        return try response(
            request, 200, JSONEncoder().encode(Components.Schemas.VoyagePositionReceipts(receipts: result)))
    }

    func expireGrant() { grant?.expires = now }

    func viewer(slug: String?) -> LiveVoyagePreview {
        guard let grant, slug == grant.slug, now < grant.expires, privacyAvailable else { return .unavailable }
        let cutoff = now - Int(grant.delay) * 1_000
        let eligible = stored.values.filter {
            let time = $0.sample.capturedAtMs
            return grant.issued < time && time <= $0.receipt && time <= cutoff
        }.map(\.sample).sorted { $0.capturedAtMs < $1.capturedAtMs }
        guard let newest = eligible.last, cutoff - newest.capturedAtMs < 600_000,
            !hiddenLongitudes.contains(newest.lon)
        else { return .unavailable }
        var segments: [[LiveVoyagePreview.Case2Payload.segmentsPayloadPayloadPayload]] = []
        var lastSegmentID: String?
        for sample in eligible {
            if hiddenLongitudes.contains(sample.lon) {
                lastSegmentID = nil
                continue
            }
            if lastSegmentID != sample.segmentId { segments.append([]) }
            segments[segments.count - 1].append(fix(sample))
            lastSegmentID = sample.segmentId
        }
        return .case2(
            .init(
                status: .available,
                current: .init(lat: newest.lat, lon: newest.lon, capturedAtMs: newest.capturedAtMs),
                segments: segments
            ))
    }

    func upload(_ request: URLRequest, file: URL, key: VoyageUploadKey) async throws -> HTTPURLResponse {
        fatalError("Live sharing must use the foreground transport")
    }

    func cancelStaleUploads(currentSignIn: () -> UUID?) async {}

    private func fix(_ sample: LiveVoyageSample) -> LiveVoyagePreview.Case2Payload.segmentsPayloadPayloadPayload {
        .init(lat: sample.lat, lon: sample.lon, capturedAtMs: sample.capturedAtMs)
    }

    private func issueGrant(delay: Int, expiresIn: Int) -> String {
        serial += 1
        let slug = String(repeating: "a", count: 42) + String(serial)
        grant = (slug, now, now + expiresIn * 1_000, delay)
        return slug
    }

    private func response(_ request: URLRequest, _ status: Int, _ data: Data = Data()) -> (Data, HTTPURLResponse) {
        (
            data,
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
        )
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError(description) }
}

@main
struct SharingFlow {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appending(path: "outbox.json")
        let worker = WorkerStub()
        let binding = VoyageAccountBinding(accountID: "synthetic-owner", signInID: UUID())
        let base = URL(string: "http://127.0.0.1:5173/api")!
        let credentials = TestCredentials()
        credentials.value = VoyageCredentials(
            binding: binding, tokens: VoyageTokenPair(accessToken: "synthetic-owner", refreshToken: "synthetic-refresh")
        )
        let account = VoyageAccount(store: credentials, api: VoyageAPI(baseURL: base, transport: worker))
        var foreground = true
        let api = LiveVoyageAPI(baseURL: base, account: account, transport: worker, foreground: { foreground })!
        let id = UUID()
        let leg = UUID()
        let nextLeg = UUID()
        let voyage = VoyageSnapshot(title: "Synthetic voyage", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        func open(binding expected: VoyageAccountBinding = binding) -> LiveVoyageShare {
            LiveVoyageShare(id: id, binding: expected, api: api, file: journal, now: { worker.now })
        }
        func capture(_ session: LiveVoyageShare, _ legID: UUID, lon: Double, gap: Bool = false) {
            worker.now += 1_251
            session.capture(
                legID: legID, capturedAt: Double(worker.now - 1) / 1_000, latitude: 0, longitude: lon,
                gapBefore: gap
            )
        }

        var session = open()
        capture(session, leg, lon: 0.01)
        require(session.pendingCount == 0, "Private before explicit issue")
        await session.start(voyage: voyage, delay: 60, duration: 180, replacing: false)
        let firstSlug = session.link!.lastPathComponent
        require(session.preview == .unavailable, "Empty server projection after issue")

        // Reject the same route and voyage ID when accessed under a different account.
        let otherBinding = VoyageAccountBinding(accountID: "synthetic-other", signInID: UUID())
        let otherCredentials = TestCredentials()
        otherCredentials.value = VoyageCredentials(
            binding: otherBinding, tokens: VoyageTokenPair(accessToken: "synthetic-other", refreshToken: "unused")
        )
        let other = VoyageAccount(store: otherCredentials, api: VoyageAPI(baseURL: base, transport: worker))
        let otherAPI = LiveVoyageAPI(baseURL: base, account: other, transport: worker, foreground: { true })!
        do {
            _ = try await otherAPI.owner(id: id, binding: otherBinding)
            fatalError("Another account read the owner projection")
        } catch let error as VoyageAPIError { require(error.status == 404, "Owner reads require ownership") }
        do {
            _ = try await otherAPI.change(.case5(.init(action: .revoke)), id: id, binding: otherBinding)
            fatalError("Another account revoked the share")
        } catch let error as VoyageAPIError { require(error.status == 404, "Owner commands require ownership") }
        print("PASS opt-in and owner-only reads and controls")

        let firstCaptureMs = worker.now + 1_250
        capture(session, leg, lon: 0.02)
        capture(session, leg, lon: 0.03)
        capture(session, leg, lon: 0.04, gap: true)
        capture(session, nextLeg, lon: 0.05)
        foreground = false
        await session.poll()
        require(worker.attempts.isEmpty && session.pendingCount == 4, "Background gate must leave the batch queued")
        foreground = true
        worker.loseAcknowledgement = true
        await session.poll()
        require(session.pendingCount == 4, "A lost acknowledgement leaves the committed samples queued")
        session = open()
        require(session.pendingCount == 4, "Relaunch restores the committed queue")
        worker.now += 1_000
        await session.poll()
        let first = worker.attempts[0]
        require(
            worker.attempts == [first, first],
            "Relaunch retry preserves the full sample payload (attempts: \(worker.attempts.map(\.count)); pending: \(session.pendingCount))"
        )
        require(worker.receipts[0] == worker.receipts[1], "Retry preserves the first server receipt")
        require(first[0].capturedAtMs == firstCaptureMs, "Original capture milliseconds survive retry")
        require(Set(first.map(\.sampleId)).count == 4, "Sample IDs are distinct")
        require(first[0].segmentId == first[1].segmentId, "Continuous fixes share a segment")
        require(
            Set([first[1], first[2], first[3]].map(\.segmentId)).count == 3, "Recovery and leg gaps split segments")
        require(session.pendingCount == 0, "Valid receipts clear acknowledged samples")
        require(session.preview == .unavailable, "Delay blocks positions before cutoff")
        worker.now += 60_000
        await session.poll()
        require(session.preview == worker.viewer(slug: firstSlug), "Owner sees the server projection")
        if case .case2(let projection) = session.preview {
            require(
                projection.current.lon == 0.05 && projection.segments.map(\.count) == [2, 1, 1],
                "Projected fixes and gaps match")
        } else {
            fatalError("Synthetic projection should be available")
        }
        worker.hiddenLongitudes = [0.05]
        await session.poll()
        require(session.preview == .unavailable, "Hidden current fix clears the prior preview")
        worker.hiddenLongitudes = []
        await session.updateDelay(180)
        require(session.serverDelay == 180 && session.preview == .unavailable, "Delay updates follow the server result")
        print("PASS foreground gate, durable retry identity, source time, leg and recovery gaps, delay and privacy")

        capture(session, nextLeg, lon: 0.06)
        await session.start(voyage: voyage, delay: 0, duration: 10, replacing: true)
        let rotatedSlug = session.link!.lastPathComponent
        require(
            rotatedSlug != firstSlug && worker.viewer(slug: firstSlug) == .unavailable,
            "Rotate invalidates the old link")
        require(
            session.pendingCount == 0 && session.preview == .unavailable, "Rotate resets the capture window and queue")
        capture(session, nextLeg, lon: 0.07)
        await session.poll()
        require(worker.attempts.last?.map(\.lon) == [0.07], "Old queue never follows locally rotated link")
        capture(session, nextLeg, lon: 0.08)
        worker.expireGrant()
        await session.poll()
        require(
            session.sharing == .off && session.link == nil && session.preview == .unavailable,
            "Expiry clears both views")
        require(!FileManager.default.fileExists(atPath: journal.path), "Expiry clears the durable queue")
        require(worker.attempts.last?.map(\.lon) == [0.07], "No sends after expiry")
        require(worker.viewer(slug: rotatedSlug) == .unavailable, "Server expiry is authoritative")
        await session.start(voyage: voyage, delay: 0, duration: 10, replacing: false)
        capture(session, leg, lon: 0.08)
        worker.online = false
        worker.now += 10_000
        await session.poll()
        require(session.pendingCount == 0 && session.link == nil, "The phone clears expired work even offline")
        worker.online = true
        print("PASS rotation and expiry")

        let differentMetadata = VoyageSnapshot(title: "Existing title changed locally", startedAt: voyage.startedAt)
        await session.start(voyage: differentMetadata, delay: 0, duration: 120, replacing: false)
        capture(session, leg, lon: 0.09)
        await session.poll()
        await session.poll()
        let revokeSlug = session.link!.lastPathComponent
        require(session.preview != .unavailable, "Preview visible before stop")
        capture(session, leg, lon: 0.10)
        worker.online = false
        await session.stop()
        require(
            session.mayHaveLink && session.preview == .unavailable && session.link == nil,
            "Offline stop clears locally and retains revoke control")
        require(!FileManager.default.fileExists(atPath: journal.path), "Offline stop durably discards the upload queue")
        worker.online = true
        worker.accessExpired = true
        await session.stop()
        require(
            worker.refreshes == 1 && account.binding == binding, "An expired access token can be renewed before revoke")
        require(session.sharing == .off && worker.viewer(slug: revokeSlug) == .unavailable, "Revoke clears the viewer")
        await session.poll()
        require(worker.attempts.last?.map(\.lon) == [0.09], "Revoked positions are never retried")

        await session.start(voyage: voyage, delay: 0, duration: 120, replacing: false)
        capture(session, leg, lon: 0.11)
        worker.replaceBeforeNextUpload = true
        await session.poll()
        require(session.pendingCount == 0 && session.link == nil, "A stale grant response clears queued samples")
        await session.poll()
        require(worker.attempts.last?.map(\.lon) == [0.09], "A second controller's grant never receives the old queue")
        await session.stop()
        await session.start(voyage: voyage, delay: 0, duration: 120, replacing: false)
        capture(session, leg, lon: 0.12)
        try account.signOut()
        await session.poll()
        require(session.pendingCount == 0 && session.link == nil, "Sign-out immediately fences the previous sign-in")
        let newSession = open(binding: VoyageAccountBinding(accountID: binding.accountID, signInID: UUID()))
        require(
            newSession.pendingCount == 0 && !FileManager.default.fileExists(atPath: journal.path),
            "A new sign-in cannot reuse the former sign-in's queue")
        require(worker.attempts.last?.map(\.lon) == [0.09], "Sign-out stops sends")
        print("PASS offline Stop, confirmed revoke, and sign-out fencing")
    }
}
