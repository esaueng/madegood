import Foundation
import Observation

/// One voyage's phone-side consent and outbox. The Worker owns viewer eligibility.
@MainActor @Observable
final class LiveVoyageShare {
    private struct Grant: Codable {
        let binding: VoyageAccountBinding
        let slug: String
        let generation: Int
        let captureAfterMs: Int
        let stopAtMs: Int
        var legID: UUID?
        var segmentID: String?
        var lastCapturedAtMs: Int?
        var samples: [LiveVoyageSample] = []
    }

    private static let batchSize = 250
    private static let queueLimit = 10_000

    let id: UUID
    let binding: VoyageAccountBinding
    private let api: LiveVoyageAPI
    private let file: URL
    private let now: () -> Int

    private var grant: Grant?
    private var owner: LiveVoyageOwner?
    private(set) var changing = false
    private(set) var mayHaveLink = false
    private(set) var message: String?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var retryAtMs: Int = 0
    @ObservationIgnored private var storageFailed = false

    var isBound: Bool { api.account.binding == binding }
    var sharing: LiveVoyageOwner.sharingPayload? { isBound ? owner?.sharing : nil }
    var serverDelay: Int? { isBound ? owner?.delayS : nil }
    var preview: LiveVoyagePreview { sharing == .on ? owner?.preview ?? .unavailable : .unavailable }
    var link: URL? {
        guard sharing == .on, let grant, owner?.grantGeneration == grant.generation, now() < grant.stopAtMs else {
            return nil
        }
        return api.link(slug: grant.slug)
    }
    var uploadCutoff: Date? {
        guard isBound, let grant else { return nil }
        return Date(timeIntervalSince1970: Double(grant.stopAtMs) / 1_000)
    }
    var pendingCount: Int { isBound ? grant?.samples.count ?? 0 : 0 }

