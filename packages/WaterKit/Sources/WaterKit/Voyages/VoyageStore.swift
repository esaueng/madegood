import Foundation

public struct Voyage: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public fileprivate(set) var legs: [VoyageLeg] = []
}

public struct VoyageLeg: Codable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: TimeInterval
    public fileprivate(set) var endedAt: TimeInterval?
    public fileprivate(set) var endingGap: VoyageGap?
}

/// Single-owner, device-local Voyage storage. The index is replaced atomically at
/// lifecycle transitions. Each leg has its own newline-delimited position journal
/// so recording never rewrites the accumulated track.
public struct VoyageStore {
    public enum StoreError: LocalizedError {
        case emptyName, unknownVoyage, activeLegExists, noActiveLeg, captureStopped, unsupportedVersion

        public var errorDescription: String? {
            switch self {
            case .emptyName: "Enter a voyage name."
            case .unknownVoyage: "This voyage could not be found."
            case .activeLegExists: "End the active leg before starting another."
            case .noActiveLeg: "There is no active leg."
            case .captureStopped: "Resume the active leg to record positions."
            case .unsupportedVersion: "This version of MadeGood cannot open the voyage library."
            }
        }
    }

    private struct Index: Codable {
        var version = 1
        var voyages: [Voyage] = []
    }

    private let root: URL
    private var index: Index
    private var sampling: VoyageSampling?
    public private(set) var activeLastFix: VoyagePosition?
    public private(set) var activeLatestGap: VoyageGap?
    public private(set) var activeFixCount = 0

    public var voyages: [Voyage] { index.voyages }

    public var activeVoyage: Voyage? {
        voyages.first { voyage in
            guard let leg = voyage.legs.last else { return false }
            return leg.endedAt == nil
        }
    }

    public var activeLeg: VoyageLeg? { activeVoyage?.legs.last }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let data = try Data(contentsOf: root.appendingPathComponent("index.json"))
            index = try JSONDecoder().decode(Index.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            index = Index()
        }
        guard index.version == 1 else { throw StoreError.unsupportedVersion }
        if let leg = activeLeg { try recoverTrack(for: leg) }
    }

    @discardableResult
    public mutating func createVoyage(named name: String) throws -> Voyage {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw StoreError.emptyName }
        let voyage = Voyage(id: UUID(), name: trimmedName)
        var next = index
        next.voyages.insert(voyage, at: 0)
        try save(next)
        return voyage
    }

    @discardableResult
    public mutating func startLeg(in voyageID: UUID, at time: TimeInterval) throws -> VoyageLeg {
        guard activeLeg == nil else { throw StoreError.activeLegExists }
        guard let voyageIndex = voyages.firstIndex(where: { $0.id == voyageID }) else { throw StoreError.unknownVoyage }
        let leg = VoyageLeg(id: UUID(), startedAt: time)
        var next = index
        next.voyages[voyageIndex].legs.append(leg)
        try save(next)
        activeFixCount = 0
        activeLastFix = nil
        activeLatestGap = nil
        sampling = VoyageSampling(startedAt: time, acceptsFrom: time, lastSaved: nil, interrupted: false)
        return leg
    }

    public mutating func resumeLeg(at time: TimeInterval) throws {
        guard let leg = activeLeg else { throw StoreError.noActiveLeg }
        try recoverTrack(for: leg)
        sampling = VoyageSampling(
            startedAt: leg.startedAt, acceptsFrom: max(time, leg.startedAt),
            lastSaved: activeLastFix, interrupted: true)
    }

    /// Core Location can suspend updates while it knows the device is stationary.
    public mutating func setStationaryPause(_ paused: Bool) {
        let hasFix = sampling?.lastSeen != nil
        sampling?.stationaryPause = paused && hasFix
    }

    public mutating func interruptCapture() {
        sampling?.interrupted = true
    }

    /// Returns true for a fresh usable position, including positions skipped by sampling.
    @discardableResult
    public mutating func record(_ position: VoyagePosition) throws -> Bool {
        guard let leg = activeLeg else { throw StoreError.noActiveLeg }
        guard var sampling else { throw StoreError.captureStopped }
        let previousTime = sampling.lastSeen
        let point = sampling.ingest(position)
        guard sampling.lastSeen != previousTime else { return false }
        if let point {
            do {
                try append(point, to: leg)
            } catch {
                // Reload the committed prefix on Resume or End, even if rollback failed.
                self.sampling = nil
                throw error
            }
            activeFixCount += 1
            activeLastFix = position
            if let gap = point.gapBefore { activeLatestGap = gap }
        }
        self.sampling = sampling
        return true
    }

    @discardableResult
    public mutating func endLeg(at time: TimeInterval) throws -> VoyageLeg {
        guard let voyage = activeVoyage, let leg = activeLeg,
            let voyageIndex = voyages.firstIndex(where: { $0.id == voyage.id })
        else { throw StoreError.noActiveLeg }
        if sampling == nil { try recoverTrack(for: leg) }
        let coverage =
            sampling
            ?? VoyageSampling(
                startedAt: leg.startedAt, acceptsFrom: leg.startedAt, lastSaved: activeLastFix, interrupted: true)
        let endedAt = max(time, leg.startedAt, coverage.lastSeen ?? activeLastFix?.timestamp ?? leg.startedAt)
        var finished = leg
        finished.endedAt = endedAt
        finished.endingGap = coverage.gap(until: endedAt)
        var next = index
        next.voyages[voyageIndex].legs[next.voyages[voyageIndex].legs.count - 1] = finished
        try save(next)
        sampling = nil
        activeFixCount = 0
        activeLastFix = nil
        activeLatestGap = nil
        return finished
    }

    public func track(for leg: VoyageLeg) throws -> [VoyageTrackPoint] {
        try readTrack(for: leg).points
    }

    private mutating func save(_ next: Index) throws {
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("index.json"), options: Self.writeOptions)
        index = next
    }

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
            [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
            [.atomic]
        #endif
    }

    private func journal(for leg: VoyageLeg) -> URL {
        root.appendingPathComponent("\(leg.id.uuidString.lowercased()).ndjson")
    }

    private func readTrack(for leg: VoyageLeg) throws -> (points: [VoyageTrackPoint], committedBytes: Int, bytes: Int) {
        let data: Data
        do {
            data = try Data(contentsOf: journal(for: leg))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ([], 0, 0)
        }
        // The newline is the commit marker. Never bridge a torn tail into a new record.
        let committed = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let decoder = JSONDecoder()
        let points = try data.prefix(committed).split(separator: 0x0A).map {
            try decoder.decode(VoyageTrackPoint.self, from: Data($0))
        }
        return (points, committed, data.count)
    }

    private mutating func recoverTrack(for leg: VoyageLeg) throws {
        let track = try readTrack(for: leg)
        if track.committedBytes < track.bytes {
            let handle = try FileHandle(forWritingTo: journal(for: leg))
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(track.committedBytes))
            try handle.synchronize()
        }
        activeFixCount = track.points.count
        activeLastFix = track.points.last?.position
        activeLatestGap = track.points.last { $0.gapBefore != nil }?.gapBefore
    }

    private func append(_ point: VoyageTrackPoint, to leg: VoyageLeg) throws {
        let data = try RawFormat.line(point)
        let url = journal(for: leg)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: Self.writeOptions)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let start = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? handle.truncate(atOffset: start)
            throw error
        }
    }
}
