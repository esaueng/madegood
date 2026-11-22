import Foundation
import Synchronization
import WatchConnectivity
import WaterKit

#if os(watchOS)
    import WatchKit
#endif

/// Moves finished recordings from the watch to the phone.
///
/// - The watch sends each file with `WCSession.transferFile` (each stream is already
///   gzipped): small files first, `meta.json` last, and files over 1 MB in parts
///   (`TransferParts`), which the phone joins. WatchConnectivity sends one file at a time and
///   slowly (a 35 MB motion stream takes many minutes), so parts keep an interruption from
///   starting a large file over.
/// - The phone stores each file durably (atomic replace for duplicates) and only then
///   acknowledges it with `transferUserInfo`, which is queued, delivered in order and
///   delivered even if the watch app isn't running. Each acknowledgement lists every
///   recording file the phone holds for that session right then, with its size.
/// - The watch deletes a recording only when one acknowledgement shows the phone holding
///   **every** file of it at the same size (`isDelivered`). Acknowledgements are not added
///   up over time: if the phone loses a file it acknowledged earlier (the user deletes a
///   half-received recording, or a replace fails), the next list shows it, and the watch
///   keeps the recording and sends it again on the next launch. An acknowledgement without
///   a list (a phone build from before it) never deletes anything.
/// - The recording in progress is never sent or deleted (`markActive`).
/// - WatchConnectivity can leave a transfer outstanding forever without calling back. Each
///   transfer carries the time it was queued. A recording whose transfers are moving is
///   never cancelled; one whose transfers have not moved (`shouldRequeue`) is cancelled and
///   queued again, at launch once queued for `stuckAfter`, on "Send again" right away.
///   Cancelling never touches the recording's files, and the phone keeps duplicates.
/// - Each acknowledgement also lists the parts the phone holds of files still arriving. The
///   watch keeps the latest list (`PhoneHolds`) across launches and sends only what the
///   phone lacks; it never deletes on that list, only on a live acknowledgement.
/// - Progress in the background (docs/watch-transfer.md): every acknowledgement that does
///   not complete a recording sends the watch round again, which tops up its window of
///   parts; acknowledgements wake a suspended watch app (`finishBackgroundDelivery`). While
///   recordings wait the watch keeps a background app refresh scheduled
///   (`TransferPolicy.nextRefresh`, `resumeFromRefresh`), and a failed transfer goes again
///   after a backoff (`TransferPolicy.retryDelay`). Sends run one at a time on a serial
///   queue, so a part is never queued twice by callers racing.
/// - The phone may be launched in the background to receive: the app activates the session
///   at launch, before any UI, and storing and joining run under an expiring background
///   activity. Joins cut short are finished, and acknowledged, at the next activation.
///
/// - Raw format versions (docs/formats.md): the phone advertises the versions it reads
///   (`rawVersions` in its application context; a phone build without it reads only 1).
///   The watch sends a recording only to a phone that reads its version and otherwise
///   keeps it, and the phone never acknowledges a `meta.json` whose version it cannot read.
///
/// The watch never talks to the API (docs/PLAN.md §4.1); the phone is the hub.
final class RecordingTransfer: NSObject, WCSessionDelegate, Sendable {
    static let shared = RecordingTransfer()

    /// Posted on the main queue when the phone has stored a file.
    static let didReceiveFile = Notification.Name("RecordingTransfer.didReceiveFile")
    /// Posted on the main queue when the watch has removed a fully delivered recording.
    static let didDeliverRecording = Notification.Name("RecordingTransfer.didDeliverRecording")

    private enum Key {
        static let sessionId = "sessionId"
        static let file = "file"
        static let stored = "stored"
        static let settings = "settings"
        static let rawVersions = "rawVersions"
        static let queuedAt = "queuedAt"
        static let files = "files"
        static let parts = "parts"
    }

    /// Which outstanding transfers a send cancels and queues again.
    enum Requeue {
        /// None: only files not in flight are queued.
        case none
        /// Those outstanding for `stuckAfter` (each launch).
        case stuck
        /// All of them ("Send again").
        case all
    }

