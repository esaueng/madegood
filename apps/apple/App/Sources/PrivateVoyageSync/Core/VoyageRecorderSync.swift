import Foundation
import WaterKit

/// Freezes the recorder’s saved leg for private sync.
enum VoyageRecorderSync {
    enum PreparationError: Error { case unfinishedLeg }

    static func prepare(voyage: Voyage, leg: VoyageLeg) throws -> CompletedVoyageLeg {
        guard let firstLeg = voyage.legs.first, let end = leg.endedAt,
            voyage.legs.contains(where: { $0.id == leg.id && $0.endedAt == end })
        else { throw PreparationError.unfinishedLeg }
        return CompletedVoyageLeg(
            voyageID: voyage.id,
            voyage: VoyageSnapshot(title: uploadTitle(voyage.name), startedAt: date(firstLeg.startedAt)),
            legID: leg.id,
            leg: VoyageLegSnapshot(startedAt: date(leg.startedAt), endedAt: date(end))
        )
    }

    static func uploadTitle(_ title: String) -> String {
        // The API limits the title to 100 UTF-16 code units. Keep graphemes intact
        // and leave room for an ellipsis when shortening an existing local name.
        guard title.utf16.count > 100 else { return title }
        var remaining = 99
        let prefix = title.prefix { character in
            let length = String(character).utf16.count
            guard length <= remaining else { return false }
            remaining -= length
            return true
        }
        return String(prefix) + "…"
    }

    static func encodeTrack(leg: VoyageLeg, points: [VoyageTrackPoint]) throws -> Data {
        guard let end = leg.endedAt else { throw PreparationError.unfinishedLeg }
        let fixes = points.map { point in
            let position = point.position
            return GPSFix(
                t: position.timestamp - leg.startedAt, latitude: position.latitude, longitude: position.longitude,
                horizontalAccuracy: position.horizontalAccuracy, speed: position.speed, course: position.course
            )
        }
        let gaps = points.compactMap(\.gapBefore) + [leg.endingGap].compactMap { $0 }
        var events = gaps.map { gap in
            SessionEvent(
                t: gap.start - leg.startedAt, type: "recording_gap",
                data: ["endT": .number(gap.end - leg.startedAt)]
            )
        }
        events.append(SessionEvent(t: end - leg.startedAt, type: .stop))
        return try TrackCodec.encode(
            Track(
                sessionId: leg.id, sport: .sailing, startedAt: date(leg.startedAt), gps: fixes, events: events
            ))
    }

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
