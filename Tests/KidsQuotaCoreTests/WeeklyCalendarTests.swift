import XCTest
@testable import KidsQuotaCore

final class WeeklyCalendarTests: XCTestCase {
    func testMondayBoundaryIsInclusive() throws {
        let calendar = try WeeklyCalendar(schedule: .init(timeZone: "UTC"))
        let boundary = instant("2026-10-19T00:00:00Z")
        XCTAssertEqual(calendar.period(containing: boundary).start, boundary)
        XCTAssertEqual(calendar.period(containing: boundary.addingTimeInterval(-1)).end, boundary)
    }

    func testCustomWeekdayAndLocalTime() throws {
        let calendar = try WeeklyCalendar(schedule: .init(weekday: "friday", localTime: "18:30", timeZone: "America/Chicago"))
        XCTAssertEqual(calendar.period(containing: instant("2026-10-24T01:00:00Z")).start, instant("2026-10-23T23:30:00Z"))
    }

    func testSpringDSTWeekHas167Hours() throws {
        let calendar = try WeeklyCalendar(schedule: .init(timeZone: "America/Chicago"))
        let period = calendar.period(containing: instant("2026-03-07T18:00:00Z"))
        XCTAssertEqual(period.end.timeIntervalSince(period.start), 167 * 3600)
        XCTAssertEqual(period.end, instant("2026-03-09T05:00:00Z"))
    }

    func testFallDSTWeekHas169Hours() throws {
        let calendar = try WeeklyCalendar(schedule: .init(timeZone: "America/Chicago"))
        let period = calendar.period(containing: instant("2026-10-31T18:00:00Z"))
        XCTAssertEqual(period.end.timeIntervalSince(period.start), 169 * 3600)
        XCTAssertEqual(period.end, instant("2026-11-02T06:00:00Z"))
    }

    func testNonexistentResetTimeAdvancesToNextValidTime() throws {
        let calendar = try WeeklyCalendar(schedule: .init(weekday: "sunday", localTime: "02:30", timeZone: "America/Chicago"))
        let period = calendar.period(containing: instant("2026-03-08T09:00:00Z"))
        XCTAssertEqual(period.start, instant("2026-03-08T08:00:00Z"))
    }

    func testRepeatedResetTimeOccursOnlyOnce() throws {
        let calendar = try WeeklyCalendar(schedule: .init(weekday: "sunday", localTime: "01:30", timeZone: "America/Chicago"))
        let first = calendar.period(containing: instant("2026-11-01T06:45:00Z"))
        let second = calendar.period(containing: instant("2026-11-01T07:45:00Z"))
        XCTAssertEqual(first.start, instant("2026-11-01T06:30:00Z"))
        XCTAssertEqual(first, second)
    }

    func testInvalidSchedulesFail() {
        for schedule in [ResetSchedule(weekday: "mondayy"), .init(localTime: "24:00"), .init(localTime: "9:00"), .init(timeZone: "not-a-timezone")] {
            XCTAssertThrowsError(try WeeklyCalendar(schedule: schedule))
        }
    }
}
