import XCTest

@testable import MadeGood

final class StatisticsTests: XCTestCase {
    /// Fixed zone and first weekday, so the tests don't depend on the machine's settings.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 2  // Monday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func sample(_ date: Date, distance: Double = 1000, time: Double = 600, max: Double? = 3)
        -> Statistics.Sample
    {
        Statistics.Sample(startedAt: date, distance: distance, movingTime: time, maxSpeed10s: max)
    }

    func testMonthsAreTheLastTwelveWithGapsAndTheCurrentOneLast() {
        let now = date(2026, 11, 21)
        let buckets = Statistics.buckets(
            [
                sample(date(2026, 11, 2), distance: 2000, time: 900, max: 4),
                sample(date(2026, 11, 20), distance: 500, time: 300, max: 5),
                sample(date(2026, 3, 31, 23)),
            ],
            period: .month, now: now, calendar: calendar)
        XCTAssertEqual(buckets.count, 12)
        XCTAssertEqual(buckets.first?.start, date(2025, 12, 1, 0))
        XCTAssertEqual(buckets.last?.start, date(2026, 11, 1, 0))
        XCTAssertEqual(buckets.filter(\.isCurrent).map(\.start), [date(2026, 11, 1, 0)])

        let november = buckets[11]
        XCTAssertEqual(november.sessions, 2)
        XCTAssertEqual(november.distance, 2500)
        XCTAssertEqual(november.movingTime, 1200)
        XCTAssertEqual(november.fastest10s, 5)
        // 23:00 local on 31 March is still March, whatever UTC says.
        XCTAssertEqual(buckets[3].sessions, 1)
        XCTAssertEqual(buckets[4].sessions, 0)
        XCTAssertNil(buckets[4].fastest10s)
    }

    func testWeeksFollowTheCalendarsFirstWeekday() {
        // Sunday 22 November belongs to the week that began on Monday 16 November.
        let now = date(2026, 11, 22)
        let buckets = Statistics.buckets(
            [sample(date(2026, 11, 16, 6)), sample(date(2026, 11, 15, 22))], period: .week, now: now,
            calendar: calendar)
        XCTAssertEqual(buckets.count, 12)
        XCTAssertEqual(buckets.last?.start, date(2026, 11, 16, 0))
        XCTAssertEqual(buckets.last?.sessions, 1)
        XCTAssertEqual(buckets[10].sessions, 1)
    }

    func testYearsRunFromTheFirstSessionsYearAndSkipFutureSessions() {
        let now = date(2026, 11, 21)
        let buckets = Statistics.buckets(
            [sample(date(2024, 6, 1)), sample(date(2026, 1, 1, 1)), sample(date(2027, 2, 1))],
            period: .year, now: now, calendar: calendar)
        XCTAssertEqual(buckets.map(\.start), [date(2024, 1, 1, 0), date(2025, 1, 1, 0), date(2026, 1, 1, 0)])
        XCTAssertEqual(buckets.map(\.sessions), [1, 0, 1])
    }

    func testOlderSessionsAndNoSessionsStillGiveTheRecentPeriods() {
        let now = date(2026, 11, 21)
        let old = Statistics.buckets([sample(date(2020, 1, 1))], period: .month, now: now, calendar: calendar)
        XCTAssertEqual(old.count, 12)
        XCTAssertEqual(old.reduce(0) { $0 + $1.sessions }, 0)
        let none = Statistics.buckets([], period: .year, now: now, calendar: calendar)
        XCTAssertEqual(none.map(\.start), [date(2026, 1, 1, 0)])
    }
}