    /// The recording files in `folder` and their sizes; nil if the folder cannot be read.
    /// The phone sends this with each acknowledgement, and the watch compares it with its own.
    static func recordingFiles(in folder: URL) -> [String: Int64]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        var files: [String: Int64] = [:]
        for name in names where RecordingStore.isRecordingFileName(name) {
            let url = folder.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let size = (attributes[.size] as? NSNumber)?.int64Value
            else { return nil }
            files[name] = size
        }
        return files
    }

    /// The phone's list of stored files from an acknowledgement; nil if it has none (a phone
    /// build from before the list) or it is malformed.
    static func phoneFiles(fromAcknowledgement userInfo: [String: Any]) -> [String: Int64]? {
        guard let raw = userInfo[Key.files] as? [String: Any] else { return nil }
        var files: [String: Int64] = [:]
        for (name, value) in raw {
            guard let size = (value as? NSNumber)?.int64Value else { return nil }
            files[name] = size
        }
        return files
    }

    /// Whether the phone holds every file of a recording the watch holds as `local`, at the
    /// same size. An empty recording is never delivered.
    static func isDelivered(local: [String: Int64], phone: [String: Int64]) -> Bool {
        !local.isEmpty && local.allSatisfy { phone[$0.key] == $0.value }
    }

    /// Why `phone` does not cover `local` yet, one line per file, for the diagnostics; empty
    /// exactly when `isDelivered`.
    static func deliveryGaps(local: [String: Int64], phone: [String: Int64]) -> [String] {
        if local.isEmpty { return ["no recording files on the watch"] }
        return local.sorted { $0.key < $1.key }.compactMap { name, size in
            guard let held = phone[name] else { return "\(name) missing on iPhone" }
            return held == size ? nil : "\(name) is \(held) bytes on iPhone, \(size) on the watch"
        }
    }

    /// A file transfer still queued or in progress, for the diagnostics.
    struct Outstanding: Hashable, Sendable {
        var file: String
        var part: Int?
        var parts: Int?
        var queuedAt: Date?
        var fractionCompleted: Double
        var isTransferring: Bool

        var name: String {
            guard let part, let parts else { return file }
            return "\(file) part \(part + 1)/\(parts)"
        }
    }

    /// What the phone said it holds of a recording in its latest acknowledgement: whole files
    /// with their sizes, and the parts of files still arriving. The watch keeps it across
    /// launches to send only what the phone lacks; it never deletes on it.
    struct PhoneHolds: Codable, Equatable, Sendable {
        var files: [String: Int64] = [:]
        var parts: [String: [Int]] = [:]
    }

    /// The phone's parts of files still arriving, from an acknowledgement; empty when it has
    /// none (or is from a build before parts).
    static func phoneParts(fromAcknowledgement userInfo: [String: Any]) -> [String: [Int]] {
        guard let raw = userInfo[Key.parts] as? [String: Any] else { return [:] }
        return raw.compactMapValues { value in
            (value as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
        }
    }

    /// One transfer: a whole file, or one part of one.
    struct Unit: Hashable, Sendable {
        var file: String
        var part: TransferParts.Part?
        var length: Int64

        var key: UnitKey { part.map(UnitKey.init) ?? .whole(file) }
    }

    /// A transfer's file and part (with the part's layout, so parts cut another way are told
    /// apart), to tell what is in flight.
    struct UnitKey: Hashable, Sendable {
        var file: String
        var part: Int?
        var layout: String?

        static func whole(_ file: String) -> UnitKey { UnitKey(file: file, part: nil, layout: nil) }

        init(file: String, part: Int?, layout: String?) {
            self.file = file
            self.part = part
            self.layout = layout
        }

        init(_ part: TransferParts.Part) {
            self.init(file: part.file, part: part.index, layout: TransferParts.layoutKey(part))
        }
    }

    /// What to send of a recording whose files are `local`, in order: smallest first and
    /// `meta.json` last, so the phone sees a recording complete only when all of it is
    /// there, and a large file never holds up the small ones. Files over a part's size go in
    /// parts. Leaves out what is in flight (a whole file in flight covers its parts) and what
    /// `holds` says the phone has (parts only of the same layout), and parts in `handedOver`
    /// (delivered, the phone's acknowledgement not in yet). `meta.json` goes unless it is in
    /// flight or the phone holds it at this size while something else of the recording is
    /// in flight, handed over or queued (their acknowledgements tell the watch what the phone
    /// holds). So when `holds` claims everything, `meta.json` goes alone and its
    /// acknowledgement corrects a stale `holds`; and an acknowledgement of `meta.json` that
    /// arrives while the last parts are still on their way does not queue it again, and
    /// again. At most `window` parts are in flight at once; `meta.json` waits until
    /// everything else is queued or handed over.
    static func units(
        local: [String: Int64], holds: PhoneHolds?, inFlight: Set<UnitKey>, handedOver: Set<UnitKey> = [],
        partSize: Int64 = TransferParts.partSize, window: Int = TransferPolicy.largestWindow
    ) -> [Unit] {
        var units: [Unit] = []
        for (name, size) in local {
            let isMeta = name == RawFormat.metaFileName
            if !isMeta, holds?.files[name] == size { continue }
            if inFlight.contains(.whole(name)) { continue }
            let parts = isMeta ? [] : TransferParts.plan(file: name, size: size, partSize: partSize)
            if parts.isEmpty {
                units.append(Unit(file: name, part: nil, length: size))
                continue
            }
            let held = Set(holds?.parts[TransferParts.layoutKey(parts[0])] ?? [])
            for part in parts where !held.contains(part.index) {
                let key = UnitKey(part)
                guard !inFlight.contains(key), !handedOver.contains(key) else { continue }
                units.append(Unit(file: name, part: part, length: part.length))
            }
        }
        let sorted = units.sorted { a, b in
            let aMeta = a.file == RawFormat.metaFileName
            let bMeta = b.file == RawFormat.metaFileName
            if aMeta != bMeta { return bMeta }
            if a.length != b.length { return a.length < b.length }
            if a.file != b.file { return a.file < b.file }
            return (a.part?.index ?? 0) < (b.part?.index ?? 0)
        }
        var budget = max(0, window - inFlight.filter { $0.part != nil }.count)
        var leftOut = false
        let queued = sorted.filter { unit in
            if unit.file == RawFormat.metaFileName { return !leftOut }
            guard unit.part != nil else { return true }
            guard budget > 0 else {
                leftOut = true
                return false
            }
            budget -= 1
            return true
        }
        let meta = RawFormat.metaFileName
        let metaHeld = local[meta].map { holds?.files[meta] == $0 } ?? false
        let othersMoving =
            queued.contains { $0.file != meta } || inFlight.contains { $0.file != meta }
            || handedOver.contains { $0.file != meta }
        return metaHeld && othersMoving ? queued.filter { $0.file != meta } : queued
    }

    /// How a recording's outstanding transfers have moved (watch side). Kept across launches
    /// (each background wake is a short look, often in a new process), so a later look can
    /// tell a transfer that has sat at the same progress since an earlier one from a transfer
    /// it sees for the first time.
    struct ProgressTracker: Codable, Equatable, Sendable {
        /// The last progress seen of each outstanding transfer (by a key naming the transfer,
        /// including when it was queued). Only the transfers of the latest look are kept.
        private var fractions: [String: Double] = [:]
        /// The last time a transfer was seen moving: progress that grew, a transfer first seen
        /// with progress, or a transfer that finished.
        private(set) var lastChange: Date?

        /// Notes each transfer's progress; returns whether any has progress, and the last time
        /// one was seen moving.
        mutating func observe(_ samples: [(key: String, fraction: Double)], now: Date) -> (
            anyProgress: Bool, since: Date?
        ) {
            var anyProgress = false
            var seen: [String: Double] = [:]
            for (key, fraction) in samples {
                if fraction > 0 {
                    anyProgress = true
                    if fraction > (fractions[key] ?? 0) { lastChange = now }
                }
                seen[key] = fraction
            }
            fractions = seen
            return (anyProgress, lastChange)
        }

        mutating func finished(at date: Date) {
            lastChange = date
        }
    }

    /// Serializes storing received files with deleting recordings on the phone, so a
    /// recording deleted as its last file is stored can't be acknowledged as complete (and
    /// then deleted on the watch too).
    static let storageLock = NSLock()

    /// How long a recording's transfers may stay outstanding without moving before a launch
    /// treats them as stuck and queues them again.
    static let stuckAfter: TimeInterval = 15 * 60
    /// How long transfers that have started may go without moving before "Send again"
    /// treats them as stalled.
    static let stalledAfter: TimeInterval = 2 * 60

    /// Whether to cancel a recording's outstanding transfers and queue them again.
    /// - Never while they move: some has progress (`anyProgress`) and `progressSince` (the
    ///   last time they were seen moving, or first seen, kept across launches) is under
    ///   `stalledAfter` ago.
    /// - "Send again" (`.all`): otherwise, yes.
    /// - Launch and background refresh (`.stuck`): if some has started, only once none has
    ///   moved for `stuckAfter` (a transfer first seen with progress counts as moving then,
    ///   so a first look never cancels a started transfer); if none has started, once the
    ///   oldest has waited `stuckAfter`. A transfer without a time (queued by a build before
    ///   times) counts as waited, as does one whose time is that far in the future (the clock
    ///   was changed).
    static func shouldRequeue(
        oldestQueuedAt: Date?, anyProgress: Bool, progressSince: Date?, now: Date, requeue: Requeue
    ) -> Bool {
        if requeue == .none { return false }
        if anyProgress, let progressSince, abs(now.timeIntervalSince(progressSince)) < stalledAfter { return false }
        if requeue == .all { return true }
        if anyProgress {
            guard let progressSince else { return false }
            return abs(now.timeIntervalSince(progressSince)) >= stuckAfter
        }
        guard let oldestQueuedAt else { return true }
        return abs(now.timeIntervalSince(oldestQueuedAt)) >= stuckAfter
    }

    /// Whether a transfer ended because it was cancelled (by `send` restarting it or by
    /// the recording being delivered), which is no reason to retry.
    static func isCancellation(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }

    /// "45 s" or "15 min", for the log.
    static func describe(_ interval: TimeInterval) -> String {
        interval < 90 ? "\(Int(interval.rounded())) s" : "\(Int((interval / 60).rounded())) min"
    }

    /// The time a transfer was queued, from its metadata.
    static func queuedAt(metadata: [String: Any]?) -> Date? {
        (metadata?[Key.queuedAt] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// The raw recording versions this build reads, as it tells the other device.
    static let readableRawVersions = RawFormat.readableVersions.sorted()

    /// The raw versions a phone reads, from its application context. Builds from before raw
    /// format 2 do not say, and read only version 1.
    static func phoneRawVersions(fromContext context: [String: Any]) -> Set<Int> {
        (context[Key.rawVersions] as? [Int]).map(Set.init) ?? [1]
    }

    /// Whether a recording of `version` may go to a phone that reads `phone`. Fails closed:
    /// a recording whose version could not be read stays on the watch (a phone build that
    /// predates the check would acknowledge it, and the watch would delete it).
    static func mayDeliver(version: Int?, toPhoneReading phone: Set<Int>) -> Bool {
        guard let version else { return false }
        return phone.contains(version)
    }

    /// Whether the recording in `folder` may go to a phone that reads `phone`: its
    /// `meta.json` names a raw format version the phone advertises.
    static func mayDeliver(folder: URL, toPhoneReading phone: Set<Int>) -> Bool {
        let data = try? Data(contentsOf: folder.appendingPathComponent(RawFormat.metaFileName))
        return mayDeliver(version: data.flatMap(metaVersion), toPhoneReading: phone)
    }

    /// The raw format version a `meta.json` declares, read from its header alone so a
    /// version this build cannot decode is still known; nil if it is not a raw recording's.
    static func metaVersion(_ data: Data) -> Int? {
        struct Header: Decodable {
            var format: String?
            var version: Int?
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: data),
            header.format == RawFormat.formatName
        else { return nil }
        return header.version
    }

    /// Whether the phone may acknowledge this `meta.json`: only a version it reads. Until
    /// then the watch keeps the recording.
    static func acknowledgesMeta(_ data: Data) -> Bool {
        guard let version = metaVersion(data) else { return false }
        return RawFormat.readableVersions.contains(version)
    }

    /// Whether settings go to and come from the other device. A Debug launch with
    /// `-demoSession` (UI tests, screenshots) keeps its settings to itself: it neither applies
    /// the paired device's settings (which would undo `-resetSettings` and leak one test's
    /// edits into the next) nor sends its own (which would overwrite the paired device's).
    let syncsSettings: Bool

    /// Whether a launch with these arguments syncs settings (`syncsSettings`).
    static func syncsSettings(arguments: [String]) -> Bool {
        !DemoFeed.isEnabled(arguments: arguments)
    }

    init(syncsSettings: Bool = RecordingTransfer.syncsSettings(arguments: ProcessInfo.processInfo.arguments)) {
        self.syncsSettings = syncsSettings
        super.init()
    }

    /// Folder names of recordings being written right now; never sent or deleted.
    private let active = Mutex<Set<String>>([])
    /// The phone's latest acknowledged holdings per recording (watch side), kept across
    /// launches so a resend skips what already arrived.
    private let phoneHolds = Mutex<[String: PhoneHolds]>(RecordingTransfer.loadPhoneHolds())
    private static let phoneHoldsKey = "transferPhoneHolds"
    /// How each recording's outstanding transfers have moved, kept across launches (watch
    /// side).
    private let progress = Mutex<[String: ProgressTracker]>(RecordingTransfer.loadProgress())
    private static let progressDefaultsKey = "transferProgress"
    /// Parts each recording handed to the phone whose acknowledgement is not in yet, and when
    /// (watch side). Not sent again for `handoverGrace`: queuing a just-delivered part again
    /// would cycle the window through the same parts while the acknowledgements lag.
    private let handedOver = Mutex<[String: [UnitKey: Date]]>([:])
    /// How long a delivered part waits for the phone's acknowledgement before it may go again.
    static let handoverGrace: TimeInterval = 10 * 60
    /// Failed rounds in a row per recording, and when the pending retry is due (watch side).
    private let retries = Mutex<[String: Retry]>([:])
    /// When the background app refresh asked for last is due (watch side).
    private let scheduledRefresh = Mutex<Date?>(nil)
    /// Delivered content and sends still being handled; a background task waits for 0.
    private let busy = Mutex(0)
    /// Runs sends one at a time (watch side).
    private let sendQueue = DispatchQueue(label: "RecordingTransfer.send", qos: .utility)

    struct Retry: Equatable, Sendable {
        var failures = 0
        var at: Date?
    }

    /// Runs `work`, counted as busy for a background task waiting on it.
    private func whileBusy<T>(_ work: () throws -> T) rethrows -> T {
        busy.withLock { $0 += 1 }
        defer { busy.withLock { $0 -= 1 } }
        return try work()
    }

    private static func loadPhoneHolds() -> [String: PhoneHolds] {
        UserDefaults.standard.data(forKey: phoneHoldsKey)
            .flatMap { try? JSONDecoder().decode([String: PhoneHolds].self, from: $0) } ?? [:]
    }

    private static func loadProgress() -> [String: ProgressTracker] {
        UserDefaults.standard.data(forKey: progressDefaultsKey)
            .flatMap { try? JSONDecoder().decode([String: ProgressTracker].self, from: $0) } ?? [:]
    }

    /// Changes the progress kept of recordings, saving it when it changed.
    @discardableResult
    private func updateProgress<T>(_ body: (inout [String: ProgressTracker]) -> T) -> T {
        progress.withLock { all in
            let before = all
            let result = body(&all)
            if all != before, let data = try? JSONEncoder().encode(all) {
                UserDefaults.standard.set(data, forKey: Self.progressDefaultsKey)
            }
            return result
        }
    }

    private func setPhoneHolds(_ holds: PhoneHolds?, sessionId: String) {
        phoneHolds.withLock { all in
            all[sessionId] = holds
            if let data = try? JSONEncoder().encode(all) {
                UserDefaults.standard.set(data, forKey: Self.phoneHoldsKey)
            }
        }
    }

    private var log: TransferLog { .shared }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Marks a recording as in progress (or not). Called by SessionRecorder on both devices.
    func markActive(_ folder: URL, _ isActive: Bool) {
        active.withLock { set in
            if isActive { set.insert(folder.lastPathComponent) } else { set.remove(folder.lastPathComponent) }
        }
    }

    private func isActive(_ name: String) -> Bool {
        active.withLock { $0.contains(name) }
    }

    /// Whether a recording folder is still being written on this device.
    func isRecording(_ folder: URL) -> Bool {
        isActive(folder.lastPathComponent)
    }

    // MARK: Watch: sending

    #if os(watchOS)
        /// Queues what the phone still lacks of `folder` and is not in flight, after cancelling
        /// the recording's outstanding transfers if `requeue` and `shouldRequeue` say so. Runs
        /// on the send queue after any send asked for earlier, so two callers (the UI, an
        /// acknowledgement, a finished part, a retry, a background wake) never queue the same
        /// part twice.
        func send(folder: URL, requeue: Requeue = .none) {
            busy.withLock { $0 += 1 }
            sendQueue.async {
                defer { self.busy.withLock { $0 -= 1 } }
                self.sendNow(folder: folder, requeue: requeue)
            }
        }

        private func sendNow(folder: URL, requeue: Requeue) {
            let session = WCSession.default
            let sessionId = folder.lastPathComponent
            guard !isActive(sessionId) else { return }
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            guard session.activationState == .activated else {
                log.add("Not sent: the connection to iPhone is not active yet", sessionId: sessionId)
                scheduleRefresh(hasPending: true)
                return
            }
            guard let local = Self.recordingFiles(in: folder), !local.isEmpty else {
                log.add("Not sent: no readable recording files in the folder", sessionId: sessionId)
                return
            }
            guard phoneReads(folder: folder) else {
                let phone = Self.phoneRawVersions(fromContext: session.receivedApplicationContext)
                let data = try? Data(contentsOf: folder.appendingPathComponent(RawFormat.metaFileName))
                if let version = data.flatMap(Self.metaVersion) {
                    log.add(
                        "Not sent: the iPhone app reads raw versions \(phone.sorted()), not \(version)",
                        sessionId: sessionId)
                } else {
                    log.add("Not sent: meta.json is missing or unreadable", sessionId: sessionId)
                }
                return
            }

            let now = Date()
            var outstanding = session.outstandingFileTransfers
                .filter { $0.file.metadata?[Key.sessionId] as? String == sessionId }
            let moved = observe(sessionId: sessionId, transfers: outstanding, now: now)
            if !outstanding.isEmpty {
                // A transfer without a time (an earlier build's) makes the oldest unknown.
                let times = outstanding.map { Self.queuedAt(metadata: $0.file.metadata) }
                let oldest = times.contains { $0 == nil } ? nil : times.compactMap { $0 }.min()
                if Self.shouldRequeue(
                    oldestQueuedAt: oldest, anyProgress: moved.anyProgress, progressSince: moved.since, now: now,
                    requeue: requeue)
                {
                    for transfer in outstanding { transfer.cancel() }
                    let age = oldest.map { "\(Int(now.timeIntervalSince($0) / 60)) min" } ?? "since an earlier build"
                    log.add(
                        "Cancelled \(outstanding.count) transfers that had not moved (queued \(age)) to send again",
                        sessionId: sessionId)
                    outstanding = []
                    updateProgress { $0[sessionId] = nil }
                } else if requeue != .none {
                    let lead = outstanding.max { $0.progress.fractionCompleted < $1.progress.fractionCompleted }
                    log.add(
                        "Still sending \(outstanding.count) transfers"
                            + (lead.map { " (\(Self.describe($0)) at \(Int($0.progress.fractionCompleted * 100))%)" }
                                ?? ""),
                        sessionId: sessionId)
                }
            }

            // Slices no transfer uses (lost when the watch restarted, or cancelled above).
            let inUse = Set(outstanding.map { $0.file.fileURL.lastPathComponent })
            for stale in TransferParts.staleSlices(in: folder, inUse: inUse) {
                try? FileManager.default.removeItem(at: stale)
            }

            let inFlight = Set(outstanding.compactMap(Self.unitKey))
            let holds = phoneHolds.withLock { $0[sessionId] }
            let recent = handedOver.withLock { all -> Set<UnitKey> in
                let kept = (all[sessionId] ?? [:]).filter { abs(now.timeIntervalSince($0.value)) < Self.handoverGrace }
                all[sessionId] = kept.isEmpty ? nil : kept
                return Set(kept.keys)
            }
            let window = TransferPolicy.window(freeSpace: Self.freeSpace(at: folder))
            let units = Self.units(
                local: local, holds: holds, inFlight: inFlight, handedOver: recent, window: window)
            defer { scheduleRefresh(hasPending: true) }
            var queued: [String] = []
            for unit in units {
                let url: URL
                var metadata: [String: Any] = [
                    Key.sessionId: sessionId, Key.file: unit.file, Key.queuedAt: now.timeIntervalSince1970,
                ]
                if let part = unit.part {
                    do {
                        url = try TransferParts.slice(part, in: folder)
                    } catch {
                        log.add("Could not prepare \(unit.file) part \(part.index + 1): \(error)", sessionId: sessionId)
                        continue
                    }
                    metadata.merge(TransferParts.metadata(for: part)) { $1 }
                } else {
                    url = folder.appendingPathComponent(unit.file)
                }
                session.transferFile(url, metadata: metadata)
                queued.append(unit.part.map { "\(unit.file) part \($0.index + 1)/\($0.count)" } ?? unit.file)
            }
            if !queued.isEmpty {
                let summary =
                    queued.count > 8
                    ? "\(queued.prefix(8).joined(separator: ", ")) and \(queued.count - 8) more"
                    : queued.joined(separator: ", ")
                log.add("Queued \(summary)", sessionId: sessionId)
            }
        }

        /// The free space on the volume holding `url`, for the window of parts.
        private static func freeSpace(at url: URL) -> Int64? {
            ((try? FileManager.default.attributesOfFileSystem(forPath: url.path))?[.systemFreeSize] as? NSNumber)?
                .int64Value
        }

        /// Notes how a recording's outstanding transfers have moved (`ProgressTracker`).
        private func observe(
            sessionId: String, transfers: [WCSessionFileTransfer], now: Date
        ) -> (anyProgress: Bool, since: Date?) {
            let samples = transfers.map { (key: Self.progressKey($0), fraction: $0.progress.fractionCompleted) }
            return updateProgress { $0[sessionId, default: ProgressTracker()].observe(samples, now: now) }
        }

        private static func progressKey(_ transfer: WCSessionFileTransfer) -> String {
            let metadata = transfer.file.metadata
            let file = metadata?[Key.file] as? String ?? transfer.file.fileURL.lastPathComponent
            let part = (try? TransferParts.part(file: file, metadata: metadata))?.index ?? -1
            return "\(file)#\(part)#\(metadata?[Key.queuedAt] as? Double ?? 0)"
        }

        private static func unitKey(_ transfer: WCSessionFileTransfer) -> UnitKey? {
            guard let file = transfer.file.metadata?[Key.file] as? String else { return nil }
            return (try? TransferParts.part(file: file, metadata: transfer.file.metadata)).map(UnitKey.init)
                ?? .whole(file)
        }

        private static func describe(_ transfer: WCSessionFileTransfer) -> String {
            let metadata = transfer.file.metadata
            let file = metadata?[Key.file] as? String ?? transfer.file.fileURL.lastPathComponent
            guard let part = try? TransferParts.part(file: file, metadata: metadata) else { return file }
            return "\(file) part \(part.index + 1)/\(part.count)"
        }

        /// The transfers of one recording still queued or in progress.
        func outstanding(sessionId: String) -> [Outstanding] {
            let transfers = WCSession.default.outstandingFileTransfers
                .filter { $0.file.metadata?[Key.sessionId] as? String == sessionId }
            _ = observe(sessionId: sessionId, transfers: transfers, now: Date())
            return transfers.map { transfer in
                let file = transfer.file.metadata?[Key.file] as? String ?? transfer.file.fileURL.lastPathComponent
                let part = try? TransferParts.part(file: file, metadata: transfer.file.metadata)
                return Outstanding(
                    file: file, part: part?.index, parts: part?.count,
                    queuedAt: Self.queuedAt(metadata: transfer.file.metadata),
                    fractionCompleted: transfer.progress.fractionCompleted,
                    isTransferring: transfer.isTransferring)
            }
            .sorted { ($0.file, $0.part ?? -1) < ($1.file, $1.part ?? -1) }
        }

        /// What the phone last said it holds of a recording.
        func phoneFiles(sessionId: String) -> PhoneHolds? {
            phoneHolds.withLock { $0[sessionId] }
        }

        /// The background refresh asked for this launch, if still to come, for the diagnostics.
        func nextBackgroundWake() -> Date? {
            scheduledRefresh.withLock { $0 }.flatMap { $0 > Date() ? $0 : nil }
        }

        /// A recording's failed rounds in a row and pending retry, for the diagnostics.
        func retry(sessionId: String) -> Retry? {
            retries.withLock { $0[sessionId] }
        }

        /// Whether the paired phone's app reads this recording's raw format version. If not
        /// (or the version cannot be read), the recording stays on the watch, which asks for
        /// the phone app to be updated.
        func phoneReads(folder: URL) -> Bool {
            let phone = Self.phoneRawVersions(fromContext: WCSession.default.receivedApplicationContext)
            return Self.mayDeliver(folder: folder, toPhoneReading: phone)
        }

        /// Sends every finished recording still on the watch, including ones interrupted
        /// in an earlier launch (they have no `endedAt`, which readers handle).
        func sendAllPending(requeue: Requeue = .none) {
            // What the phone held of recordings no longer on the watch.
            let gone = phoneHolds.withLock { Array($0.keys) }.filter {
                !FileManager.default.fileExists(atPath: RecordingStore.root.appendingPathComponent($0).path)
            }
            for sessionId in gone { setPhoneHolds(nil, sessionId: sessionId) }
            updateProgress { all in
                all = all.filter {
                    FileManager.default.fileExists(atPath: RecordingStore.root.appendingPathComponent($0.key).path)
                }
            }
            for entry in RecordingStore.list() {
                send(folder: entry.folder, requeue: requeue)
            }
        }

        // MARK: Watch: retries and background

        /// After a failed transfer, sends the recording again once `TransferPolicy.retryDelay`
        /// has passed. One retry is pending per recording, so parts failing together count
        /// as one failure. Returns the wait, or nil if a retry was already pending.
        private func scheduleRetry(sessionId: String, folder: URL) -> TimeInterval? {
            let now = Date()
            let delay: TimeInterval? = retries.withLock { all in
                var retry = all[sessionId, default: Retry()]
                if let at = retry.at, at > now { return nil }
                retry.failures += 1
                let delay = TransferPolicy.retryDelay(afterFailures: retry.failures)
                retry.at = now.addingTimeInterval(delay)
                all[sessionId] = retry
                return delay
            }
            guard let delay else { return nil }
            // Fires late if the app is suspended; the background refresh asked for below
            // wakes it, and its send covers the retry.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                self.retries.withLock { $0[sessionId]?.at = nil }
                guard FileManager.default.fileExists(atPath: folder.path) else { return }
                self.log.add("Sending again after the failure", sessionId: sessionId)
                self.send(folder: folder)
            }
            scheduleRefresh(hasPending: true)
            return delay
        }

        /// Keeps a background app refresh asked for while recordings wait
        /// (`TransferPolicy.nextRefresh`), so a suspended app wakes to send even when no
        /// acknowledgement wakes it.
        private func scheduleRefresh(hasPending: Bool) {
            let now = Date()
            let retryAt = retries.withLock { $0.values.compactMap(\.at).min() }
            guard let wanted = TransferPolicy.nextRefresh(now: now, hasPending: hasPending, retryAt: retryAt) else {
                return
            }
            let asks = scheduledRefresh.withLock { scheduled in
                guard TransferPolicy.shouldSchedule(wanted: wanted, scheduled: scheduled, now: now) else {
                    return false
                }
                scheduled = wanted
                return true
            }
            guard asks else { return }
            busy.withLock { $0 += 1 }
            DispatchQueue.main.async {
                defer { self.busy.withLock { $0 -= 1 } }
                MainActor.assumeIsolated {
                    WKApplication.shared().scheduleBackgroundRefresh(
                        withPreferredDate: wanted, userInfo: TransferPolicy.refreshIdentifier as NSString
                    ) { error in
                        if let error {
                            self.scheduledRefresh.withLock { $0 = nil }
                            self.log.add("Could not ask to wake in the background: \(error.localizedDescription)")
                        }
                    }
                }
            }
            log.add("Asked to wake in the background in \(Self.describe(wanted.timeIntervalSince(now)))")
        }

        /// A WatchConnectivity background task: the phone's acknowledgements woke the app.
        /// Returns once the session is active, has delivered everything, and what it delivered
        /// has been handled, including the sends that topped up the window
        /// (`TransferPolicy.backgroundWorkDone`), or when the task's time runs out.
        func finishBackgroundDelivery() async {
            if WCSession.default.delegate !== self { activate() }
            let done = await waitUntil(limit: TransferPolicy.backgroundTaskLimit) { [self] in
                let session = WCSession.default
                return TransferPolicy.backgroundWorkDone(
                    activated: session.activationState == .activated, hasContentPending: session.hasContentPending,
                    busy: busy.withLock { $0 })
            }
            if !done { log.add("A background wake ended before everything it delivered was handled") }
        }

        /// A background app refresh: sends what waits (restarting transfers stuck for
        /// `stuckAfter`). Each send asks for the next refresh while its recording can still go,
        /// so a recording the phone cannot read does not keep waking the app.
        func resumeFromRefresh() async {
            scheduledRefresh.withLock { $0 = nil }
            if WCSession.default.delegate !== self { activate() }
            _ = await waitUntil(limit: 10) { WCSession.default.activationState == .activated }
            let waiting = RecordingStore.list().filter { !isActive($0.folder.lastPathComponent) }.count
            if waiting > 0 {
                log.add("Woke in the background with \(waiting) recording\(waiting == 1 ? "" : "s") to send")
            }
            sendAllPending(requeue: .stuck)
            await finishBackgroundDelivery()
        }

        /// Waits until `condition` holds, up to `limit` or the task's cancellation; returns
        /// whether it held.
        private func waitUntil(limit: TimeInterval, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(limit)
            while !condition() {
                guard !Task.isCancelled, Date() < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return true
        }

        nonisolated func session(
            _ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?
        ) {
            whileBusy { finished(fileTransfer, error: error) }
        }

        private func finished(_ fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
            // Delivery is not storage: only the phone's acknowledgement allows deleting.
            let sessionId = fileTransfer.file.metadata?[Key.sessionId] as? String
            let name = Self.describe(fileTransfer)
            let file = fileTransfer.file.metadata?[Key.file] as? String ?? fileTransfer.file.fileURL.lastPathComponent
            let part = try? TransferParts.part(file: file, metadata: fileTransfer.file.metadata)
            let isPart = part != nil
            // Done either way: a part's slice is written again if it has to go again.
            if isPart { TransferParts.removeSlice(at: fileTransfer.file.fileURL) }
            let folder = sessionId.map { RecordingStore.root.appendingPathComponent($0, isDirectory: true) }
            let exists = folder.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            if let error {
                let nsError = error as NSError
                var line = "Sending \(name) failed: \(error.localizedDescription) (\(nsError.domain) \(nsError.code))"
                // Not at once: it could fail again at once. Cancelled ones were sent again.
                if !Self.isCancellation(nsError), let sessionId, let folder, exists,
                    let delay = scheduleRetry(sessionId: sessionId, folder: folder)
                {
                    line += "; sending again in \(Self.describe(delay))"
                }
                log.add(line, sessionId: sessionId)
                return
            }
            guard let sessionId else { return }
            let now = Date()
            updateProgress { $0[sessionId, default: ProgressTracker()].finished(at: now) }
            retries.withLock { $0[sessionId]?.failures = 0 }
            // Not sent again while its acknowledgement is on the way (`handoverGrace`).
            if let part { handedOver.withLock { $0[sessionId, default: [:]][UnitKey(part)] = now } }
            // Keeps the window of parts full (`TransferPolicy.window`).
            if isPart, exists, let folder { send(folder: folder) }
            if !isPart {
                // Not for every part: the phone's acknowledgements show those.
                log.add("Handed \(name) to iPhone; waiting for it to confirm", sessionId: sessionId)
            }
        }

        nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
            whileBusy { receivedAcknowledgement(userInfo) }
        }

        private func receivedAcknowledgement(_ userInfo: [String: Any]) {
            guard userInfo[Key.stored] as? Bool == true,
                let sessionId = userInfo[Key.sessionId] as? String,
                UUID(uuidString: sessionId) != nil
            else { return }
            guard let phone = Self.phoneFiles(fromAcknowledgement: userInfo) else {
                log.add(
                    "iPhone confirmed a file without listing its files (older iPhone build); ignored",
                    sessionId: sessionId)
                return
            }
            let parts = Self.phoneParts(fromAcknowledgement: userInfo)
            setPhoneHolds(PhoneHolds(files: phone, parts: parts), sessionId: sessionId)
            log.add(
                "iPhone holds \(TransferLog.describe(phone))\(TransferLog.describe(parts: parts))", sessionId: sessionId
            )
            // The link works: a retry after this starts from the shortest wait.
            retries.withLock { $0[sessionId]?.failures = 0 }
            let isMeta = userInfo[Key.file] as? String == RawFormat.metaFileName
            // Why the watch keeps it, only once meta.json (sent last) is in, not for every part.
            let delivered = deleteIfDelivered(sessionId: sessionId, phone: phone, logsWhyKept: isMeta)
            // Sends what the phone lacks and is not in flight: the next parts of the window
            // (this is what keeps a suspended watch app sending, since acknowledgements wake
            // it and finished transfers do not), or, once meta.json is in, what the phone lost
            // or never got.
            if !delivered {
                let folder = RecordingStore.root.appendingPathComponent(sessionId, isDirectory: true)
                if FileManager.default.fileExists(atPath: folder.path) { send(folder: folder) }
            }
        }

        /// Deletes the recording if `phone`, the phone's latest list for it, holds all of it.
        /// Returns whether it is gone.
        @discardableResult
        private func deleteIfDelivered(sessionId: String, phone: [String: Int64], logsWhyKept: Bool = true) -> Bool {
            guard !isActive(sessionId) else { return false }
            let folder = RecordingStore.root.appendingPathComponent(sessionId, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return true }
            guard let local = Self.recordingFiles(in: folder) else {
                log.add("Kept on watch: could not list its files", sessionId: sessionId)
                return false
            }
            let gaps = Self.deliveryGaps(local: local, phone: phone)
            guard gaps.isEmpty else {
                if logsWhyKept { log.add("Kept on watch: \(gaps.joined(separator: "; "))", sessionId: sessionId) }
                return false
            }
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                log.add("Could not remove the delivered recording: \(error.localizedDescription)", sessionId: sessionId)
                return false
            }
            log.add("Removed from watch: iPhone holds all \(local.count) files", sessionId: sessionId)
            setPhoneHolds(nil, sessionId: sessionId)
            updateProgress { $0[sessionId] = nil }
            handedOver.withLock { $0[sessionId] = nil }
            retries.withLock { $0[sessionId] = nil }
            // Copies re-queued after a stall have nothing left to send.
            for transfer in WCSession.default.outstandingFileTransfers
            where transfer.file.metadata?[Key.sessionId] as? String == sessionId {
                transfer.cancel()
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didDeliverRecording, object: nil)
            }
            return true
        }
    #endif

    // MARK: Phone: receiving

    #if os(iOS)
        /// Stores the file before returning (WatchConnectivity deletes it afterwards), then
        /// acknowledges it. Nothing is acknowledged unless it is safely on disk. Runs with
        /// background time (`withBackgroundTime`): the phone may have been launched in the
        /// background to receive it, and joining a large file takes a moment.
        nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
            Self.withBackgroundTime("Storing a recording from Apple Watch") { receive(file, session: session) }
        }

        private func receive(_ file: WCSessionFile, session: WCSession) {
            guard let sessionId = (file.metadata?[Key.sessionId] as? String)?.lowercased(),
                let name = file.metadata?[Key.file] as? String,
                UUID(uuidString: sessionId) != nil,
                RecordingStore.isRecordingFileName(name)
            else {
                log.add(
                    "Ignored a file without valid metadata (\(file.fileURL.lastPathComponent))",
                    sessionId: file.metadata?[Key.sessionId] as? String)
                return
            }
            let part: TransferParts.Part?
            do {
                part = try TransferParts.part(file: name, metadata: file.metadata)
            } catch {
                log.add("Ignored a part of \(name): \(error)", sessionId: sessionId)
                return
            }
            if name == RawFormat.metaFileName {
                // meta.json always comes whole: it decides whether the recording is readable.
                guard part == nil else {
                    log.add("Ignored meta.json sent in parts", sessionId: sessionId)
                    return
                }
                let data = (try? Data(contentsOf: file.fileURL)) ?? Data()
                if !Self.acknowledgesMeta(data) {
                    // A version this build cannot read: not stored, not acknowledged, so the
                    // watch keeps the recording until this app is updated.
                    let version = Self.metaVersion(data).map(String.init) ?? "unreadable"
                    log.add(
                        "Rejected meta.json (\(data.count) bytes): raw version \(version); this build reads "
                            + "\(RawFormat.readableVersions.sorted())",
                        sessionId: sessionId)
                    return
                }
            }
            let fm = FileManager.default
            let folder = RecordingStore.recordingsRoot.appendingPathComponent(sessionId, isDirectory: true)
            let destination = folder.appendingPathComponent(name)
            Self.storageLock.lock()
            defer { Self.storageLock.unlock() }
            // Stage next to the destination (same volume) so replacing is atomic and an old
            // copy survives if anything fails.
            var staged: URL?
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if let part {
                    let label = "\(name) part \(part.index + 1)/\(part.count)"
                    // Stored parts show in the confirmation below; only the unusual is logged.
                    switch try TransferParts.store(file.fileURL, as: part, in: folder) {
                    case .stored: break
                    case .alreadyHad: log.add("Already had \(label); kept it", sessionId: sessionId)
                    case .replaced: log.add("Replaced \(label)", sessionId: sessionId)
                    }
                } else {
                    let whole = folder.appendingPathComponent(
                        "\(RecordingStore.stagingPrefix)\(UUID().uuidString)-\(name)")
                    staged = whole
                    try fm.moveItem(at: file.fileURL, to: whole)
                    try place(whole, at: destination, name: name, sessionId: sessionId)
                    TransferParts.removeParts(file: name, in: folder)
                }
            } catch {
                if let staged { try? fm.removeItem(at: staged) }
                let nsError = error as NSError
                log.add(
                    "Could not store \(name): \(error) (\(nsError.domain) \(nsError.code))", sessionId: sessionId)
                return
            }
            // Joins every file whose parts are all here: the one just completed, or one whose
            // join was cut short (the app stopped) and that no further part would trigger.
            joinCompleteFiles(in: folder, sessionId: sessionId)
            acknowledge(folder: folder, sessionId: sessionId, file: name, session: session)
        }

        /// Joins every file of the recording in `folder` whose parts are all held, and puts it
        /// in place. Returns the files joined. The caller holds `storageLock`.
        @discardableResult
        private func joinCompleteFiles(in folder: URL, sessionId: String) -> [String] {
            var done: [String] = []
            for ready in TransferParts.complete(in: folder) {
                var joined: URL?
                do {
                    joined = try TransferParts.join(ready, in: folder, stagingPrefix: RecordingStore.stagingPrefix)
                    if let joined {
                        try place(joined, at: folder.appendingPathComponent(ready.file), name: ready.file, sessionId: sessionId)
                        log.add("Joined \(ready.file) from \(ready.count) parts", sessionId: sessionId)
                        done.append(ready.file)
                    }
                } catch {
                    if let joined { try? FileManager.default.removeItem(at: joined) }
                    log.add("Could not join \(ready.file); its parts go again: \(error)", sessionId: sessionId)
                }
                // Either way the parts go: kept, they would tell the watch not to send them.
                TransferParts.removeParts(file: ready.file, in: folder)
            }
            return done
        }

        /// Tells the watch what the phone holds of the recording in `folder` now (after
        /// storing `file`): every recording file with its size, so a file it lost since an
        /// earlier acknowledgement keeps the watch's copy, and the parts of files still
        /// arriving. The caller holds `storageLock`, so the list is what is stored.
        private func acknowledge(folder: URL, sessionId: String, file: String, session: WCSession) {
            guard let stored = Self.recordingFiles(in: folder) else {
                log.add("Could not list the recording after storing \(file); not confirmed", sessionId: sessionId)
                return
            }
            let parts = TransferParts.held(in: folder)
            session.transferUserInfo([
                Key.stored: true, Key.sessionId: sessionId, Key.file: file, Key.files: stored, Key.parts: parts,
            ])
            log.add(
                "Confirmed to watch: \(TransferLog.describe(stored))\(TransferLog.describe(parts: parts))",
                sessionId: sessionId)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didReceiveFile, object: nil)
            }
        }

        /// Finishes joins cut short when the app stopped (in the background, iOS may suspend
        /// or end it) and tells the watch, which otherwise waits for its next send. Runs at
        /// activation, before WatchConnectivity delivers anything new.
        private func finishInterruptedJoins(session: WCSession) {
            let fm = FileManager.default
            let root = RecordingStore.recordingsRoot
            let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for folder in folders {
                let parts = folder.appendingPathComponent(TransferParts.folderName)
                guard fm.fileExists(atPath: parts.path) else { continue }
                let sessionId = folder.lastPathComponent
                guard UUID(uuidString: sessionId) != nil, !isActive(sessionId) else { continue }
                Self.withBackgroundTime("Joining a recording from Apple Watch") {
                    Self.storageLock.withLock {
                        if let last = joinCompleteFiles(in: folder, sessionId: sessionId).last {
                            acknowledge(folder: folder, sessionId: sessionId, file: last, session: session)
                        }
                    }
                }
            }
        }

        /// Runs `work` (synchronously, on this thread) while holding an expiring background
        /// activity, so iOS does not suspend an app launched in the background to receive a
        /// file halfway through storing or joining it. If time runs out anyway, the staged
        /// copies are removed at the next launch and the parts stay to be joined then.
        static func withBackgroundTime(_ reason: String, _ work: () -> Void) {
            let done = DispatchSemaphore(value: 0)
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
                // The activity lasts while this block runs; it is called again with
                // `expired` when the time is up, and then must return.
                if !expired { _ = done.wait(timeout: .now() + 120) }
            }
            defer { done.signal() }
            work()
        }

        /// Puts a staged file at `destination`. A file already there at the same size stays
        /// (a finished recording's files never change, so replacing would only risk it), and
        /// the staged copy is removed; a different size is replaced.
        private func place(_ staged: URL, at destination: URL, name: String, sessionId: String) throws {
            let fm = FileManager.default
            let incoming = Self.storedSize(at: staged)
            if let existing = Self.storedSize(at: destination) {
                if existing == incoming {
                    try? fm.removeItem(at: staged)
                    log.add("Already had \(name) (\(existing) bytes); kept it", sessionId: sessionId)
                } else {
                    try Self.replace(destination, with: staged)
                    log.add(
                        "Replaced \(name): \(existing) bytes with \(incoming.map(String.init) ?? "?") bytes",
                        sessionId: sessionId)
                }
            } else {
                try fm.moveItem(at: staged, to: destination)
                log.add("Stored \(name) (\(incoming.map(String.init) ?? "?") bytes)", sessionId: sessionId)
            }
        }

        private static func storedSize(at url: URL) -> Int64? {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
        }

        /// Replaces `destination` with `staged`. If the replace fails after moving the stored
        /// copy aside, it is moved back, so a file the phone acknowledged stays in place
        /// (`NSFileManager.h` names the key only as a string).
        static func replace(_ destination: URL, with staged: URL) throws {
            let fm = FileManager.default
            do {
                _ = try fm.replaceItemAt(destination, withItemAt: staged)
            } catch {
                if !fm.fileExists(atPath: destination.path),
                    let original = (error as NSError).userInfo["NSFileOriginalItemLocationKey"] as? URL
                {
                    try? fm.moveItem(at: original, to: destination)
                }
                throw error
            }
        }

        nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

        nonisolated func sessionDidDeactivate(_ session: WCSession) {
            // The user switched watches; activate for the new one.
            session.activate()
        }
    #endif

    // MARK: Settings (both ways)

    // Each device sends its whole settings snapshot as its application context (only the
    // latest is delivered). Every setting carries its own stamp; the receiver takes each
    // setting whose stamp is newer (`SettingsSync`) and answers with its own snapshot when
    // it holds something newer, so both converge. Settings the sender does not send are
    // left alone, so the two apps can run different builds without losing each other's
    // newer settings.
    // Applying runs on the main actor, like local edits, so the two never interleave.

    #if os(iOS)
        /// Resends settings when the watch app is installed (or the pairing changes): an
        /// earlier push returns early while the app is missing.
        nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
            pushSettingsOnMain()
        }
    #else
        /// Resends settings once the iPhone app is installed.
        nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
            pushSettingsOnMain()
        }
    #endif

    /// Sends this device's settings to the other one. If the session cannot send yet,
    /// activation (and the install callbacks above) send them later; the snapshot is read
    /// at that point, so nothing is lost. Main actor only, like every settings write, so a
    /// snapshot's values and revision always come from one consistent state.
    @MainActor
    func pushSettings() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        #if os(iOS)
            guard session.isPaired, session.isWatchAppInstalled else { return }
        #else
            guard session.isCompanionAppInstalled else { return }
        #endif
        var context: [String: Any] = [:]
        if syncsSettings { context[Key.settings] = UserSettings.snapshot() }
        #if os(iOS)
            // Tells the watch which recordings this build can receive.
            context[Key.rawVersions] = Self.readableRawVersions
        #endif
        guard !context.isEmpty else { return }
        do {
            try session.updateApplicationContext(context)
        } catch {
            print("RecordingTransfer: settings update failed: \(error)")
        }
    }

    /// For WatchConnectivity callbacks, which arrive off the main actor.
    nonisolated private func pushSettingsOnMain() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.pushSettings() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        receiveSettings(context)
        #if os(watchOS)
            // The phone may now read recordings it could not before.
            sendAllPending()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didDeliverRecording, object: nil)
            }
        #endif
    }

    /// Hops to the main actor (in arrival order) to apply a snapshot from the other device,
    /// then pushes this device's settings if the other side is behind, or if `alwaysPush`.
    nonisolated private func receiveSettings(_ context: [String: Any], alwaysPush: Bool = false) {
        let snapshot = SendableSnapshot(value: context[Key.settings] as? [String: Any])
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if self.applyReceivedSettings(snapshot.value, alwaysPush: alwaysPush) { self.pushSettings() }
            }
        }
    }

    /// Applies a settings snapshot from the other device (unless this launch keeps its
    /// settings to itself, `syncsSettings`) and returns whether to push this device's context.
    /// An isolated launch still honours `alwaysPush`: its push carries no settings, but the
    /// phone's still tells the watch which recording formats it can receive.
    @MainActor
    func applyReceivedSettings(_ snapshot: [String: Any]?, alwaysPush: Bool = false) -> Bool {
        guard syncsSettings else { return alwaysPush }
        var push = alwaysPush
        if let outcome = snapshot.map({ UserSettings.apply($0) }) {
            if outcome.changed {
                NotificationCenter.default.post(name: UserSettings.didChangeRemotely, object: nil)
                #if os(iOS)
                    // Keep the phone's outgoing context current, for a watch app
                    // reinstalled later.
                    push = true
                #endif
            }
            if outcome.replyNeeded { push = true }
        }
        return push
    }

    /// Property-list values from WatchConnectivity, handed to the main queue unchanged.
    private struct SendableSnapshot: @unchecked Sendable {
        let value: [String: Any]?
    }

    // MARK: Both

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        if let error {
            log.add("Connection to the other device failed: \(error.localizedDescription)")
        }
        guard activationState == .activated else { return }
        log.add("Connected to the other device")
        // Both sides send their settings on activation: an edit made before activation
        // (whose push returned early) goes out now, and the receiver keeps the newer.
        receiveSettings(session.receivedApplicationContext, alwaysPush: true)
        #if os(watchOS)
            // Transfers left stuck since an earlier launch go again.
            sendAllPending(requeue: .stuck)
        #else
            finishInterruptedJoins(session: session)
        #endif
    }
}
