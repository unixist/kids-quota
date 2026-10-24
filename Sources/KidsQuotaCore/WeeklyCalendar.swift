import Foundation

public struct WeekPeriod: Equatable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}

/// Calendar boundaries, not a fixed 604800-second duration. This handles DST and
/// local midnight transitions according to Foundation's next-valid-time policy.
public struct WeeklyCalendar {
    public let schedule: ResetSchedule
    private let calendar: Calendar
    private let weekday: Int
    private let hour: Int
    private let minute: Int

    public init(schedule: ResetSchedule) throws {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let time = schedule.localTime.split(separator: ":", omittingEmptySubsequences: false)
        guard let index = names.firstIndex(of: schedule.weekday), time.count == 2,
              time[0].count == 2, time[1].count == 2,
              let hour = Int(time[0]), let minute = Int(time[1]), (0...23).contains(hour), (0...59).contains(minute),
              let zone = TimeZone(identifier: schedule.timeZone) else {
            throw QuotaError.invalidPolicy("Invalid weekly reset day, time, or timezone.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        self.calendar = calendar; self.weekday = index + 1
        self.hour = hour; self.minute = minute; self.schedule = schedule
    }

    private func boundary(on day: Date) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start,
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)!
    }

    public func period(containing date: Date) -> WeekPeriod {
        let day = calendar.startOfDay(for: date)
        let currentWeekday = calendar.component(.weekday, from: day)
        let daysSinceBoundary = (currentWeekday - weekday + 7) % 7
        var boundaryDay = calendar.date(byAdding: .day, value: -daysSinceBoundary, to: day)!
        var start = boundary(on: boundaryDay)
        if start > date {
            boundaryDay = calendar.date(byAdding: .day, value: -7, to: boundaryDay)!
            start = boundary(on: boundaryDay)
        }
        let end = boundary(on: calendar.date(byAdding: .day, value: 7, to: boundaryDay)!)
        return WeekPeriod(start: start, end: end)
    }
}
