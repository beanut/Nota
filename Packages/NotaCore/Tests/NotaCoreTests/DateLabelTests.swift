import Foundation
@testable import NotaCore
import Testing

@Suite("Date.libraryLabel")
struct DateLabelTests {
    private func label(_ date: Date) -> String {
        date.libraryLabel(relativeTo: Clock.now, calendar: Clock.calendar, locale: Clock.locale)
    }

    @Test func today() {
        #expect(label(Clock.now) == "Today")
        #expect(label(Clock.date(2026, 11, 12, hour: 0, minute: 0)) == "Today", "midnight starts today")
        #expect(label(Clock.date(2026, 11, 12, hour: 23, minute: 59)) == "Today")
    }

    @Test func yesterday() {
        #expect(label(Clock.date(2026, 11, 11, hour: 0)) == "Yesterday")
        #expect(label(Clock.date(2026, 11, 11, hour: 23, minute: 59)) == "Yesterday")
    }

    /// Two to six days back is the weekday; the start of the sixth day back is the boundary.
    @Test func weekdayWithinTheLastWeek() {
        #expect(label(Clock.daysAgo(2)) == "Tuesday")
        #expect(label(Clock.daysAgo(5)) == "Saturday")
        #expect(label(Clock.daysAgo(6, hour: 0)) == "Friday")
    }

    @Test func monthAndDayEarlierThisYear() {
        #expect(label(Clock.daysAgo(7)) == "Nov 5")
        #expect(label(Clock.daysAgo(6).addingTimeInterval(-12 * 3600 - 1)) == "Nov 5", "a second before the boundary")
        #expect(label(Clock.date(2026, 1, 1, hour: 0)) == "Jan 1")
    }

    @Test func yearIsAddedForEarlierYears() {
        #expect(label(Clock.date(2025, 12, 31, hour: 23)) == "Dec 31, 2025")
        #expect(label(Clock.date(2019, 6, 3)) == "Jun 3, 2019")
    }

    /// Days begin at midnight in the calendar's time zone, not UTC.
    @Test func dayBoundariesFollowTheCalendarTimeZone() throws {
        var tokyo = Clock.calendar
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        // 15:30 UTC on 12 Nov is 00:30 on 13 Nov in Tokyo, so 14:00 UTC (23:00 on 12 Nov there) is yesterday.
        let date = Clock.date(2026, 11, 12, hour: 14)
        #expect(date.libraryLabel(relativeTo: Clock.now, calendar: tokyo, locale: Clock.locale) == "Yesterday")
        #expect(label(date) == "Today")
    }

    @Test func weekdayFollowsLocale() {
        let french = Clock.daysAgo(2).libraryLabel(relativeTo: Clock.now, calendar: Clock.calendar,
                                                   locale: Locale(identifier: "fr_FR"))
        #expect(french == "mardi")
    }

    @Test func defaultUsesTheCurrentClock() {
        #expect(Date.now.libraryLabel == "Today")
    }
}
