import Foundation
import WaterKit

/// A finished session's metadata for `PUT /sessions/{id}`, frozen from its track v1 file
/// when the session is queued, so every retry sends the same values. SI units.
struct SessionUploadSnapshot: Codable, Equatable, Sendable {
    let sessionID: UUID
    let sport: Sport
    let startedAt: Date
    var endedAt: Date?
    var durationS: Double?
    var movingS: Double?
    var distanceM: Double?
    var maxSpeedMps: Double?
    var avgSpeedMps: Double?
    var summary: JSONValue?
    var analyzerVersion: String?

    // The API's limits (web/src/server/routes/sessions.ts). Values outside them are left
    // out rather than rejected, so one odd number cannot block a whole upload.
    static let maxDurationS: Double = 7 * 24 * 3600
    static let maxSpeedMps: Double = 50
    static let maxDistanceM: Double = 10_000_000
    static let maxSummaryBytes = 64 * 1024

    /// `endedAt` is when the recording stopped (raw meta); the track's own summary gives
    /// the rest.
    init(track: Track, endedAt: Date?) {
        sessionID = track.sessionId
        sport = track.sport
        startedAt = track.startedAt
        analyzerVersion = track.analyzerVersion.flatMap { version in
            version.wholeMatch(of: /\d{1,4}\.\d{1,4}\.\d{1,4}/) == nil ? nil : version
        }

        let fields: [String: JSONValue]
        if case .object(let object) = track.summary { fields = object } else { fields = [:] }
        func number(_ key: String) -> Double? {
            if case .number(let value) = fields[key], value.isFinite { return value }
            return nil
        }
        func within(_ value: Double?, _ limit: Double) -> Double? {
            value.flatMap { (0...limit).contains($0) ? $0 : nil }
        }

        let elapsed = endedAt.map { $0.timeIntervalSince(startedAt) } ?? number("elapsed")
        durationS = within(elapsed, Self.maxDurationS)
        if let durationS { self.endedAt = endedAt ?? startedAt.addingTimeInterval(durationS) }
        movingS = within(number("movingTime"), Self.maxDurationS).map { moving in
            durationS.map { min(moving, $0) } ?? moving
        }
        distanceM = within(number("distance"), Self.maxDistanceM)
        maxSpeedMps = within(number("maxSpeed2s"), Self.maxSpeedMps)
        avgSpeedMps = within(number("averageSpeed"), Self.maxSpeedMps)
        if let summary = track.summary, case .object = summary,
            let encoded = try? JSONEncoder().encode(summary), encoded.count <= Self.maxSummaryBytes
        {
            self.summary = summary
        }
    }
}
