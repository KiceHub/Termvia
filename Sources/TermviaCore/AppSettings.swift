import Foundation

public enum TerminalCursorShape: String, Codable, CaseIterable, Sendable {
    case block, bar, underline
    public var title: String {
        switch self {
        case .block: return T("方框") + " □"
        case .bar: return T("竖线") + " |"
        case .underline: return T("下划线") + " _"
        }
    }
}

public enum TerminalLeftMouseAction: String, Codable, CaseIterable, Sendable {
    case disabled, copy
    public var title: String { self == .disabled ? T("关闭鼠标操作") : T("拷贝") }
}
public enum TerminalRightMouseAction: String, Codable, CaseIterable, Sendable {
    case disabled, copyPaste, copyAndPaste
    public var title: String {
        switch self {
        case .disabled: return T("关闭鼠标操作")
        case .copyPaste: return T("拷贝/粘贴")
        case .copyAndPaste: return T("复制/粘贴")
        }
    }
}

public enum TerminalTheme: String, Codable, CaseIterable, Sendable {
    case system, midnight, daylight, custom
    public var title: String { switch self { case .system: return T("系统"); case .midnight: return T("深色"); case .daylight: return T("浅色"); case .custom: return T("自定义") } }
}

public struct TerminalPalette: Codable, Equatable, Sendable {
    public var foreground = "CCCCCC"
    public var background = "0C0C0C"
    public var cursor = "FFFFFF"
    // Windows Terminal Campbell: saturated ANSI colors, independent of UI tint.
    public var ansi = ["0C0C0C", "C50F1F", "13A10E", "C19C00", "0037DA", "881798", "3A96DD", "CCCCCC", "767676", "E74856", "16C60C", "F9F1A5", "3B78FF", "B4009E", "61D6D6", "F2F2F2"]
    public init() {}
    public static func validHex(_ value: String) -> Bool { value.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }
    public func validated() -> Self {
        let defaults = Self(); var result = self
        result.foreground = Self.validHex(foreground) ? foreground.uppercased() : defaults.foreground
        result.background = Self.validHex(background) ? background.uppercased() : defaults.background
        result.cursor = Self.validHex(cursor) ? cursor.uppercased() : defaults.cursor
        result.ansi = (0..<16).map { index in ansi.indices.contains(index) && Self.validHex(ansi[index]) ? ansi[index].uppercased() : defaults.ansi[index] }
        return result
    }
    public static var daylight: Self {
        var value = Self(); value.foreground = "24292F"; value.background = "FAFAFA"; value.cursor = "0969DA"
        value.ansi = ["24292F", "CF222E", "116329", "9A6700", "0969DA", "8250DF", "1B7C83", "6E7781", "57606A", "A40E26", "1A7F37", "7D4E00", "0550AE", "6639BA", "0A6972", "FAFAFA"]
        return value
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var terminalTheme = TerminalTheme.system
    public var preferRemoteColors = true
    public var customPalette = TerminalPalette()
    public var scrollbackLines = 10000
    public var cursorShape = TerminalCursorShape.bar
    public var monitorInterval = 1
    public var leftMouseAction = TerminalLeftMouseAction.disabled
    public var rightMouseAction = TerminalRightMouseAction.copyPaste
    public var doubleClickClosesTab = true
    public var terminalInsets = TerminalInsets()
    public var shortcutOverrides: [String: AppShortcutBinding] = [:]
    public var sshKeepAlive = false
    public var sshKeepAliveInterval = 15
    public var autoReconnect = false
    public var confirmTransfers = true
    public var suppressOpenSSHWarnings = true
    public var reconnectDelay = 2.0
    public var reconnectAttempts = 3
    public init() {}
    private enum CodingKeys: CodingKey { case terminalTheme, preferRemoteColors, customPalette, scrollbackLines, cursorShape, monitorInterval, leftMouseAction, rightMouseAction, rightClickClipboard, leftClickCopyRightClickPaste, doubleClickClosesTab, terminalInsets, shortcutOverrides, sshKeepAlive, sshKeepAliveInterval, autoReconnect, confirmTransfers, suppressOpenSSHWarnings, reconnectDelay, reconnectAttempts }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        terminalTheme = (try values.decodeIfPresent(String.self, forKey: .terminalTheme)).flatMap(TerminalTheme.init(rawValue:)) ?? .system
        preferRemoteColors = try values.decodeIfPresent(Bool.self, forKey: .preferRemoteColors) ?? true
        customPalette = try values.decodeIfPresent(TerminalPalette.self, forKey: .customPalette) ?? TerminalPalette()
        scrollbackLines = try values.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? 10000
        cursorShape = (try values.decodeIfPresent(String.self, forKey: .cursorShape)).flatMap(TerminalCursorShape.init(rawValue:)) ?? .bar
        monitorInterval = try values.decodeIfPresent(Int.self, forKey: .monitorInterval) ?? 1
        let legacyRight = try values.decodeIfPresent(Bool.self, forKey: .rightClickClipboard) ?? true
        let legacyCombined = try values.decodeIfPresent(Bool.self, forKey: .leftClickCopyRightClickPaste) ?? false
        leftMouseAction = (try values.decodeIfPresent(String.self, forKey: .leftMouseAction)).flatMap(TerminalLeftMouseAction.init(rawValue:)) ?? (legacyRight && legacyCombined ? .copy : .disabled)
        rightMouseAction = (try values.decodeIfPresent(String.self, forKey: .rightMouseAction)).flatMap(TerminalRightMouseAction.init(rawValue:)) ?? (!legacyRight ? .disabled : legacyCombined ? .copyAndPaste : .copyPaste)
        doubleClickClosesTab = try values.decodeIfPresent(Bool.self, forKey: .doubleClickClosesTab) ?? true
        terminalInsets = try values.decodeIfPresent(TerminalInsets.self, forKey: .terminalInsets) ?? TerminalInsets()
        shortcutOverrides = try values.decodeIfPresent([String: AppShortcutBinding].self, forKey: .shortcutOverrides) ?? [:]
        sshKeepAlive = try values.decodeIfPresent(Bool.self, forKey: .sshKeepAlive) ?? false
        sshKeepAliveInterval = try values.decodeIfPresent(Int.self, forKey: .sshKeepAliveInterval) ?? 15
        autoReconnect = try values.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
        confirmTransfers = try values.decodeIfPresent(Bool.self, forKey: .confirmTransfers) ?? true
        suppressOpenSSHWarnings = try values.decodeIfPresent(Bool.self, forKey: .suppressOpenSSHWarnings) ?? true
        reconnectDelay = try values.decodeIfPresent(Double.self, forKey: .reconnectDelay) ?? 2
        reconnectAttempts = try values.decodeIfPresent(Int.self, forKey: .reconnectAttempts) ?? 3
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(terminalTheme, forKey: .terminalTheme)
        try values.encode(preferRemoteColors, forKey: .preferRemoteColors)
        try values.encode(customPalette, forKey: .customPalette)
        try values.encode(scrollbackLines, forKey: .scrollbackLines)
        try values.encode(cursorShape, forKey: .cursorShape)
        try values.encode(monitorInterval, forKey: .monitorInterval)
        try values.encode(leftMouseAction, forKey: .leftMouseAction)
        try values.encode(rightMouseAction, forKey: .rightMouseAction)
        try values.encode(doubleClickClosesTab, forKey: .doubleClickClosesTab)
        try values.encode(terminalInsets, forKey: .terminalInsets)
        try values.encode(shortcutOverrides, forKey: .shortcutOverrides)
        try values.encode(sshKeepAlive, forKey: .sshKeepAlive)
        try values.encode(sshKeepAliveInterval, forKey: .sshKeepAliveInterval)
        try values.encode(autoReconnect, forKey: .autoReconnect)
        try values.encode(confirmTransfers, forKey: .confirmTransfers)
        try values.encode(suppressOpenSSHWarnings, forKey: .suppressOpenSSHWarnings)
        try values.encode(reconnectDelay, forKey: .reconnectDelay)
        try values.encode(reconnectAttempts, forKey: .reconnectAttempts)
    }
    public func validated() -> Self {
        var result = self
        result.customPalette = customPalette.validated()
        result.terminalInsets = terminalInsets.validated()
        result.shortcutOverrides = AppShortcutConfiguration.validated(shortcutOverrides)
        result.scrollbackLines = min(100000, max(500, scrollbackLines))
        result.sshKeepAliveInterval = min(300, max(1, sshKeepAliveInterval))
        result.monitorInterval = min(30, max(1, monitorInterval))
        result.reconnectDelay = reconnectDelay.isFinite ? min(30, max(1, reconnectDelay)) : 2
        result.reconnectAttempts = min(10, max(1, reconnectAttempts))
        return result
    }
    public func retryDelay(attempt: Int) -> Double {
        min(30, validated().reconnectDelay * pow(2, Double(max(0, min(10, attempt - 1)))))
    }
    public static func isTransientConnectionFailure(_ detail: String) -> Bool {
        // Authentication/trust failures require a manual decision, never a retry loop.
        let message = detail.lowercased()
        return !message.isEmpty && ["connection refused", "connection timed out", "operation timed out", "connection reset", "connection closed", "broken pipe", "no route to host", "network is unreachable", "could not resolve hostname"].contains { message.contains($0) }
            && !["permission denied", "authentication failed", "host key", "identification has changed"].contains { message.contains($0) }
    }
}
