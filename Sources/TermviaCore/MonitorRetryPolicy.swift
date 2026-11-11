import Foundation

/// Reconnect only the auxiliary sampling channel. Authentication and host-key
/// failures need user intervention; transport failures use a bounded cadence.
public enum MonitorRetryPolicy {
    public static func shouldRetry(status: Int32, diagnostic: String) -> Bool {
        guard status == 0 || status == 255 else { return false }
        let text = diagnostic.lowercased()
        return !["permission denied", "authentication failed", "host key verification failed", "remote host identification has changed", "no supported authentication methods", "too many authentication failures", "bad configuration option"].contains(where: text.contains)
    }
    public static func delay(afterFailure count: Int) -> Int {
        [2, 4, 8, 16, 30][min(4, max(0, count - 1))]
    }
}
