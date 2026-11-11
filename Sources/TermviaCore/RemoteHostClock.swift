import Foundation

/// The remote wall clock and numeric UTC offset, sampled together. Metrics
/// still use local receipt time and remote uptime for plots and rates.
public struct RemoteHostClock: Sendable, Equatable {
    public let date: Date
    public let utcOffset: Int
    public var timeZoneLabel: String {
        let minutes = abs(utcOffset) / 60
        let hours = minutes / 60, remainder = minutes % 60
        return "UTC" + (utcOffset < 0 ? "-" : "+") + String(hours) + (remainder == 0 ? "" : String(format: ":%02d", remainder))
    }
    public static func parse(_ value: String) -> Self? {
        let fields = value.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let epoch = Double(fields[0]), epoch.isFinite,
              (-62_135_596_800...253_402_300_799).contains(epoch) else { return nil }
        let offset = Array(fields[1])
        guard offset.count == 5, offset[0] == "+" || offset[0] == "-",
              offset.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }),
              let hours = Int(String(offset[1...2])), let minutes = Int(String(offset[3...4])),
              hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return nil }
        return Self(date: Date(timeIntervalSince1970: epoch), utcOffset: (hours * 3600 + minutes * 60) * (offset[0] == "-" ? -1 : 1))
    }
    private static let formatterLock = NSLock()
    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian)
        value.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return value
    }()
    public func formatted(at now: Date, sampledAt: Date, advancing: Bool) -> String {
        Self.formatterLock.lock()
        defer { Self.formatterLock.unlock() }
        let formatter = Self.formatter
        if formatter.timeZone.secondsFromGMT() != utcOffset { formatter.timeZone = TimeZone(secondsFromGMT: utcOffset) }
        return formatter.string(from: date.addingTimeInterval(advancing ? max(0, now.timeIntervalSince(sampledAt)) : 0)) + " " + timeZoneLabel
    }
}