    init(id: UUID, binding: VoyageAccountBinding, api: LiveVoyageAPI, file: URL, now: @escaping () -> Int) {
        self.id = id
        self.binding = binding
        self.api = api
        self.file = file
        self.now = now
        do {
            var saved = try JSONDecoder().decode(Grant.self, from: Data(contentsOf: file))
            if saved.binding == binding && now() < saved.stopAtMs {
                // The recorder may have resumed before this voyage screen reopened.
                // Preserve queued identities and start a separate segment for the next fix.
                saved.segmentID = nil
                grant = saved
                mayHaveLink = true
            } else {
                discard()
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Private by default.
        } catch is DecodingError {
            // Older or malformed journals cannot establish the grant that authorized capture.
            discard()
        } catch {
            storageFailure()
        }
    }

    func capture(legID: UUID, capturedAt: TimeInterval, latitude: Double, longitude: Double, gapBefore: Bool) {
        guard !storageFailed, isBound, var grant, now() < grant.stopAtMs,
            (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return }
        let milliseconds = (capturedAt * 1_000).rounded(.down)
        guard (0...8_640_000_000_000_000).contains(milliseconds) else { return }
        let capturedAtMs = Int(milliseconds)
        guard capturedAtMs > grant.captureAfterMs, capturedAtMs < grant.stopAtMs, capturedAtMs <= now(),
            capturedAtMs > (grant.lastCapturedAtMs ?? -1)
        else { return }

        if grant.samples.count == Self.queueLimit {
            // If space opens later, preserve the break caused by dropped live fixes.
            if grant.segmentID != nil {
                grant.segmentID = nil
                save(grant)
            }
            return
        }
        let segmentID: String
        if !gapBefore, grant.legID == legID, let previous = grant.segmentID {
            segmentID = previous
        } else {
            segmentID = UUID().uuidString.lowercased()
        }
        grant.legID = legID
        grant.segmentID = segmentID
        grant.lastCapturedAtMs = capturedAtMs
        grant.samples.append(
            LiveVoyageSample(
                lat: latitude, lon: longitude, capturedAtMs: capturedAtMs,
                sampleId: UUID().uuidString.lowercased(), segmentId: segmentID
            ))
        save(grant)
    }

    func poll() async {
        guard isBound, !changing, polling == nil else { return }
        let job = Task { await refreshAndUpload() }
        polling = job
        await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
        polling = nil
    }

    func clearPreview() { owner = nil }

    func invalidate() {
        polling?.cancel()
        owner = nil
        discard()
        mayHaveLink = false
    }

    func start(voyage: VoyageSnapshot, delay: Int, duration: Int, replacing: Bool) async {
        guard (0...86_400).contains(delay), (1...604_800).contains(duration),
            beginChange(discarding: true)
        else { return }
        defer { changing = false }
        await polling?.value
        guard isBound, !storageFailed else { return }
        do {
            if !replacing { try await api.ensureVoyage(voyage, id: id, binding: binding) }
            let started = now()
            mayHaveLink = true
            let owner = try await api.change(
                replacing
                    ? .case2(.init(action: .rotate, delayS: delay, expiresInS: duration))
                    : .case1(.init(action: .issue, delayS: delay, expiresInS: duration)),
                id: id, binding: binding
            )
            guard owner.sharing == .on, let slug = owner.slug, api.link(slug: slug) != nil,
                let generation = owner.grantGeneration, generation > 0
            else {
                throw VoyageAPIError.invalidResponse
            }
            let deadline = started + duration * 1_000
            guard now() < deadline else { return }
            // Begin after the acknowledgement and stop by the earliest possible expiry.
            save(Grant(binding: binding, slug: slug, generation: generation, captureAfterMs: now(), stopAtMs: deadline))
            apply(owner)
        } catch {
            message = "Couldn’t confirm the new link. Check the sharing status before trying again."
        }
    }

    func updateDelay(_ seconds: Int) async {
        guard (0...86_400).contains(seconds), beginChange(discarding: false) else { return }
        defer { changing = false }
        await polling?.value
        do {
            apply(
                try await api.change(
                    .case6(.init(action: .delay, delayS: seconds)), id: id, binding: binding))
        } catch {
            message = "Couldn’t confirm the delay. Refresh sharing status to check the current setting."
        }
    }

    func stop() async {
        guard beginChange(discarding: true) else { return }
        defer { changing = false }
        await polling?.value
        do {
            let result = try await api.change(.case5(.init(action: .revoke)), id: id, binding: binding)
            guard result.sharing == .off else { throw VoyageAPIError.invalidResponse }
            apply(result)
        } catch {
            message = "Uploads stopped on this iPhone. The link may still work. Try Stop Sharing again when connected."
        }
    }

    private func beginChange(discarding: Bool) -> Bool {
        guard isBound, !changing else { return false }
        changing = true
        owner = nil
        message = nil
        retryAtMs = 0
        polling?.cancel()
        if discarding { discard() }
        return true
    }

    private func refreshAndUpload() async {
        if let grant, now() >= grant.stopAtMs {
            clearPreview()
            discard()
        }
        guard !Task.isCancelled else { return }
        do {
            let response = try await api.owner(id: id, binding: binding)
            guard !Task.isCancelled, !changing else { return }
            apply(response)
            guard response.sharing == .on, !storageFailed, let grant,
                now() < grant.stopAtMs, now() >= retryAtMs, !grant.samples.isEmpty
            else { return }
            let batch = Array(grant.samples.prefix(Self.batchSize))
            try await api.upload(batch, generation: grant.generation, id: id, binding: binding) {
                !self.changing && self.grant?.generation == grant.generation && self.now() < grant.stopAtMs
            }
            guard !Task.isCancelled, !changing, var latest = self.grant, latest.generation == grant.generation else {
                return
            }
            latest.samples.removeFirst(batch.count)
            save(latest)
        } catch {
            guard !Task.isCancelled, !changing else { return }
            owner = nil
            if error is CancellationError { return }
            if let error = error as? VoyageAPIError {
                if case .http(409, "stale_grant", _) = error {
                    discard()
                    message = "The link changed or expired. Queued positions were cleared."
                    return
                }
                switch error.status {
                case 404:
                    discard()
                    mayHaveLink = false
                    owner = LiveVoyageOwner(sharing: .off, delayS: 0, preview: .unavailable)
                case 400, 409, 413:
                    // Stay fail-closed on a rejected batch or prototype capacity.
                    discard()
                    message = "The server rejected the live positions. Stop or replace this link."
                default:
                    retryAtMs = now() + 30_000
                    if case .http(_, _, let retryAfter?) = error, retryAfter.isFinite, retryAfter > 30 {
                        retryAtMs = now() + Int(min(86_400, retryAfter) * 1_000)
                    }
                }
            } else {
                retryAtMs = now() + 30_000
            }
        }
    }

    private func apply(_ response: LiveVoyageOwner) {
        owner = response
        mayHaveLink = response.sharing != .off
        if let grant, response.sharing != .on || response.grantGeneration != grant.generation {
            discard()
        }
    }

    private func save(_ next: Grant) {
        do {
            let root = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var directory = root
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try directory.setResourceValues(resourceValues)
            #if os(iOS)
                let options: Data.WritingOptions = [.atomic, .completeFileProtection]
            #else
                let options: Data.WritingOptions = [.atomic]
            #endif
            try JSONEncoder().encode(next).write(to: file, options: options)
            grant = next
        } catch {
            grant = nil
            discard()
            storageFailure()
        }
    }

    private func discard() {
        grant = nil
        do {
            try FileManager.default.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already clear.
        } catch {
            storageFailure()
        }
    }

    private func storageFailure() {
        grant = nil
        storageFailed = true
        message = "Live uploads are off on this iPhone because its sharing data couldn’t be saved or cleared."
    }
}
