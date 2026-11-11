import Foundation

/// Which build of the app is running. The `Nota` target is production; the `Nota Staging`
/// target compiles with the `STAGING` flag. The two targets have different bundle IDs, so
/// each has its own sandbox, SwiftData store and UserDefaults, and both can be installed at once.
enum AppEnvironment {
    case production
    case staging

    static var current: AppEnvironment {
        #if STAGING
        .staging
        #else
        .production
        #endif
    }

    /// Staging starts with the sample library so there is test data to work with.
    /// Production starts empty and only ever holds the user's own notes.
    var seedsSampleData: Bool { self == .staging }
}
