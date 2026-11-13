import Foundation
@testable import NotaCore
import SwiftData

/// A fresh in-memory SwiftData store per test, so tests never touch the app's library or each other.
@MainActor
func makeContext() throws -> ModelContext {
    let container = try ModelContainer(for: Note.self, Folder.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    // The context keeps the container alive for as long as the test holds it.
    return ModelContext(container)
}

/// Tests run on a fixed clock and calendar so date rules don't depend on when or where they run.
enum Clock {
    /// Gregorian, UTC, weeks starting Sunday.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static let locale = Locale(identifier: "en_US")

    /// Thursday 12 November 2026, 15:30 UTC.
    static let now = date(2026, 11, 12, hour: 15, minute: 30)

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func daysAgo(_ days: Int, hour: Int = 12) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        return calendar.date(byAdding: .hour, value: hour, to: day)!
    }
}
