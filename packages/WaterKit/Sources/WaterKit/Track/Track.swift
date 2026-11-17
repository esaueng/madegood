import Foundation

/// A recorded session as stored on device and uploaded: GPS, heart rate, events, and the
/// analysis summary. Raw motion data is not part of a track (see `RawSession`).
public struct Track: Sendable, Hashable {
    public var sessionId: UUID
    public var sport: Sport
    /// Wall-clock start of the session; every `t` is seconds since this instant.
    public var startedAt: Date
    public var gps: [GPSFix]
    public var hr: [HRSample]
    public var events: [SessionEvent]
    /// The sport-specific analysis summary, if analysis has run.
    public var summary: JSONValue?
    /// Version of the analyzer that produced `summary` and analysis events.
    public var analyzerVersion: String?

    public init(
        sessionId: UUID, sport: Sport, startedAt: Date, gps: [GPSFix] = [], hr: [HRSample] = [],
        events: [SessionEvent] = [], summary: JSONValue? = nil, analyzerVersion: String? = nil
    ) {
        self.sessionId = sessionId
        self.sport = sport
        self.startedAt = startedAt
        self.gps = gps
        self.hr = hr
        self.events = events
        self.summary = summary
        self.analyzerVersion = analyzerVersion
    }

    /// Duration from the start to the last sample or event, s.
    public var duration: Double {
        max(gps.last?.t ?? 0, hr.last?.t ?? 0, events.map(\.t).max() ?? 0)
    }
}
