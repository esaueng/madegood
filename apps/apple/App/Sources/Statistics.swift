import Foundation

/// Totals per calendar week, month or year for the Statistics screen. Values stay SI
/// (metres, seconds, metres per second) until display.
enum Statistics {
    enum Period: String, CaseIterable, Identifiable, Sendable {
        case week, month, year

        var id: Self { self }

        var title: String {
            switch self {
            case .week: "Week"
            case .month: "Month"
            case .year: "Year"
            }
        }

        var component: Calendar.Component {
            switch self {
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        }
    }

    /// One analyzed session: where it starts (the recording's start, as History's date
    /// filters use) and its headline numbers.
    struct Sample: Equatable, Sendable {
        var startedAt: Date
        var distance: Double
        var movingTime: Double
        var maxSpeed10s: Double?
    }

    struct Bucket: Identifiable, Equatable, Sendable {
        var id: Date { start }
        let start: Date
        let end: Date
        var sessions = 0
        var distance = 0.0
        var movingTime = 0.0
        var fastest10s: Double?
        /// The period that contains now, still filling up.
        var isCurrent = false
    }

    /// Weeks and months show this many periods; years show every year from the first
    /// session's.
    static let recentCount = 12

    /// Consecutive periods ending with the one that contains `now`, oldest first. Empty
    /// periods are included, so gaps show as gaps; sessions before the first period or
    /// after the last are left out.
    static func buckets(
        _ samples: [Sample], period: Period, now: Date, calendar: Calendar
    ) -> [Bucket] {
        guard let current = calendar.dateInterval(of: period.component, for: now) else { return [] }
        let count: Int
        if period == .year {
            // By year number: a year that began off midnight (an offset change) would make
            // a count of whole elapsed years come out one short.
            let first = samples.map(\.startedAt).filter { $0 < current.end }.min() ?? now
            let years = calendar.component(.year, from: current.start) - calendar.component(.year, from: first)
            count = max(1, min(years + 1, 50))
        } else {
            count = recentCount
        }
        // Step back one period at a time from the current one, and end each period where
        // the next begins: across a skipped day (Samoa's date-line change) Foundation's
        // interval for that week is a day short, and a session in the gap would be lost.
        var buckets = [Bucket(start: current.start, end: current.end, isCurrent: true)]
        while buckets.count < count, let earliest = buckets.first,
            let interval = calendar.dateInterval(of: period.component, for: earliest.start.addingTimeInterval(-1))
        {
            buckets.insert(Bucket(start: interval.start, end: earliest.start), at: 0)
        }
        for sample in samples {
            guard
                let index = buckets.firstIndex(where: { $0.start <= sample.startedAt && sample.startedAt < $0.end })
            else { continue }
            buckets[index].sessions += 1
            buckets[index].distance += sample.distance
            buckets[index].movingTime += sample.movingTime
            if let speed = sample.maxSpeed10s {
                buckets[index].fastest10s = max(buckets[index].fastest10s ?? speed, speed)
            }
        }
        return buckets
    }
}
