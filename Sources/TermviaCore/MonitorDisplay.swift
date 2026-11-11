import Foundation

public enum MonitorTimeWindow {
    public static let duration: TimeInterval = 60
    public static func range(endingAt date: Date) -> ClosedRange<Date> { date.addingTimeInterval(-duration)...date }
}

public enum MonitorPlotScale {
    /// Quantized headroom avoids continuously renormalizing the first samples.
    /// A visible plot only expands this bound; historical peaks never shrink it.
    public static func upperBound(for peak: Double, minimum: Double = 1) -> Double {
        guard peak.isFinite, peak > 0 else { return minimum }
        let needed = peak * 1.15
        let magnitude = pow(10, floor(log10(needed)))
        for multiplier in [1.0, 2, 5, 10] where magnitude * multiplier >= needed { return max(minimum, magnitude * multiplier) }
        return max(minimum, needed)
    }
}

public enum MonitorRateFormatter {
    /// Decimal, language-independent units; rounded values never grow a fourth
    /// integer digit. A counter baseline is unknown, rather than a fake zero.
    public static func string(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        if bytesPerSecond == 0 { return "0 KB/s" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"]
        var index = bytesPerSecond < 100 ? 0 : 1
        var value = bytesPerSecond / (index == 0 ? 1 : 1000)
        while (value * 10).rounded() / 10 >= 1000, index < units.count - 1 { value /= 1000; index += 1 }
        guard value < 1000 else { return "—" }
        var number = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        if number.hasSuffix(".0") { number.removeLast(2) }
        if number == "0" { return "0 KB/s" }
        return number + " " + units[index] + "/s"
    }
}

/// Technical uptime units stay stable across interface languages.
public enum MonitorUptimeFormatter {
    public static func string(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let minutes = Int(min(seconds / 60, Double(Int.max / 2)))
        let days = minutes / 1440, hours = minutes / 60 % 24, remainder = minutes % 60
        if days > 0 { return "\(days)d \(hours)h \(remainder)m" }
        if minutes >= 60 { return "\(minutes / 60)h \(remainder)m" }
        return "\(minutes)m"
    }
}

/// C/T are intentional technical labels, identical in every interface language.
public enum MonitorCPUFormatter {
    public static func string(cores: Int, threads: Int) -> String {
        (cores > 0 ? String(cores) : "—") + "C" + (threads > 0 ? String(threads) : "—") + "T"
    }
}
