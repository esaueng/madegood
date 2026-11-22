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

    /// Review regression: years were counted as whole years elapsed between year starts.
    /// Kathmandu's 1986 began at 00:15 (an offset change), so Year started at 1987 and a
    /// June 1986 session was left out.
    func testYearsCountByYearNumberWhenAYearStartsOffMidnight() {
        var kathmandu = Calendar(identifier: .gregorian)
        kathmandu.timeZone = TimeZone(identifier: "Asia/Kathmandu")!
        let june1986 = kathmandu.date(from: DateComponents(year: 1986, month: 6, day: 1, hour: 10))!
        let now = kathmandu.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 10))!
        let buckets = Statistics.buckets([sample(june1986)], period: .year, now: now, calendar: kathmandu)
        XCTAssertEqual(buckets.count, 41)
        XCTAssertEqual(buckets.first.map { kathmandu.component(.year, from: $0.start) }, 1986)
        XCTAssertEqual(buckets.first?.sessions, 1)
    }

    /// Review regression: weeks were found by adding whole weeks to the current one, and
    /// Samoa's skipped 30 December 2011 made the week of 25 December drop out.
    func testWeeksStayConsecutiveAcrossASkippedDay() {
        var apia = Calendar(identifier: .gregorian)
        apia.timeZone = TimeZone(identifier: "Pacific/Apia")!
        apia.firstWeekday = 1  // Sunday
        let now = apia.date(from: DateComponents(year: 2012, month: 1, day: 5, hour: 12))!
        let december27 = apia.date(from: DateComponents(year: 2011, month: 12, day: 27, hour: 12))!
        let buckets = Statistics.buckets([sample(december27)], period: .week, now: now, calendar: apia)
        XCTAssertEqual(buckets.count, 12)
        for (earlier, later) in zip(buckets, buckets.dropFirst()) {
            XCTAssertEqual(earlier.end, later.start, "weeks must meet with no gap")
        }
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.sessions }, 1)
    }
}
