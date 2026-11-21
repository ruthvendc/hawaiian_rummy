import Foundation

enum PlayerName {
    static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func comparisonKey(_ name: String) -> String {
        trimmed(name).folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}
