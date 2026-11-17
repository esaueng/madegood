import Foundation

/// Verifies that a recording looks anonymized before it is committed: every position near
/// `Anonymizer.fakeOrigin`, every timestamp on the fake start date, no altitude, and no
/// text in event data. CI runs this over `fixtures/`.
public enum FixtureCheck {
    /// Problems found in a raw session; empty when it passes.
    public static func problems(in session: RawSession) -> [String] {
        var problems = common(
            gps: session.gps, events: session.events, startedAt: session.meta.startedAt)
        if session.meta.clock.uptime != Anonymizer.fakeUptime {
            problems.append("clock anchor uptime is \(session.meta.clock.uptime), expected \(Anonymizer.fakeUptime)")
        }
        if session.clockAnchors.count > 1 {
            problems.append("clock.ndjson has extra anchors; anonymized recordings have only the meta.json anchor")
        }
        return problems
    }

    /// Problems found in a track; empty when it passes.
    public static func problems(in track: Track) -> [String] {
        var problems = common(gps: track.gps, events: track.events, startedAt: track.startedAt.timeIntervalSince1970)
        if track.summary != nil { problems.append("track has a summary; anonymized tracks drop it") }
        return problems
    }

    private static func common(gps: [GPSFix], events: [SessionEvent], startedAt: Double) -> [String] {
        var problems: [String] = []
        let day = 86_400.0
        let fakeDay = (Anonymizer.fakeStart / day).rounded(.down) * day
        if startedAt < fakeDay || startedAt >= fakeDay + day {
            problems.append("session starts at Unix time \(startedAt), not on the anonymized date (2000-01-01)")
        }
        let far = gps.filter {
            Geo.distance(
                lat1: $0.latitude, lon1: $0.longitude,
                lat2: Anonymizer.fakeOrigin.lat, lon2: Anonymizer.fakeOrigin.lon) > Anonymizer.checkRadius
        }
        if !far.isEmpty {
            problems.append(
                "\(far.count) GPS fixes are more than \(Int(Anonymizer.checkRadius / 1000)) km from the fake origin")
        }
        if gps.contains(where: { $0.altitude != nil || $0.verticalAccuracy != nil }) {
            problems.append("GPS fixes include altitude")
        }
        let texty = events.filter { event in
            (event.data ?? [:]).contains { key, value in
                switch value {
                case .number, .bool: return Anonymizer.blockedKeyFragments.contains(where: key.lowercased().contains)
                default: return true
                }
            }
        }
        if !texty.isEmpty {
            problems.append("\(texty.count) events carry text, nested, or position-like data")
        }
        return problems
    }
}
