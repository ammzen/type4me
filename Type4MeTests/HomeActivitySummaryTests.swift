import XCTest
@testable import Type4Me

final class HomeActivitySummaryTests: XCTestCase {
    func testHeatmapWindowExpandsWithAvailableWidth() {
        let narrow = HomeHeatmapLayout(width: 350)
        let wide = HomeHeatmapLayout(width: 900)
        let veryWide = HomeHeatmapLayout(width: 2_000)

        XCTAssertGreaterThan(wide.weekCount, narrow.weekCount)
        XCTAssertEqual(veryWide.weekCount, 104)
    }

    func testSummarizesActiveAndLongestStreaks() {
        let fixture = makeFixture()
        let days = [
            activityDay(-8, calendar: fixture.calendar, today: fixture.today),
            activityDay(-7, calendar: fixture.calendar, today: fixture.today),
            activityDay(-3, calendar: fixture.calendar, today: fixture.today),
            activityDay(-2, calendar: fixture.calendar, today: fixture.today),
            activityDay(-1, calendar: fixture.calendar, today: fixture.today),
            activityDay(0, calendar: fixture.calendar, today: fixture.today),
        ]

        let summary = HomeActivitySummary(
            activityDays: days,
            today: fixture.today,
            calendar: fixture.calendar
        )

        XCTAssertEqual(summary.activeDays, 6)
        XCTAssertEqual(summary.currentStreak, 4)
        XCTAssertEqual(summary.longestStreak, 4)
    }

    func testYesterdayKeepsCurrentStreakUntilTodayHasActivity() {
        let fixture = makeFixture()
        let days = [
            activityDay(-3, calendar: fixture.calendar, today: fixture.today),
            activityDay(-2, calendar: fixture.calendar, today: fixture.today),
            activityDay(-1, calendar: fixture.calendar, today: fixture.today),
        ]

        let summary = HomeActivitySummary(
            activityDays: days,
            today: fixture.today,
            calendar: fixture.calendar
        )

        XCTAssertEqual(summary.currentStreak, 3)
        XCTAssertEqual(summary.longestStreak, 3)
    }

    func testInactiveRecentDaysResetCurrentStreak() {
        let fixture = makeFixture()
        let summary = HomeActivitySummary(
            activityDays: [
                activityDay(-4, calendar: fixture.calendar, today: fixture.today),
                activityDay(-3, calendar: fixture.calendar, today: fixture.today),
            ],
            today: fixture.today,
            calendar: fixture.calendar
        )

        XCTAssertEqual(summary.currentStreak, 0)
        XCTAssertEqual(summary.longestStreak, 2)
    }

    private func makeFixture() -> (calendar: Calendar, today: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let today = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 25, hour: 12
        ))!
        return (calendar, today)
    }

    private func activityDay(
        _ offset: Int,
        calendar: Calendar,
        today: Date
    ) -> HistoryStore.ActivityDay {
        let date = calendar.date(byAdding: .day, value: offset, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return HistoryStore.ActivityDay(
            dayIdentifier: formatter.string(from: date),
            recordCount: 1
        )
    }
}
