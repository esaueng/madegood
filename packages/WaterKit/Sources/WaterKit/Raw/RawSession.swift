import Foundation

/// A raw recording loaded into memory, with every stream on the session timeline
/// (`t` = seconds since `meta.startedAt`) and sorted by time.
public struct RawSession: Sendable {
    public var meta: RawFormat.Meta
    public var gps: [GPSFix]
    public var motion: [MotionSample]
    public var hr: [HRSample]
    public var heading: [HeadingSample]
    public var events: [SessionEvent]
    /// Clock anchors in uptime order, starting with `meta.clock`.
    public var clockAnchors: [RawFormat.ClockAnchor]
    /// Problems found while reading that did not stop the read (e.g. a truncated last line).
    public var issues: [RawReadIssue]
    /// The user's pause and resume events (not auto-pause) in recorded order, timed on the
    /// motion sensor's uptime clock: seconds of device uptime since `meta.clock`. A
    /// wall-clock correction can reorder `events`; it cannot reorder these. Nil when the
    /// session was not read from files.
    public var pauseEventsOnUptime: [SessionEvent]?

    public init(
        meta: RawFormat.Meta, gps: [GPSFix] = [], motion: [MotionSample] = [], hr: [HRSample] = [],
        heading: [HeadingSample] = [], events: [SessionEvent] = [], clockAnchors: [RawFormat.ClockAnchor]? = nil,
        issues: [RawReadIssue] = []
    ) {
        self.meta = meta
        self.gps = gps
        self.motion = motion
        self.hr = hr
        self.heading = heading
        self.events = events
        self.clockAnchors = clockAnchors ?? [meta.clock]
        self.issues = issues
    }

    public var startedAt: Date { Date(timeIntervalSince1970: meta.startedAt) }

    /// Duration from the start to `endedAt`, or to the last sample if the recording did not stop cleanly.
    public var duration: Double {
        if let endedAt = meta.endedAt { return endedAt - meta.startedAt }
        let lastTimes = [gps.last?.t, motion.last?.t, hr.last?.t, heading.last?.t, events.last?.t]
        return lastTimes.compactMap { $0 }.max() ?? 0
    }

    /// The track (GPS, heart rate, events) this recording would produce, without analysis.
    public func track() -> Track {
        Track(sessionId: meta.sessionId, sport: meta.sport, startedAt: startedAt, gps: gps, hr: hr, events: events)
    }

    /// All samples from every stream, merged in time order.
    public func samples() -> [Sample] {
        var all: [Sample] = []
        all.reserveCapacity(gps.count + motion.count + hr.count + heading.count + events.count)
        all += gps.map(Sample.gps)
        all += motion.map(Sample.motion)
        all += hr.map(Sample.hr)
        all += heading.map(Sample.heading)
        all += events.map(Sample.event)
        return all.enumerated()
            .sorted { $0.element.t != $1.element.t ? $0.element.t < $1.element.t : $0.offset < $1.offset }
            .map(\.element)
    }
}

/// A recoverable problem in a raw recording.
public struct RawReadIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        /// The last line has no newline and does not parse: the write was cut off.
        case truncatedLine
        /// A complete line that does not parse; it was skipped.
        case invalidLine(String)
        /// A gzipped stream ends inside a gzip member; the readable part was used.
        case truncatedFile
        /// A gzipped stream could not be decoded at all (e.g. a write cut off in the first
        /// header); the stream was treated as empty.
        case unreadableFile(String)
    }

    public var file: String
    /// 1-based line number, or nil for file-level issues.
    public var line: Int?
    public var kind: Kind

    public var description: String {
        let location = line.map { "\(file):\($0)" } ?? file
        switch kind {
        case .truncatedLine: return "\(location): truncated last line (skipped)"
        case .invalidLine(let reason): return "\(location): invalid line skipped (\(reason))"
        case .truncatedFile: return "\(location): gzip data ends early; read what was complete"
        case .unreadableFile(let reason): return "\(location): unreadable, treated as empty (\(reason))"
        }
    }
}
