import Foundation

@MainActor enum FileSizeDisplay {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
    static func string(_ bytes: UInt64) -> String {
        var value = Double(bytes), unit = 0
        // Convert by 1024, promoting at 1000 to keep at most three integer digits.
        while value >= 1000, unit < units.count - 1 {
            value /= 1024; unit += 1
        }
        // Promote values that round up to the next unit at two decimal places.
        if value >= 999.995, unit < units.count - 1 { value /= 1024; unit += 1 }
        return value.formatted(.number.precision(.fractionLength(2)).grouping(.never)) + " " + units[unit]
    }
}
