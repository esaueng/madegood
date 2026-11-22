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
            let first = samples.map(\.startedAt).filter { $0 < current.end }.min() ?? now
            let firstYear = calendar.dateInterval(of: .year, for: first)?.start ?? current.start
            let years = calendar.dateComponents([.year], from: firstYear, to: current.start).year ?? 0
            count = max(1, min(years + 1, 50))
        } else {
            count = recentCount
        }
        var buckets: [Bucket] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: period.component, value: -offset, to: current.start),
                let interval = calendar.dateInterval(of: period.component, for: date)
            else { continue }
            buckets.append(Bucket(start: interval.start, end: interval.end, isCurrent: offset == 0))
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
